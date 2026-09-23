//
//  MenuBarItemManager.swift
//  Ice
//

import Cocoa
import Combine

/// Manager for menu bar items.
@MainActor
final class MenuBarItemManager: ObservableObject {
    private var pendingPanelAction: Task<Void, Never>?
    private var isSetUp = false
    private var isActivatingPanelItem = false
    private var isRestoringTempShownItems = false
    private let cacheRequests = CoalescingTask()
    private let accessibility = MenuBarAccessibility()
    private let localAccessibility = MenuBarAccessibility.Local()
    private var accessibleItems = [MenuBarItem]()
    private var isReadingAccessibility = false
    private var isMovingAccessibleItem = false
    private(set) var isRefreshingHiddenImages = false
    private let presentationCapture = LatestTask<Bool, Void>()

    /// Spacing must restart publishers, not the system process hosting their
    /// windows. Resolve a fresh snapshot before the spacing preference is written.
    func menuBarPublisherProcessIDs() async throws -> Set<pid_t> {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw MenuBarAccessibilitySnapshot.IncompleteReadError() }
        let snapshot = await accessibilitySnapshot(discoverAllCandidates: true)
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw MenuBarAccessibilitySnapshot.IncompleteReadError() }
        return try snapshot.publisherProcessIDs()
    }

    /// Discovery is asynchronous; readers use the latest complete snapshot.
    func menuBarItems(on display: CGDirectDisplayID? = nil, onScreenOnly: Bool, activeSpaceOnly: Bool) -> [MenuBarItem] {
        let bounds = display.map { display in
            if #unavailable(macOS 27), let screen = NSScreen.screens.first(where: { $0.displayID == display }), let row = menuBarRow(on: screen) {
                return row
            }
            return CGDisplayBounds(display)
        }
        return accessibleItems.filter { item in
            guard !onScreenOnly || item.isOnScreen else { return false }
            guard let bounds else { return true }
            if #available(macOS 27, *) { return bounds.intersects(item.frame) }
            return item.accessibleItem?.isOnMenuBarRow(in: bounds) == true
        }.sortedByOrderInMenuBar()
    }

    /// Keeps discovery geometry distinct from the onscreen capture region.
    /// On 26.5 a full-screen bar retracts to y=-62, while the inactive desktop
    /// still has a Menubar window at y=0. Current local AX controls identify it.
    func menuBarRow(on screen: NSScreen) -> CGRect? {
        if let window = WindowInfo.getMenuBarWindow(for: screen.displayID) { return window.frame }
        guard #unavailable(macOS 27), appState?.isActiveSpaceFullscreen == true else { return nil }
        let anchors = accessibleItems.filter { $0.ownerPID == ProcessInfo.processInfo.processIdentifier }.compactMap { $0.accessibleItem?.frame }
        let rows = WindowInfo.getAllWindows().filter {
            $0.isWindowServerWindow && $0.layer == kCGMainMenuWindowLevel && $0.title == "Menubar"
        }.map(\.frame)
        return CaptureGeometry.menuBarRow(display: CGDisplayBounds(screen.displayID), candidates: rows, anchors: anchors)
    }

    private func cacheAccessibleItems() async {
        guard AXIsProcessTrusted() else {
            accessibleItems = []
            itemCache.clear()
            return
        }
        guard !isReadingAccessibility, !isMovingItem, !isRefreshingHiddenImages else { return }
        isReadingAccessibility = true
        defer { isReadingAccessibility = false }
        let snapshot = await accessibilitySnapshot()
        guard !Task.isCancelled, snapshot.isComplete, !isMovingItem, AXIsProcessTrusted() else { return }
        applyAccessibleSnapshot(snapshot)
        if #available(macOS 27, *) {
            await arrangeSupplementalDividersIfNeeded()
        }
    }

    @available(macOS 27, *)
    private func arrangeSupplementalDividersIfNeeded() async {
        guard let appState, !isMouseButtonDown, !mouseHasRecentlyMoved else { return }
        let controls = appState.menuBarManager.sections.map(\.controlItem).filter { $0.isSectionDivider && $0.isAddedToMenuBar }
        let pending = controls.filter(\.needsSupplementalPlacement)
        guard !pending.isEmpty else { return }
        // Reveal existing groups without discarding their verified order when a
        // second section is enabled. Only new or invalidated groups need setup.
        for control in controls { control.setTemporarilyRevealed(true) }
        var didRestoreControls = false
        func restoreControls() {
            guard !didRestoreControls else { return }
            didRestoreControls = true
            for control in controls { control.setTemporarilyRevealed(false) }
            let invalidated = accessibleItems.compactMap(\.accessibleItem).map { $0.removingFrame() }
            applyAccessibleSnapshot(MenuBarAccessibilitySnapshot(items: invalidated, isComplete: true, unavailableProcessIDs: []))
        }
        defer { restoreControls() }
        for control in pending { control.prepareSupplementalItems() }
        // MenuBarAgent applies status-item lengths asynchronously. Reading in the
        // same turn can still see the preceding collapsed bar and miss publishers.
        guard let snapshot = await settledAccessibilitySnapshot() else { return }
        let overflow = await prepareNativeOverflowPresentation(for: pending, snapshot: snapshot)
        if let overflow {
            if await clickNativeOverflow(at: overflow.point), let revealed = await settledAccessibilitySnapshot() {
                await placeSupplementalDividers(pending, snapshot: revealed)
            }
        } else {
            await placeSupplementalDividers(pending, snapshot: snapshot)
        }
        if let overflow {
            restoreControls()
            await restoreNativeOverflowPresentation(overflow)
        }
    }

    @available(macOS 27, *)
    private func prepareNativeOverflowPresentation(
        for controls: [ControlItem], snapshot: MenuBarAccessibilitySnapshot, requiredItemIDs: Set<UUID> = []
    ) async -> MenuBarAccessibility.NativeOverflowPresentation? {
        let identifiers = Set(controls.flatMap { $0.supplementalIdentifiers + [$0.accessibilityIdentifier] })
        let frames = snapshot.items.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier && identifiers.contains($0.accessibilityIdentifier ?? "")
        }.compactMap(\.frame)
        let overlaps = frames.enumerated().contains { index, frame in
            frames.dropFirst(index + 1).contains { frame.intersects($0) }
        }
        let missingGeometry = requiredItemIDs.contains { id in
            snapshot.items.first(where: { $0.id == id })?.frame == nil
        }
        guard
            overlaps || missingGeometry,
            let screen = NSScreen.main,
            let agent = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.MenuBarAgent" })
        else { return nil }
        let display = CGDisplayBounds(screen.displayID)
        let bar = CGRect(x: display.minX, y: display.minY, width: display.width, height: screen.getMenuBarHeight() ?? 0)
        return await accessibility.prepareNativeOverflowPresentation(processID: agent.processIdentifier, menuBarBounds: bar)
    }

    @available(macOS 27, *)
    private func restoreNativeOverflowPresentation(_ overflow: MenuBarAccessibility.NativeOverflowPresentation) async {
        // Cancellation must not prevent the restoring click. Await this cleanup
        // task so it cannot outlive the operation. Call after restoring divider
        // lengths, which must settle before restoring and rechecking overflow.
        await Task { @MainActor in
            for attempt in 0...2 {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
                guard let point = await accessibility.nativeOverflowRestorationPoint(overflow.token) else { break }
                guard attempt < 2 else {
                    Logger.itemManager.error("Native menu-bar overflow did not return to its preceding state")
                    break
                }
                guard await clickNativeOverflow(at: point) else { break }
            }
            await accessibility.endNativeOverflowPresentation(overflow.token)
        }.value
    }

    @available(macOS 27, *)
    private func clickNativeOverflow(at point: CGPoint) async -> Bool {
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        guard
            let appState, let cursor = MouseCursor.locationCoreGraphics,
            CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: modifiers),
            !CGEventSource.buttonState(.combinedSessionState, button: .left),
            !CGEventSource.buttonState(.combinedSessionState, button: .right)
        else { return false }
        appState.eventManager.stopAll()
        MouseCursor.hide()
        defer {
            MouseCursor.warp(to: cursor)
            MouseCursor.show()
            appState.eventManager.startAll()
        }
        do {
            try await MenuBarItemClick.perform(at: point, button: .left)
            // Allow the posted mouse-up to reach MenuBarAgent before warping
            // the pointer away from its toggle.
            try await Task.sleep(for: .milliseconds(50))
            return true
        } catch {
            Logger.itemManager.error("Could not toggle native menu-bar overflow: \(error)")
            return false
        }
    }

    @available(macOS 27, *)
    private func placeSupplementalDividers(_ pending: [ControlItem], snapshot: MenuBarAccessibilitySnapshot) async {
        guard let appState else { return }
        applyAccessibleSnapshot(snapshot)
        let ownItems = snapshot.items.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        for control in pending {
            guard var target = ownItems.first(where: { $0.accessibilityIdentifier == control.accessibilityIdentifier }) else { return }
            // Work outward from the delimiter. Moving every spacer directly
            // before it would dismantle an already-correct group on each retry.
            for identifier in control.supplementalIdentifiers.reversed() {
                guard let spacer = ownItems.first(where: { $0.accessibilityIdentifier == identifier }) else { return }
                do {
                    try await move(item: MenuBarItem(accessibleItem: spacer), to: .leftOfItem(MenuBarItem(accessibleItem: target)))
                    target = spacer
                } catch is CancellationError {
                    return
                } catch {
                    Logger.itemManager.error("Could not place section spacer: \(error)")
                    return
                }
            }
        }
        let placed = await accessibilitySnapshot()
        guard placed.isComplete, !Task.isCancelled, let screen = NSScreen.main else { return }
        let bounds = CGDisplayBounds(screen.displayID)
        for control in pending {
            let identifiers = control.supplementalIdentifiers + [control.accessibilityIdentifier]
            let ordered = identifiers.compactMap { identifier in
                placed.items.first { $0.processID == ProcessInfo.processInfo.processIdentifier && $0.accessibilityIdentifier == identifier }
            }
            guard ordered.count == identifiers.count else { return }
            for (first, second) in zip(ordered, ordered.dropFirst()) {
                guard AccessibleMenuBarItem.hasPlacement(
                    itemID: first.id, targetID: second.id, placement: .before, items: placed.items, displayBounds: bounds
                ) else { return }
            }
        }
        applyAccessibleSnapshot(placed)
        // Capture while the real icons are still available. The image cache keeps
        // these images when the next snapshot reports overflow without geometry.
        await appState.imageCache.updateCacheWithoutChecks(sections: MenuBarSection.Name.allCases)
        for control in pending { control.finishSupplementalPlacement() }
    }

    private func settledAccessibilitySnapshot() async -> MenuBarAccessibilitySnapshot? {
        var previousGeometry: [UUID: CGRect]?
        for attempt in 0..<5 {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return nil }
            let snapshot = await accessibilitySnapshot(discoverAllCandidates: attempt == 0)
            guard !Task.isCancelled else { return nil }
            guard snapshot.isComplete else {
                previousGeometry = nil
                continue
            }
            let geometry = Dictionary(snapshot.items.map { ($0.id, $0.frame ?? .null) }, uniquingKeysWith: { first, _ in first })
            if geometry == previousGeometry { return snapshot }
            previousGeometry = geometry
        }
        return nil
    }

    /// A presentation gets a fresh image of overflow items. macOS 26 can capture
    /// their host windows directly; macOS 27 temporarily reveals hosted controls.
    func refreshImagesForPresentation() async {
        _ = await presentationCapture.value(for: true) { [weak self] in
            await self?.captureHiddenImagesForPresentation()
        }
    }

    private func captureHiddenImagesForPresentation() async {
        guard let appState, appState.imageCache.refreshPermissionState() else { return }
        // Startup discovery can still be finishing when a panel is requested.
        for _ in 0..<20 where isReadingAccessibility {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        guard !Task.isCancelled, !isReadingAccessibility, !isMovingItem, !isRefreshingHiddenImages else { return }
        let controls = appState.menuBarManager.sections.map(\.controlItem).filter { $0.isSectionDivider && $0.isAddedToMenuBar }
        guard !controls.contains(where: \.needsSupplementalPlacement) else { return }
        isRefreshingHiddenImages = true
        defer { isRefreshingHiddenImages = false }
        Logger.itemManager.debug("Refreshing menu bar images for presentation")
        let screens = NSScreen.screens.map(\.frame)
        if #unavailable(macOS 27) {
            guard let snapshot = await settledAccessibilitySnapshot(), NSScreen.screens.map(\.frame) == screens else { return }
            applyAccessibleSnapshot(snapshot)
            await appState.imageCache.updateCacheWithoutChecks(sections: MenuBarSection.Name.allCases)
            return
        }
        do {
            for control in controls { control.setTemporarilyRevealed(true) }
            var didRestoreControls = false
            func restoreControls() {
                guard !didRestoreControls else { return }
                didRestoreControls = true
                // Read the current state on restoration: a user action during the
                // capture must not be overwritten with an earlier hiding state.
                for control in controls { control.setTemporarilyRevealed(false) }
                let invalidated = accessibleItems.compactMap(\.accessibleItem).map { $0.removingFrame() }
                applyAccessibleSnapshot(MenuBarAccessibilitySnapshot(items: invalidated, isComplete: true, unavailableProcessIDs: []))
                requestCacheRefresh()
            }
            defer { restoreControls() }
            guard let snapshot = await settledAccessibilitySnapshot(), NSScreen.screens.map(\.frame) == screens else { return }
            if #available(macOS 27, *), let overflow = await prepareNativeOverflowPresentation(for: controls, snapshot: snapshot) {
                if
                    await clickNativeOverflow(at: overflow.point),
                    let revealed = await settledAccessibilitySnapshot(),
                    NSScreen.screens.map(\.frame) == screens
                {
                    applyAccessibleSnapshot(revealed)
                    await appState.imageCache.updateCacheWithoutChecks(sections: MenuBarSection.Name.allCases)
                }
                restoreControls()
                await restoreNativeOverflowPresentation(overflow)
            } else {
                applyAccessibleSnapshot(snapshot)
                await appState.imageCache.updateCacheWithoutChecks(sections: MenuBarSection.Name.allCases)
            }
        }
        // Restore useful visible geometry before positioning the panel. If this
        // read is cancelled, invalidated frames remain unusable until discovery.
        if let snapshot = await settledAccessibilitySnapshot() {
            applyAccessibleSnapshot(snapshot)
        }
        Logger.itemManager.debug("Restored sections after presentation capture")
    }

    private func accessibilitySnapshot(discoverAllCandidates: Bool = false) async -> MenuBarAccessibilitySnapshot {
        let applications = NSWorkspace.shared.runningApplications.map {
            MenuBarAccessibility.Application(
                processID: $0.processIdentifier,
                bundleIdentifier: $0.bundleIdentifier,
                name: $0.localizedName ?? "Unknown",
                launchDate: $0.launchDate
            )
        }
        let local = localAccessibility.snapshot(application: MenuBarAccessibility.Application(
            processID: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: Constants.bundleIdentifier,
            name: "Vanilla",
            launchDate: NSRunningApplication.current.launchDate
        ))
        return await accessibility.snapshot(applications: applications, local: local, discoverAllCandidates: discoverAllCandidates)
    }

    private func applyAccessibleSnapshot(_ snapshot: MenuBarAccessibilitySnapshot) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let dividerFrames = snapshot.items.compactMap { item -> CGRect? in
            guard item.processID == ownPID, let identifier = item.accessibilityIdentifier else { return nil }
            guard identifier == "HItem" || identifier == "AHItem" || identifier.hasPrefix("HItem.Spacer.") || identifier.hasPrefix("AHItem.Spacer.") else { return nil }
            return item.frame
        }
        let snapshot = MenuBarAccessibilitySnapshot(
            items: snapshot.items.map { $0.processID == ownPID ? $0 : $0.validatingFrame(occludedBy: dividerFrames) },
            isComplete: snapshot.isComplete,
            unavailableProcessIDs: snapshot.unavailableProcessIDs
        )
        let previous = itemCache
        accessibleItems = snapshot.items.map { MenuBarItem(accessibleItem: $0) }
        guard let screen = NSScreen.main, let bar = menuBarRow(on: screen) else { return }
        // A native overflow panel's rows are on screen, but their horizontal
        // positions do not describe section boundaries in the actual menu bar.
        var items = accessibleItems.filter {
            if #available(macOS 27, *) { return $0.accessibleItem?.isLocated(in: bar) == true }
            return $0.accessibleItem?.isOnMenuBarRow(in: bar) == true
        }.sortedByOrderInMenuBar()
        let hidden = items.firstIndex(matching: .hiddenControlItem).map { items.remove(at: $0) }
        let alwaysHidden = items.firstIndex(matching: .alwaysHiddenControlItem).map { items.remove(at: $0) }
        var cache = ItemCache()
        if let hidden {
            cache = makeItemCache(hiddenControlItem: hidden, alwaysHiddenControlItem: alwaysHidden, otherItems: items)
        } else {
            // The old oversized separator can disappear on macOS 27. Keep known
            // membership until its replacement is available instead of clearing every item.
            for item in items {
                cache[itemCache.section(for: item) ?? .visible].append(item)
            }
        }
        let menuBarBounds = NSScreen.screens.compactMap { menuBarRow(on: $0) }
        let assignedItemIDs = Set(cache.allItems.compactMap { $0.accessibleItem?.id })
        // Retain section membership only for still-discovered items whose menu-bar
        // geometry is unavailable. Items on another display are not overflow here.
        // macOS 26 offscreen frames can already assign an item to a new section;
        // do not also retain that item in its previous section.
        for section in MenuBarSection.Name.allCases {
            cache[section] = AccessibleMenuBarItem.retainingUnpositionedItems(
                current: cache[section].compactMap(\.accessibleItem),
                previous: previous[section].compactMap(\.accessibleItem),
                snapshot: snapshot.items,
                menuBarBounds: menuBarBounds,
                assignedItemIDs: assignedItemIDs
            ).map { MenuBarItem(accessibleItem: $0) }
        }
        itemCache = cache
        Logger.itemManager.debug("Section counts: visible \(cache[.visible].count), hidden \(cache[.hidden].count), always hidden \(cache[.alwaysHidden].count)")
    }

    isolated deinit {
        performTeardown()
    }

    /// Cache for menu bar items.
    struct ItemCache: Hashable {
        /// All cached menu bar items, keyed by section.
        private var items = [MenuBarSection.Name: [MenuBarItem]]()

        /// All cached menu bar items.
        var allItems: [MenuBarItem] {
            MenuBarSection.Name.allCases.reduce(into: []) { result, section in
                result.append(contentsOf: self[section])
            }
        }

        /// The cached menu bar items managed by Ice.
        var managedItems: [MenuBarItem] {
            MenuBarSection.Name.allCases.reduce(into: []) { result, section in
                result.append(contentsOf: managedItems(for: section))
            }
        }

        /// Clears the cache.
        mutating func clear() {
            items.removeAll()
        }

        /// Returns the cached menu bar items managed by Ice for the given section.
        func managedItems(for section: MenuBarSection.Name) -> [MenuBarItem] {
            self[section].filter { item in
                // Filter out items that can't be hidden.
                guard item.canBeHidden else {
                    return false
                }

                if item.owningApplication == .current {
                    // Ice icon is the only item owned by Ice that should be included.
                    guard item.title == ControlItem.Identifier.iceIcon.rawValue else {
                        return false
                    }
                }

                return true
            }
        }

        /// Returns the name of the section for the given menu bar item.
        func section(for item: MenuBarItem) -> MenuBarSection.Name? {
            for (section, items) in self.items where items.contains(where: { $0.info == item.info }) {
                return section
            }
            return nil
        }

        /// Accesses the items in the given section.
        subscript(section: MenuBarSection.Name) -> [MenuBarItem] {
            get { items[section, default: []] }
            set { items[section] = newValue }
        }
    }

    /// Context for a temporarily shown menu bar item.
    private struct TempShownItemContext {
        /// The information associated with the item.
        let info: MenuBarItemInfo

        /// The destination to return the item to.
        let returnDestination: MoveDestination

        /// The window of the item's shown interface.
        var shownInterfaceWindow: WindowInfo?

        /// A Boolean value that indicates whether the menu bar item's interface is showing.
        var isShowingInterface: Bool {
            guard let currentWindow = shownInterfaceWindow.flatMap({ WindowInfo(windowID: $0.windowID) }) else {
                return false
            }
            // A status-item popover can remain visible without activating its app.
            return currentWindow.isOnScreen
        }
    }

    /// The manager's menu bar item cache.
    @Published private(set) var itemCache = ItemCache()

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Cached window identifiers for the most recent items.
    private var cachedItemWindowIDs = [CGWindowID]()

    /// Context values for the current temporarily shown items.
    private var tempShownItemContexts = [TempShownItemContext]()

    /// A timer that determines when to rehide the temporarily shown items.
    private let tempShownItemDelay = DelayedAction<Bool>()
    private let restorationRequests = CoalescingTask()

    /// The last time a menu bar item was moved.
    private var lastItemMoveStartDate: Date?

    /// The last time the mouse was moved.
    private var lastMouseMoveStartDate: Date?

    /// Counter to determine if a menu bar item, or group of menu bar
    /// items is being moved.
    private var itemMoveCount = 0

    /// A Boolean value that indicates whether a mouse button is down.
    private var isMouseButtonDown = false

    /// Event type mask for tracking mouse events.
    private let mouseTrackingMask: NSEvent.EventTypeMask = [
        .mouseMoved,
        .leftMouseDown,
        .rightMouseDown,
        .otherMouseDown,
        .leftMouseUp,
        .rightMouseUp,
        .otherMouseUp,
    ]

    /// A Boolean value that indicates whether a menu bar item, or
    /// group of menu bar items is being moved.
    var isMovingItem: Bool {
        itemMoveCount > 0
    }

    /// A Boolean value that indicates whether a menu bar item has
    /// recently moved.
    var itemHasRecentlyMoved: Bool {
        guard let lastItemMoveStartDate else {
            return false
        }
        return Date.now.timeIntervalSince(lastItemMoveStartDate) <= 1
    }

    /// A Boolean value that indicates whether the mouse has recently moved.
    var mouseHasRecentlyMoved: Bool {
        guard let lastMouseMoveStartDate else {
            return false
        }
        return Date.now.timeIntervalSince(lastMouseMoveStartDate) <= 1
    }

    /// Creates a manager with the given app state.
    init(appState: AppState) {
        self.appState = appState
    }

    /// Sets up the manager.
    func performSetup() {
        performTeardown()
        isSetUp = true
        configureCancellables()
        if !tempShownItemContexts.isEmpty { runTempShownItemTimer(for: 3) }
    }

    func performTeardown() {
        isSetUp = false
        cancellables.removeAll()
        cacheRequests.cancel()
        presentationCapture.cancel()
        pendingPanelAction?.cancel()
        pendingPanelAction = nil
        tempShownItemDelay.cancel()
        restorationRequests.cancel()
    }

    private func requestCacheRefresh() {
        cacheRequests.schedule { [weak self] in
            await self?.cacheItemsIfNeeded()
        }
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        Timer.publish(every: 5, on: .main, in: .default)
            .autoconnect()
            .merge(with: Just(.now))
            .sink { [weak self] _ in
                self?.requestCacheRefresh()
            }
            .store(in: &c)

        NSWorkspace.shared.publisher(for: \.runningApplications)
            .delay(for: 0.25, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.requestCacheRefresh()
            }
            .store(in: &c)

        Publishers.Merge(
            UniversalEventMonitor.publisher(for: mouseTrackingMask),
            RunLoopLocalEventMonitor.publisher(for: mouseTrackingMask, mode: .eventTracking)
        )
        .removeDuplicates()
        .sink { [weak self] event in
            guard let self else {
                return
            }
            switch event.type {
            case .mouseMoved:
                lastMouseMoveStartDate = .now
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                isMouseButtonDown = true
            case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                isMouseButtonDown = false
            default:
                break
            }
        }
        .store(in: &c)

        cancellables = c
    }
}

// MARK: - Cache Items

extension MenuBarItemManager {
    /// Logs a warning that the given menu bar item was not added to the cache.
    private func logNotCachedWarning(for item: MenuBarItem) {
        Logger.itemManager.warning("\(item.logString) was not cached")
    }

    /// Logs a reason for skipping the cache.
    private func logSkippingCache(reason: String) {
        Logger.itemManager.debug("Skipping menu bar item cache as \(reason)")
    }

    /// Caches the given menu bar items, without checking whether the control
    /// items are in the correct order.
    private func makeItemCache(
        hiddenControlItem: MenuBarItem,
        alwaysHiddenControlItem: MenuBarItem?,
        otherItems: [MenuBarItem]
    ) -> ItemCache {
        Logger.itemManager.debug("Caching menu bar items")

        let predicates = Predicates.sectionPredicates(
            hiddenControlItem: hiddenControlItem,
            alwaysHiddenControlItem: alwaysHiddenControlItem
        )

        var cache = ItemCache()
        var tempShownItems = [(MenuBarItem, MoveDestination)]()

        for item in otherItems {
            if let context = tempShownItemContexts.first(where: { $0.info == item.info }) {
                // Keep track of temporarily shown items and their return destinations separately.
                // We want to cache them as if they were in their original locations. Once all other
                // items are cached, use the return destinations to insert the items into the cache
                // at the correct position.
                tempShownItems.append((item, context.returnDestination))
            } else if predicates.isInVisibleSection(item) {
                cache[.visible].append(item)
            } else if predicates.isInHiddenSection(item) {
                cache[.hidden].append(item)
            } else if predicates.isInAlwaysHiddenSection(item) {
                cache[.alwaysHidden].append(item)
            } else {
                logNotCachedWarning(for: item)
            }
        }

        for (item, destination) in tempShownItems {
            switch destination {
            case .leftOfItem(let targetItem):
                switch targetItem.info {
                case .hiddenControlItem:
                    cache[.hidden].append(item)
                case .alwaysHiddenControlItem:
                    cache[.alwaysHidden].append(item)
                default:
                    if
                        let section = cache.section(for: targetItem),
                        let index = cache[section].firstIndex(matching: targetItem.info)
                    {
                        let clampedIndex = index.clamped(to: cache[section].startIndex...cache[section].endIndex)
                        cache[section].insert(item, at: clampedIndex)
                    }
                }
            case .rightOfItem(let targetItem):
                switch targetItem.info {
                case .hiddenControlItem:
                    cache[.visible].insert(item, at: 0)
                case .alwaysHiddenControlItem:
                    cache[.hidden].insert(item, at: 0)
                default:
                    if
                        let section = cache.section(for: targetItem),
                        let index = cache[section].firstIndex(matching: targetItem.info)
                    {
                        let clampedIndex = (index - 1).clamped(to: cache[section].startIndex...cache[section].endIndex)
                        cache[section].insert(item, at: clampedIndex)
                    }
                }
            }
        }

        return cache
    }

    /// Caches the current menu bar items if needed, ensuring that the control
    /// items are in the correct order.
    func cacheItemsIfNeeded() async {
        await cacheAccessibleItems()
    }
}

// MARK: - Menu Bar Item Events -

extension MenuBarItemManager {
    /// An error that can occur during menu bar item event operations.
    struct EventError: Error, CustomStringConvertible, LocalizedError {
        /// Error codes within the domain of menu bar item event errors.
        enum ErrorCode: Int, CustomStringConvertible {
            /// An operation could not be completed.
            case couldNotComplete

            /// The creation of a menu bar item event failed.
            case eventCreationFailure

            /// The shared app state is invalid or could not be found.
            case invalidAppState

            /// An event source could not be created or is otherwise invalid.
            case invalidEventSource

            /// The location of the mouse cursor is invalid or could not be found.
            case invalidCursorLocation

            /// A menu bar item is invalid.
            case invalidItem

            /// A menu bar item cannot be moved.
            case notMovable

            /// A menu bar item event operation timed out.
            case eventOperationTimeout

            /// A menu bar item frame check timed out.
            case frameCheckTimeout

            /// An operation timed out.
            case otherTimeout

            /// Description of the code for debugging purposes.
            var description: String {
                switch self {
                case .couldNotComplete: "couldNotComplete"
                case .eventCreationFailure: "eventCreationFailure"
                case .invalidAppState: "invalidAppState"
                case .invalidEventSource: "invalidEventSource"
                case .invalidCursorLocation: "invalidCursorLocation"
                case .invalidItem: "invalidItem"
                case .notMovable: "notMovable"
                case .eventOperationTimeout: "eventOperationTimeout"
                case .frameCheckTimeout: "frameCheckTimeout"
                case .otherTimeout: "otherTimeout"
                }
            }

            /// A string to use for logging purposes.
            var logString: String {
                "\(self) (rawValue: \(rawValue))"
            }
        }

        /// The error code of this error.
        let code: ErrorCode

        /// The error's menu bar item.
        let item: MenuBarItem

        /// The message associated with this error.
        var message: String {
            switch code {
            case .couldNotComplete:
                "Could not complete event operation for \"\(item.displayName)\""
            case .eventCreationFailure:
                "Failed to create event for \"\(item.displayName)\""
            case .invalidAppState:
                "Invalid app state for \"\(item.displayName)\""
            case .invalidEventSource:
                "Invalid event source for \"\(item.displayName)\""
            case .invalidCursorLocation:
                "Invalid cursor location for \"\(item.displayName)\""
            case .invalidItem:
                "\"\(item.displayName)\" is invalid"
            case .notMovable:
                "\"\(item.displayName)\" is not movable"
            case .eventOperationTimeout:
                "Event operation timed out for \"\(item.displayName)\""
            case .frameCheckTimeout:
                "Frame check timed out for \"\(item.displayName)\""
            case .otherTimeout:
                "Operation timed out for \"\(item.displayName)\""
            }
        }

        /// Description of the error for debugging purposes.
        var description: String {
            var parameters = [String]()
            parameters.append("code: \(code.logString)")
            parameters.append("item: \(item.logString)")
            return "\(Self.self)(\(parameters.joined(separator: ", ")))"
        }

        /// Description of the error for display purposes.
        var errorDescription: String? {
            message
        }

        /// Suggestion for recovery from the error.
        var recoverySuggestion: String? {
            "Please try again. If the error persists, please file a bug report."
        }
    }
}

// MARK: - Async Waiters

extension MenuBarItemManager {
    /// Waits asynchronously for the given operation to complete.
    /// 
    /// - Parameters:
    ///   - timeout: Amount of time to wait before throwing an error.
    ///   - operation: The operation to perform.
    private func waitWithTask(timeout: Duration?, operation: @MainActor @escaping @Sendable () async throws -> Void) async throws {
        let task = if let timeout {
            Task(timeout: timeout, operation: operation)
        } else {
            Task(operation: operation)
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Waits asynchronously for all menu bar items to stop moving.
    ///
    /// - Parameter timeout: Amount of time to wait before throwing an error.
    func waitForItemsToStopMoving(timeout: Duration? = nil) async throws {
        try await waitWithTask(timeout: timeout) { [weak self] in
            guard let self else {
                return
            }
            while isMovingItem {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    /// Waits asynchronously for the mouse to stop moving.
    ///
    /// - Parameters:
    ///   - threshold: A threshold to use to determine whether the mouse has stopped moving.
    ///   - timeout: Amount of time to wait before throwing an error.
    func waitForMouseToStopMoving(threshold: TimeInterval = 0.1, timeout: Duration? = nil) async throws {
        try await waitWithTask(timeout: timeout) { [weak self] in
            guard let self else {
                return
            }
            while true {
                try Task.checkCancellation()
                guard let date = lastMouseMoveStartDate else {
                    break
                }
                if Date.now.timeIntervalSince(date) > threshold {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    /// Waits asynchronously until no modifier keys are pressed.
    ///
    /// - Parameter timeout: Amount of time to wait before throwing an error.
    func waitForNoModifiersPressed(timeout: Duration? = nil) async throws {
        try await waitWithTask(timeout: timeout) {
            // Return early if no flags are pressed.
            if NSEvent.modifierFlags.isEmpty {
                return
            }

            var cancellable: AnyCancellable?

            await withCheckedContinuation { continuation in
                cancellable = Publishers.Merge(
                    UniversalEventMonitor.publisher(for: .flagsChanged),
                    RunLoopLocalEventMonitor.publisher(for: .flagsChanged, mode: .eventTracking)
                )
                .removeDuplicates()
                .sink { _ in
                    if NSEvent.modifierFlags.isEmpty {
                        cancellable?.cancel()
                        continuation.resume()
                    }
                }
            }
        }
    }
}

// MARK: - Move Items

extension MenuBarItemManager {
    /// A destination that a menu bar item can be moved to.
    enum MoveDestination {
        /// The menu bar item will be moved to the left of the given menu bar item.
        case leftOfItem(MenuBarItem)

        /// The menu bar item will be moved to the right of the given menu bar item.
        case rightOfItem(MenuBarItem)

        /// A string to use for logging purposes.
        var logString: String {
            switch self {
            case .leftOfItem(let item): "left of \(item.logString)"
            case .rightOfItem(let item): "right of \(item.logString)"
            }
        }
    }

    /// Returns the current frame for the given item.
    ///
    /// - Parameter item: The item to return the current frame for.
    private func getCurrentFrame(for item: MenuBarItem) -> CGRect? {
        guard let windowID = item.windowID, let frame = Bridging.getWindowFrame(for: windowID) else {
            Logger.itemManager.error("Couldn't get current frame for \(item.logString)")
            return nil
        }
        return frame
    }

    /// Returns the end point for moving an item to the given destination.
    ///
    /// - Parameter destination: The destination to return the end point for.
    private func getEndPoint(for destination: MoveDestination) throws -> CGPoint {
        switch destination {
        case .leftOfItem(let targetItem):
            guard let currentFrame = getCurrentFrame(for: targetItem) else {
                throw EventError(code: .invalidItem, item: targetItem)
            }
            return CGPoint(x: currentFrame.minX, y: currentFrame.midY)
        case .rightOfItem(let targetItem):
            guard let currentFrame = getCurrentFrame(for: targetItem) else {
                throw EventError(code: .invalidItem, item: targetItem)
            }
            return CGPoint(x: currentFrame.maxX, y: currentFrame.midY)
        }
    }

    /// Returns the fallback point for returning the given item to its original
    /// position if a move fails.
    ///
    /// - Parameter item: The item to return the fallback point for.
    private func getFallbackPoint(for item: MenuBarItem) throws -> CGPoint {
        guard let currentFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }
        return CGPoint(x: currentFrame.midX, y: currentFrame.midY)
    }

    /// Returns the target item for the given destination.
    ///
    /// - Parameter destination: The destination to get the target item from.
    private func getTargetItem(for destination: MoveDestination) -> MenuBarItem {
        switch destination {
        case .leftOfItem(let targetItem), .rightOfItem(let targetItem): targetItem
        }
    }

    /// Returns a Boolean value that indicates whether the given item is in the
    /// correct position for the given destination.
    ///
    /// - Parameters:
    ///   - item: The item to check the position of.
    ///   - destination: The destination to compare the item's position against.
    private func itemHasCorrectPosition(item: MenuBarItem, for destination: MoveDestination) throws -> Bool {
        guard let currentFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }
        switch destination {
        case .leftOfItem(let targetItem):
            guard let currentTargetFrame = getCurrentFrame(for: targetItem) else {
                throw EventError(code: .invalidItem, item: targetItem)
            }
            return currentFrame.maxX == currentTargetFrame.minX
        case .rightOfItem(let targetItem):
            guard let currentTargetFrame = getCurrentFrame(for: targetItem) else {
                throw EventError(code: .invalidItem, item: targetItem)
            }
            return currentFrame.minX == currentTargetFrame.maxX
        }
    }

    /// Returns a Boolean value that indicates whether the given events have the
    /// same values for each integer value field.
    ///
    /// - Parameters:
    ///   - events: The events to compare.
    ///   - integerFields: An array of integer value fields to compare on each event.
    private nonisolated func eventsMatch(_ events: [CGEvent], by integerFields: [CGEventField]) -> Bool {
        var fieldValues = Set<[Int64]>()
        for event in events {
            let values = integerFields.map(event.getIntegerValueField)
            fieldValues.insert(values)
            if fieldValues.count != 1 {
                return false
            }
        }
        return true
    }

    /// Posts an event to the given event tap location.
    ///
    /// - Parameters:
    ///   - event: The event to post.
    ///   - location: The event tap location to post the event to.
    private nonisolated func postEvent(_ event: CGEvent, to location: EventTap.Location) {
        Logger.itemManager.debug("Posting \(event.type.logString) to \(location.logString)")
        switch location {
        case .hidEventTap:
            event.post(tap: .cghidEventTap)
        case .sessionEventTap:
            event.post(tap: .cgSessionEventTap)
        case .annotatedSessionEventTap:
            event.post(tap: .cgAnnotatedSessionEventTap)
        case .pid(let pid):
            event.postToPid(pid)
        }
    }

    /// Posts an event to the given event tap location and waits until it is
    /// received before returning.
    ///
    /// - Parameters:
    ///   - event: The event to post.
    ///   - location: The event tap location to post the event to.
    ///   - item: The menu bar item that the event affects.
    private func postEventAndWaitToReceive(
        _ event: CGEvent,
        to location: EventTap.Location,
        item: MenuBarItem
    ) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let eventTap = EventTap(
                options: .listenOnly,
                location: location,
                place: .tailAppendEventTap,
                types: [event.type]
            ) { [weak self] proxy, type, rEvent in
                guard let self else {
                    proxy.disable()
                    return nil
                }

                // Reenable the tap if disabled by the system.
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }

                // Verify that the received event was the sent event.
                guard eventsMatch([rEvent, event], by: CGEventField.menuBarItemEventFields) else {
                    return nil
                }

                // Ensure the tap is enabled, preventing multiple calls to resume().
                guard proxy.isEnabled else {
                    Logger.itemManager.debug("Event tap \"\(proxy.label)\" is disabled (item: \(item.logString))")
                    return nil
                }

                Logger.itemManager.debug("Received \(type.logString) at \(location.logString) (item: \(item.logString))")

                // Disable the tap and resume the continuation.
                proxy.disable()
                continuation.resume()

                return nil
            }

            eventTap.enable(timeout: .milliseconds(50)) {
                Logger.itemManager.error("Event tap \"\(eventTap.label)\" timed out (item: \(item.logString))")
                eventTap.disable()
                continuation.resume(throwing: EventError(code: .eventOperationTimeout, item: item))
            }

            // Post the event to the location.
            postEvent(event, to: location)
        }
    }

    /// Does a lot of weird magic to make a menu bar item receive an event.
    ///
    /// - Parameters:
    ///   - event: The event to send.
    ///   - firstLocation: The first location to send the event to.
    ///   - secondLocation: The second location to send the event to.
    ///   - item: The menu bar item that the event affects.
    private func scrombleEvent(
        _ event: CGEvent,
        from firstLocation: EventTap.Location,
        to secondLocation: EventTap.Location,
        item: MenuBarItem
    ) async throws {
        // Create a null event and assign it unique user data.
        guard let nullEvent = CGEvent(source: nil) else {
            throw EventError(code: .eventCreationFailure, item: item)
        }
        let nullUserData = Int64(truncatingIfNeeded: Int(bitPattern: ObjectIdentifier(nullEvent)))
        nullEvent.setIntegerValueField(.eventSourceUserData, value: nullUserData)

        return try await withCheckedThrowingContinuation { continuation in
            // Create an event tap for the null event at the first location.
            // This tap throws away all events it receives.
            let eventTap1 = EventTap(
                label: "EventTap 1",
                options: .defaultTap,
                location: firstLocation,
                place: .tailAppendEventTap,
                types: [nullEvent.type]
            ) { [weak self] proxy, type, rEvent in
                guard let self else {
                    proxy.disable()
                    return nil
                }

                // Reenable the tap if disabled by the system.
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }

                // Verify that this is the null event.
                guard rEvent.getIntegerValueField(.eventSourceUserData) == nullUserData else {
                    return nil
                }

                // Disable the tap and post the real event to the second location.
                proxy.disable()
                postEvent(event, to: secondLocation)

                return nil
            }

            // Create an event tap for the real event at the second location.
            // This tap can listen for events, but cannot alter or discard them.
            let eventTap2 = EventTap(
                label: "EventTap 2",
                options: .listenOnly,
                location: secondLocation,
                place: .tailAppendEventTap,
                types: [event.type]
            ) { [weak self] proxy, type, rEvent in
                guard let self else {
                    proxy.disable()
                    return nil
                }

                // Reenable the tap if disabled by the system.
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }

                // Verify that the received event was the sent event.
                guard eventsMatch([rEvent, event], by: CGEventField.menuBarItemEventFields) else {
                    return nil
                }

                // Ensure the tap is enabled, preventing multiple calls to resume().
                guard proxy.isEnabled else {
                    Logger.itemManager.debug("Event tap \"\(proxy.label)\" is disabled (item: \(item.logString))")
                    return nil
                }

                // Disable the tap, post the event to the first location, and resume
                // the continuation.
                proxy.disable()
                postEvent(event, to: firstLocation)
                continuation.resume()

                return nil
            }

            // Enable both taps, with a timeout on the second tap.
            eventTap1.enable()
            eventTap2.enable(timeout: .milliseconds(50)) {
                Logger.itemManager.error("Event tap \"\(eventTap2.label)\" timed out (item: \(item.logString))")
                eventTap1.disable()
                eventTap2.disable()
                continuation.resume(throwing: EventError(code: .eventOperationTimeout, item: item))
            }

            // Post the null event to the first location.
            postEvent(nullEvent, to: firstLocation)
        }
    }

    /// Does a lot of weird magic to make a menu bar item receive an event, then
    /// waits for the frame of the given menu bar item to change before returning.
    ///
    /// - Parameters:
    ///   - event: The event to send.
    ///   - firstLocation: The first location to send the event to.
    ///   - secondLocation: The second location to send the event to.
    ///   - item: The item whose frame should be observed.
    private func scrombleEvent(
        _ event: CGEvent,
        from firstLocation: EventTap.Location,
        to secondLocation: EventTap.Location,
        waitingForFrameChangeOf item: MenuBarItem
    ) async throws {
        guard let currentFrame = getCurrentFrame(for: item) else {
            try await scrombleEvent(event, from: firstLocation, to: secondLocation, item: item)
            Logger.itemManager.warning("Couldn't get menu bar item frame for \(item.logString), so using fixed delay")
            // This will be slow, but subsequent events will have a better chance of succeeding.
            try await Task.sleep(for: .milliseconds(50))
            return
        }
        try await scrombleEvent(event, from: firstLocation, to: secondLocation, item: item)
        try await waitForFrameChange(of: item, initialFrame: currentFrame, timeout: .milliseconds(50))
    }

    /// Waits for a menu bar item's frame to change from an initial frame.
    ///
    /// - Parameters:
    ///   - item: The item whose frame should be observed.
    ///   - initialFrame: An initial frame to compare the item's frame against.
    ///   - timeout: The amount of time to wait before throwing a timeout error.
    private func waitForFrameChange(of item: MenuBarItem, initialFrame: CGRect, timeout: Duration) async throws {
        struct FrameCheckCancellationError: Error { }

        let frameCheckTask = Task(timeout: timeout) {
            while true {
                try Task.checkCancellation()
                guard let currentFrame = await self.getCurrentFrame(for: item) else {
                    throw FrameCheckCancellationError()
                }
                if currentFrame != initialFrame {
                    Logger.itemManager.debug("Menu bar item frame for \(item.logString) has changed to \(NSStringFromRect(currentFrame))")
                    return
                }
            }
        }
        do {
            try await frameCheckTask.value
        } catch is FrameCheckCancellationError {
            Logger.itemManager.warning("Menu bar item frame check for \(item.logString) was cancelled, so using fixed delay")
            // This will be slow, but subsequent events will have a better chance of succeeding.
            try await Task.sleep(for: .milliseconds(50))
        } catch is TaskTimeoutError {
            throw EventError(code: .frameCheckTimeout, item: item)
        }
    }

    /// Permits all events for an event source during the given suppression states,
    /// suppressing local events for the given interval.
    private func permitAllEvents(
        for stateID: CGEventSourceStateID,
        during states: [CGEventSuppressionState],
        suppressionInterval: TimeInterval,
        item: MenuBarItem
    ) throws {
        guard let source = CGEventSource(stateID: stateID) else {
            throw EventError(code: .invalidEventSource, item: item)
        }
        for state in states {
            source.setLocalEventsFilterDuringSuppressionState(.permitAllEvents, state: state)
        }
        source.localEventsSuppressionInterval = suppressionInterval
    }

    /// Tries to wake up the given item if it is not responding to events.
    private func wakeUpItem(_ item: MenuBarItem) async throws {
        Logger.itemManager.debug("Attempting to wake up \(item.logString)")

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw EventError(code: .invalidEventSource, item: item)
        }
        guard let currentFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }

        guard
            let mouseDownEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseDown),
                location: CGPoint(x: currentFrame.midX, y: currentFrame.midY),
                item: item,
                pid: item.ownerPID,
                source: source
            ),
            let mouseUpEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseUp),
                location: CGPoint(x: currentFrame.midX, y: currentFrame.midY),
                item: item,
                pid: item.ownerPID,
                source: source
            )
        else {
            throw EventError(code: .eventCreationFailure, item: item)
        }

        try await scrombleEvent(
            mouseDownEvent,
            from: .pid(item.ownerPID),
            to: .sessionEventTap,
            item: item
        )
        try await scrombleEvent(
            mouseUpEvent,
            from: .pid(item.ownerPID),
            to: .sessionEventTap,
            item: item
        )
    }

    /// Moves a menu bar item to the given destination, without restoring the mouse
    /// pointer to its initial location.
    ///
    /// - Parameters:
    ///   - item: A menu bar item to move.
    ///   - destination: A destination to move the menu bar item.
    private func moveItemWithoutRestoringMouseLocation(_ item: MenuBarItem, to destination: MoveDestination) async throws {
        itemMoveCount += 1
        defer {
            itemMoveCount -= 1
        }

        guard item.isMovable else {
            throw EventError(code: .notMovable, item: item)
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw EventError(code: .invalidEventSource, item: item)
        }

        let startPoint = CGPoint(x: 20_000, y: 20_000)
        let endPoint = try getEndPoint(for: destination)
        let fallbackPoint = try getFallbackPoint(for: item)
        let targetItem = getTargetItem(for: destination)

        guard
            let mouseDownEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseDown),
                location: startPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            ),
            let mouseUpEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseUp),
                location: endPoint,
                item: targetItem,
                pid: item.ownerPID,
                source: source
            ),
            let fallbackEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseUp),
                location: fallbackPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            )
        else {
            throw EventError(code: .eventCreationFailure, item: item)
        }

        try permitAllEvents(
            for: .combinedSessionState,
            during: [
                .eventSuppressionStateRemoteMouseDrag,
                .eventSuppressionStateSuppressionInterval,
            ],
            suppressionInterval: 0,
            item: item
        )

        lastItemMoveStartDate = .now

        do {
            try await scrombleEvent(
                mouseDownEvent,
                from: .pid(item.ownerPID),
                to: .sessionEventTap,
                waitingForFrameChangeOf: item
            )
            try await scrombleEvent(
                mouseUpEvent,
                from: .pid(item.ownerPID),
                to: .sessionEventTap,
                waitingForFrameChangeOf: item
            )
        } catch {
            do {
                Logger.itemManager.debug("Posting fallback event for moving \(item.logString)")
                // Catch this, as we still want to throw the existing error if the fallback fails.
                try await postEventAndWaitToReceive(
                    fallbackEvent,
                    to: .sessionEventTap,
                    item: item
                )
            } catch {
                Logger.itemManager.error("Failed to post fallback event for moving \(item.logString)")
            }
            throw error
        }
    }

    /// Reads fresh AX geometry before dragging and verifies order after mouse-up.
    private func moveAccessibleItem(_ item: MenuBarItem, to destination: MoveDestination, timeout: Duration = .seconds(2)) async throws {
        guard !isMovingAccessibleItem, !isRefreshingHiddenImages else { throw EventError(code: .invalidItem, item: item) }
        isMovingAccessibleItem = true
        itemMoveCount += 1
        defer {
            isMovingAccessibleItem = false
            itemMoveCount -= 1
            lastItemMoveStartDate = .now
        }
        try await withRevealedMenuBar(for: item) {
            try await performAccessibleMove(item, to: destination, timeout: timeout)
        }
    }

    private func performAccessibleMove(_ item: MenuBarItem, to destination: MoveDestination, timeout: Duration) async throws {
        let target = getTargetItem(for: destination)
        guard item.isMovable else { throw EventError(code: .notMovable, item: item) }
        guard let itemID = item.accessibleItem?.id, let targetID = target.accessibleItem?.id else {
            throw EventError(code: .invalidItem, item: item)
        }
        guard let appState else { throw EventError(code: .invalidAppState, item: item) }
        // Include mouse buttons: a layout drop can arrive before its release has
        // reached the global input state. Ignore Caps Lock, which is not a held key.
        let inputDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        while !CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: modifiers) ||
            CGEventSource.buttonState(.combinedSessionState, button: .left) ||
            CGEventSource.buttonState(.combinedSessionState, button: .right) {
            guard ContinuousClock.now < inputDeadline else { throw EventError(code: .eventOperationTimeout, item: item) }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await waitForMouseToStopMoving(timeout: .seconds(2))
        var snapshot = await accessibilitySnapshot()
        var restoreReveal: (() -> Void)?
        defer { restoreReveal?() }
        let dividers = appState.menuBarManager.sections.map(\.controlItem).filter { $0.isSectionDivider && $0.isAddedToMenuBar }
        let dividerIdentifiers = Set(dividers.flatMap { $0.supplementalIdentifiers + [$0.accessibilityIdentifier] })
        let targetsDivider = target.accessibleItem.map { $0.processID == ProcessInfo.processInfo.processIdentifier && dividerIdentifiers.contains($0.accessibilityIdentifier ?? "") } ?? false
        let sourceFrame = snapshot.items.first { $0.id == itemID }?.frame
        let destinationFrame = snapshot.items.first { $0.id == targetID }?.frame
        if (sourceFrame == nil || destinationFrame == nil || !item.isOnScreen || !target.isOnScreen || targetsDivider) && !dividers.contains(where: \.needsSupplementalPlacement) {
            // Internal spacer placement already runs with small dividers. Do
            // not interfere with that operation while it establishes order.
            let controls = dividers
            for control in controls { control.setTemporarilyRevealed(true) }
            restoreReveal = {
                for control in controls { control.setTemporarilyRevealed(false) }
                let invalidated = self.accessibleItems.compactMap(\.accessibleItem).map { $0.removingFrame() }
                self.applyAccessibleSnapshot(MenuBarAccessibilitySnapshot(items: invalidated, isComplete: true, unavailableProcessIDs: []))
                self.requestCacheRefresh()
            }
            guard let expanded = await settledAccessibilitySnapshot() else { throw EventError(code: .invalidItem, item: item) }
            snapshot = expanded
            applyAccessibleSnapshot(snapshot)
            if #available(macOS 27, *), let overflow = await prepareNativeOverflowPresentation(for: controls, snapshot: snapshot, requiredItemIDs: [itemID, targetID]) {
                // On a notched display, shrinking Vanilla's dividers can leave
                // source and target frames clamped beneath native overflow.
                // Restore divider lengths before closing overflow, including
                // when geometry validation, dragging, or cancellation throws.
                do {
                    guard
                        await clickNativeOverflow(at: overflow.point),
                        let revealed = await settledAccessibilitySnapshot()
                    else { throw EventError(code: .invalidItem, item: item) }
                    applyAccessibleSnapshot(revealed)
                    try await dragAccessibleItem(item, to: destination, snapshot: revealed, timeout: timeout)
                } catch {
                    restoreReveal?()
                    restoreReveal = nil
                    await restoreNativeOverflowPresentation(overflow)
                    throw error
                }
                restoreReveal?()
                restoreReveal = nil
                await restoreNativeOverflowPresentation(overflow)
                return
            }
        }
        try await dragAccessibleItem(item, to: destination, snapshot: snapshot, timeout: timeout)
    }

    private func dragAccessibleItem(
        _ item: MenuBarItem, to destination: MoveDestination, snapshot: MenuBarAccessibilitySnapshot, timeout: Duration, correctsGroupPlacement: Bool = true
    ) async throws {
        let target = getTargetItem(for: destination)
        guard let itemID = item.accessibleItem?.id, let targetID = target.accessibleItem?.id else {
            throw EventError(code: .invalidItem, item: item)
        }
        guard let appState else { throw EventError(code: .invalidAppState, item: item) }
        try Task.checkCancellation()
        guard
            snapshot.isComplete,
            let frame = snapshot.items.first(where: { $0.id == itemID })?.frame,
            let targetFrame = snapshot.items.first(where: { $0.id == targetID })?.frame,
            let screen = NSScreen.screens.first(where: { CGDisplayBounds($0.displayID).contains(frame) && CGDisplayBounds($0.displayID).contains(targetFrame) }),
            let cursor = MouseCursor.locationCoreGraphics
        else { throw EventError(code: .invalidItem, item: item) }
        let bounds = CGDisplayBounds(screen.displayID)
        let barBounds = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: screen.getMenuBarHeight() ?? 0)
        guard barBounds.contains(frame), barBounds.contains(targetFrame) else { throw EventError(code: .invalidItem, item: item) }
        let placement: AccessibleMenuBarItem.Placement = switch destination {
        case .leftOfItem: .before
        case .rightOfItem: .after
        }
        var sourceBoundaryID = itemID
        var targetBoundaryID = targetID
        var destinationFrame = targetFrame
        var dragFrame = frame
        var movesGroup = false
        if #available(macOS 27, *) {
            let sourceGroup = AccessibleMenuBarItem.movementGroup(containing: itemID, items: snapshot.items, menuBarBounds: barBounds)
            let targetGroup = AccessibleMenuBarItem.movementGroup(containing: targetID, items: snapshot.items, menuBarBounds: barBounds)
            if sourceGroup.contains(where: { $0.id == targetID }) { return }
            let sourceBoundary = placement == .before ? sourceGroup.last : sourceGroup.first
            let targetBoundary = placement == .before ? targetGroup.first : targetGroup.last
            guard let sourceBoundary, let targetBoundary, let boundaryFrame = targetBoundary.frame else {
                throw EventError(code: .invalidItem, item: item)
            }
            movesGroup = sourceGroup.count > 1
            dragFrame = sourceGroup.compactMap(\.frame).reduce(CGRect.null) { $0.union($1) }
            sourceBoundaryID = sourceBoundary.id
            targetBoundaryID = targetBoundary.id
            destinationFrame = boundaryFrame
        }
        // Coincident overflow proxies do not identify a usable source/target.
        // A destination inside the source's movement group was handled above.
        guard frame.maxX <= destinationFrame.minX || destinationFrame.maxX <= frame.minX else {
            throw EventError(code: .invalidItem, item: item)
        }
        if AccessibleMenuBarItem.hasPlacement(itemID: sourceBoundaryID, targetID: targetBoundaryID, placement: placement, items: snapshot.items, displayBounds: bounds) { return }
        let endX: CGFloat
        if #available(macOS 27, *) {
            let inset = min(1, destinationFrame.width / 4)
            endX = placement == .before ? destinationFrame.minX + inset : destinationFrame.maxX - inset
        } else {
            endX = placement == .before ? destinationFrame.minX - 1 : destinationFrame.maxX + 1
        }
        let end = CGPoint(x: endX, y: targetFrame.midY)
        guard bounds.contains(end) else { throw EventError(code: .invalidItem, item: item) }
        Logger.itemManager.debug("Dragging item \(itemID) relative to \(targetID): source \(NSStringFromRect(dragFrame)), target \(NSStringFromRect(destinationFrame))")
        var latest = snapshot
        do {
            appState.eventManager.stopAll()
            MouseCursor.hide()
            defer {
                MouseCursor.warp(to: cursor)
                MouseCursor.show()
                appState.eventManager.startAll()
            }
            try await MenuBarItemDrag.perform(from: CGPoint(x: dragFrame.midX, y: dragFrame.midY), to: end)
            let deadline = ContinuousClock.now.advanced(by: timeout)
            repeat {
                try await Task.sleep(for: .milliseconds(50))
                let updated = await accessibilitySnapshot()
                try Task.checkCancellation()
                guard AXIsProcessTrusted() else { throw EventError(code: .couldNotComplete, item: item) }
                if updated.isComplete {
                    latest = updated
                    applyAccessibleSnapshot(updated)
                    if AccessibleMenuBarItem.hasPlacement(itemID: sourceBoundaryID, targetID: targetBoundaryID, placement: placement, items: updated.items, displayBounds: bounds) {
                        return
                    }
                }
            } while ContinuousClock.now < deadline
        }
        // Linked instances can settle a slot beyond the requested neighbor.
        // Re-read the changed layout and permit one corrective drag, retaining
        // the same strict adjacency check. An unchanged position is not retried.
        if
            correctsGroupPlacement, movesGroup,
            let movedFrame = latest.items.first(where: { $0.id == itemID })?.frame,
            movedFrame != frame
        {
            try await dragAccessibleItem(item, to: destination, snapshot: latest, timeout: timeout, correctsGroupPlacement: false)
            return
        }
        let finalSource = latest.items.first(where: { $0.id == sourceBoundaryID })?.frame
        let finalTarget = latest.items.first(where: { $0.id == targetBoundaryID })?.frame
        Logger.itemManager.debug("Drag order was not confirmed: source \(String(describing: finalSource)), target \(String(describing: finalTarget))")
        throw EventError(code: .frameCheckTimeout, item: item)
    }

    /// Uses the outer edge of a divider group so a hidden item cannot land
    /// between the supplemental spacers and the main delimiter on macOS 27.
    func movementDestination(for section: MenuBarSection.Name) -> MoveDestination? {
        guard let appState, appState.menuBarManager.section(withName: section)?.isEnabled == true else { return nil }
        let dividerSection: MenuBarSection.Name = section == .visible ? .hidden : section
        guard let control = appState.menuBarManager.section(withName: dividerSection)?.controlItem else { return nil }
        var identifier = control.accessibilityIdentifier
        if #available(macOS 27, *), section != .visible {
            guard !control.needsSupplementalPlacement else { return nil }
            identifier = control.supplementalIdentifiers.first ?? identifier
        }
        let items = menuBarItems(onScreenOnly: false, activeSpaceOnly: true)
        guard let target = items.first(where: {
            if let accessible = $0.accessibleItem {
                return accessible.processID == ProcessInfo.processInfo.processIdentifier && accessible.accessibilityIdentifier == identifier
            }
            return $0.info.namespace == .ice && $0.info.title == identifier
        }) else { return nil }
        return section == .visible ? .rightOfItem(target) : .leftOfItem(target)
    }

    /// Moves a menu bar item to the given destination.
    ///
    /// - Parameters:
    ///   - item: A menu bar item to move.
    ///   - destination: A destination to move the menu bar item.
    func move(item: MenuBarItem, to destination: MoveDestination) async throws {
        if item.accessibleItem != nil {
            try await moveAccessibleItem(item, to: destination)
            return
        }
        if try itemHasCorrectPosition(item: item, for: destination) {
            Logger.itemManager.debug("\(item.logString) is already in the correct position")
            return
        }

        do {
            // Order of these waiters matters, as the modifiers could be released
            // while the mouse is still moving.
            try await waitForNoModifiersPressed()
            try await waitForMouseToStopMoving()
        } catch {
            throw EventError(code: .couldNotComplete, item: item)
        }

        Logger.itemManager.info("Moving \(item.logString) to \(destination.logString)")

        guard let appState else {
            throw EventError(code: .invalidAppState, item: item)
        }
        guard let cursorLocation = MouseCursor.locationCoreGraphics else {
            throw EventError(code: .invalidCursorLocation, item: item)
        }
        guard let initialFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }

        appState.eventManager.stopAll()
        defer {
            appState.eventManager.startAll()
        }

        MouseCursor.hide()

        defer {
            MouseCursor.warp(to: cursorLocation)
            MouseCursor.show()
        }

        // Item movement can occasionally fail. Retry up to a total of 5 attempts,
        // throwing the last attempt's error if it fails.
        for n in 1...5 {
            do {
                try await moveItemWithoutRestoringMouseLocation(item, to: destination)
                guard let newFrame = getCurrentFrame(for: item) else {
                    throw EventError(code: .invalidItem, item: item)
                }
                if newFrame != initialFrame {
                    Logger.itemManager.info("Successfully moved \(item.logString)")
                    break
                } else {
                    throw EventError(code: .couldNotComplete, item: item)
                }
            } catch where n < 5 {
                Logger.itemManager.warning("Attempt \(n) to move \(item.logString) failed (error: \(error))")
                try await wakeUpItem(item)
                Logger.itemManager.info("Retrying move of \(item.logString)")
                continue
            }
        }
    }

    /// Moves a menu bar item to the given destination and waits until the move
    /// completes before returning.
    /// 
    /// - Parameters:
    ///   - item: A menu bar item to move.
    ///   - destination: A destination to move the menu bar item.
    ///   - timeout: Amount of time to wait before throwing an error.
    func slowMove(item: MenuBarItem, to destination: MoveDestination, timeout: Duration = .seconds(1)) async throws {
        if item.accessibleItem != nil {
            // The Accessibility move already waits for verified neighboring positions.
            try await moveAccessibleItem(item, to: destination, timeout: timeout)
            return
        }
        itemMoveCount += 1
        defer {
            itemMoveCount -= 1
        }
        try await move(item: item, to: destination)
        let waitTask = Task(timeout: timeout) {
            while true {
                try Task.checkCancellation()
                if try await self.itemHasCorrectPosition(item: item, for: destination) {
                    return
                }
            }
        }
        do {
            try await waitTask.value
        } catch is TaskTimeoutError {
            throw EventError(code: .otherTimeout, item: item)
        }
    }
}

// MARK: - Click Items

extension MenuBarItemManager {
    /// Clicks the given menu bar item with the given mouse button.
    func click(item: MenuBarItem, with mouseButton: CGMouseButton) async throws {
        if let accessibleItem = item.accessibleItem {
            guard mouseButton == .left || mouseButton == .right else { throw EventError(code: .couldNotComplete, item: item) }
            if #unavailable(macOS 27) {
                try await clickVisibleAccessibleItem(item, with: mouseButton)
                return
            }
            let succeeded: Bool
            if accessibleItem.processID == ProcessInfo.processInfo.processIdentifier {
                succeeded = localAccessibility.performAction(itemID: accessibleItem.id, showMenu: mouseButton == .right)
            } else {
                succeeded = await accessibility.performAction(itemID: accessibleItem.id, showMenu: mouseButton == .right)
            }
            guard succeeded else { throw EventError(code: .couldNotComplete, item: item) }
            return
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw EventError(code: .invalidEventSource, item: item)
        }
        guard let cursorLocation = MouseCursor.locationCoreGraphics else {
            throw EventError(code: .invalidCursorLocation, item: item)
        }
        guard let currentFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }

        let buttonStates = mouseButton.buttonStates
        let clickPoint = CGPoint(x: currentFrame.midX, y: currentFrame.midY)

        guard
            let mouseDownEvent = CGEvent.menuBarItemEvent(
                type: .click(buttonStates.down),
                location: clickPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            ),
            let mouseUpEvent = CGEvent.menuBarItemEvent(
                type: .click(buttonStates.up),
                location: clickPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            ),
            let fallbackEvent = CGEvent.menuBarItemEvent(
                type: .click(buttonStates.up),
                location: clickPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            )
        else {
            throw EventError(code: .eventCreationFailure, item: item)
        }

        try permitAllEvents(
            for: .combinedSessionState,
            during: [
                .eventSuppressionStateRemoteMouseDrag,
                .eventSuppressionStateSuppressionInterval,
            ],
            suppressionInterval: 0,
            item: item
        )

        MouseCursor.hide()

        defer {
            MouseCursor.warp(to: cursorLocation)
            MouseCursor.show()
        }

        do {
            Logger.itemManager.info("Clicking \(item.logString) with \(mouseButton.logString)")
            try await postEventAndWaitToReceive(
                mouseDownEvent,
                to: .sessionEventTap,
                item: item
            )
            try await postEventAndWaitToReceive(
                mouseUpEvent,
                to: .sessionEventTap,
                item: item
            )
        } catch {
            do {
                Logger.itemManager.debug("Posting fallback event for clicking \(item.logString)")
                // Catch this, as we still want to throw the existing error if the fallback fails.
                try await postEventAndWaitToReceive(
                    fallbackEvent,
                    to: .sessionEventTap,
                    item: item
                )
            } catch {
                Logger.itemManager.error("Failed to post fallback event for clicking \(item.logString)")
            }
            throw error
        }
    }

    /// Hosted items on macOS 26 need the native bar onscreen for input, even
    /// though their offscreen images can be captured. Reveal through pointer
    /// motion before activation or restoration, then restore the pointer.
    /// Verified on 26.5; macOS 27 uses its existing Accessibility path.
    private func withRevealedMenuBar(
        for item: MenuBarItem, preserveMenuTracking: Bool = false, operation: () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard
            #unavailable(macOS 27), item.accessibleItem != nil,
            appState?.isActiveSpaceFullscreen == true,
            let screen = NSScreen.main,
            WindowInfo.getMenuBarWindow(for: screen.displayID) == nil
        else {
            try await operation()
            return
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        while !CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: modifiers) || isMouseButtonDown {
            guard ContinuousClock.now < deadline else { throw EventError(code: .eventOperationTimeout, item: item) }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard AXIsProcessTrusted(), let cursor = MouseCursor.locationCoreGraphics else {
            throw EventError(code: .invalidCursorLocation, item: item)
        }
        let bounds = CGDisplayBounds(screen.displayID)
        let space = Bridging.activeSpaceID
        MouseCursor.hide()
        defer {
            if preserveMenuTracking && !Task.isCancelled {
                // Retraction can obscure a newly opened third-party panel on
                // 26.5. Let its own tracking handle subsequent pointer motion.
                MouseCursor.warp(to: cursor)
            } else {
                // A warp alone leaves the system's hover state at the edge.
                // Restoration and cancellation must clear that state too.
                do {
                    try MenuBarItemClick.movePointer(to: cursor)
                } catch {
                    MouseCursor.warp(to: cursor)
                    Logger.itemManager.error("Could not restore pointer motion: \(error)")
                }
            }
            MouseCursor.show()
        }
        try Task.checkCancellation()
        try MenuBarItemClick.movePointer(to: CGPoint(x: bounds.minX + bounds.width * 0.75, y: bounds.minY))
        let revealDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while WindowInfo.getMenuBarWindow(for: screen.displayID) == nil {
            guard ContinuousClock.now < revealDeadline else { throw EventError(code: .eventOperationTimeout, item: item) }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard
            let snapshot = await settledAccessibilitySnapshot(),
            AXIsProcessTrusted(), Bridging.activeSpaceID == space,
            CGDisplayBounds(screen.displayID) == bounds
        else { throw EventError(code: .invalidItem, item: item) }
        try Task.checkCancellation()
        applyAccessibleSnapshot(snapshot)
        try await operation()
    }

    /// macOS 26's hosted status items need input at their visible position.
    /// Re-read geometry after temporary placement; the pre-move frame is stale.
    private func clickVisibleAccessibleItem(_ item: MenuBarItem, with button: CGMouseButton) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        while !CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: modifiers) || isMouseButtonDown {
            guard ContinuousClock.now < deadline else { throw EventError(code: .eventOperationTimeout, item: item) }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard
            let appState,
            let itemID = item.accessibleItem?.id,
            !isMovingAccessibleItem, !isRefreshingHiddenImages,
            let snapshot = await settledAccessibilitySnapshot(),
            let frame = snapshot.items.first(where: { $0.id == itemID })?.frame,
            !frame.isNull, !frame.isEmpty,
            NSScreen.screens.contains(where: { screen in
                let bounds = CGDisplayBounds(screen.displayID)
                let bar = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: screen.getMenuBarHeight() ?? 0)
                return bar.contains(frame)
            }),
            let cursor = MouseCursor.locationCoreGraphics
        else { throw EventError(code: .invalidItem, item: item) }
        guard
            CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: modifiers),
            !isMouseButtonDown
        else { throw EventError(code: .couldNotComplete, item: item) }
        appState.eventManager.stopAll()
        MouseCursor.hide()
        defer {
            MouseCursor.warp(to: cursor)
            MouseCursor.show()
            appState.eventManager.startAll()
        }
        try await MenuBarItemClick.perform(at: CGPoint(x: frame.midX, y: frame.midY), button: button)
        try await Task.sleep(for: .milliseconds(50))
    }
}

// MARK: - Temporarily Show Items

extension MenuBarItemManager {
    /// Gets the destination to return the given item to after it is temporarily shown.
    private func getReturnDestination(for item: MenuBarItem, in items: [MenuBarItem]) -> MoveDestination? {
        let info = item.info
        if let index = items.firstIndex(where: { $0.info == info }) {
            if items.indices.contains(index + 1) {
                return .leftOfItem(items[index + 1])
            } else if items.indices.contains(index - 1) {
                return .rightOfItem(items[index - 1])
            }
        }
        return nil
    }

    /// Restarts the restore deadline and keeps the subsequent work owned.
    private func runTempShownItemTimer(for interval: TimeInterval) {
        guard isSetUp else { return }
        Logger.itemManager.debug("Scheduling restoration of temporarily shown items after: \(interval)")
        tempShownItemDelay.cancel()
        tempShownItemDelay.schedule(key: true, after: .seconds(interval)) { [weak self] in
            self?.restorationRequests.schedule { [weak self] in
                await self?.rehideTempShownItems()
            }
        }
    }

    /// Lets a search or Vanilla Bar panel close before showing and clicking its item.
    func showItemAfterClosingPanel(_ item: MenuBarItem, mouseButton: CGMouseButton) {
        let previousAction = pendingPanelAction
        previousAction?.cancel()
        pendingPanelAction = Task { [weak self] in
            // A cancelled drag must release its input and restore the section
            // before the next activation reads geometry or starts moving.
            await previousAction?.value
            // Search accepts input before previews finish. Let the shared
            // capture restore divider/overflow state before activating a result.
            await self?.presentationCapture.waitForCompletion()
            do {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(25))
                while self?.isRestoringTempShownItems == true {
                    try await Task.sleep(for: .milliseconds(25))
                }
            } catch {
                return
            }
            guard let self, isSetUp, !Task.isCancelled else { return }
            isActivatingPanelItem = true
            defer { isActivatingPanelItem = false }
            if #available(macOS 27, *), item.accessibleItem != nil {
                // Semantic activation does not need a visible icon or its stale
                // pre-overflow coordinates. Keep it in this cancellable task.
                do {
                    try await click(item: item, with: mouseButton)
                } catch {
                    Logger.itemManager.error("Could not activate menu bar item: \(error)")
                }
            } else {
                await tempShowItem(item, mouseButton: mouseButton)
            }
        }
    }

    /// Shows and clicks an item, retaining its original position until restored.
    private func tempShowItem(_ item: MenuBarItem, mouseButton: CGMouseButton) async {
        do {
            try await withRevealedMenuBar(for: item, preserveMenuTracking: true) {
                await activateTempShownItem(item, mouseButton: mouseButton)
            }
        } catch is CancellationError {
            return
        } catch {
            Logger.itemManager.error("Could not reveal menu bar for activation: \(error)")
        }
    }

    private func activateTempShownItem(_ item: MenuBarItem, mouseButton: CGMouseButton) async {
        guard !Task.isCancelled else { return }
        if
            let latest = accessibleItems.first(where: { $0.id == item.id }),
            latest.isOnScreen
        {
            do {
                try await click(item: latest, with: mouseButton)
            } catch is CancellationError {
                return
            } catch {
                Logger.itemManager.error("Could not activate visible item: \(error)")
            }
            return
        }

        guard
            let appState,
            let screen = NSScreen.main,
            let applicationMenuFrame = appState.menuBarManager.getApplicationMenuFrame(for: screen.displayID)
        else {
            Logger.itemManager.warning("No application menu frame, so not showing \(item.logString)")
            return
        }

        Logger.itemManager.info("Temporarily showing \(item.logString)")

        var items = menuBarItems(onScreenOnly: false, activeSpaceOnly: true)

        guard let destination = getReturnDestination(for: item, in: items) else {
            Logger.itemManager.warning("No return destination for \(item.logString)")
            return
        }

        guard let dividerIndex = items.firstIndex(where: { $0.info == .hiddenControlItem }) else { return }
        items.removeFirst(dividerIndex + 1)
        // Remove all offscreen items.
        items.trimPrefix { !$0.isOnScreen }

        let maxX = if let rightArea = screen.auxiliaryTopRightArea {
            max(rightArea.minX + 20, applicationMenuFrame.maxX)
        } else {
            applicationMenuFrame.maxX
        }

        // Remove items until we have enough room to show this item.
        items.trimPrefix { $0.frame.minX - item.frame.width <= maxX }

        // Control Center's recording indicator moves to the left edge when
        // sections expand on macOS 26.5. It cannot anchor a visible placement.
        guard let targetItem = items.first(where: \.canBeHidden) else {
            let alert = NSAlert()
            alert.messageText = "Not enough room to show \"\(item.displayName)\""
            alert.runModal()
            return
        }

        // Record before moving: cancellation may arrive after mouse-up, when
        // the item has moved but placement verification has not completed.
        if !tempShownItemContexts.contains(where: { $0.info == item.info }) {
            tempShownItemContexts.append(TempShownItemContext(
                info: item.info,
                returnDestination: destination,
                shownInterfaceWindow: nil
            ))
        }
        defer {
            runTempShownItemTimer(for: appState.settingsManager.advancedSettingsManager.tempShowInterval)
        }
        do {
            try await slowMove(item: item, to: .leftOfItem(targetItem))
            // Moving can introduce hosted status windows and drag images.
            // Only windows introduced by the subsequent click are interfaces.
            let initialWindows = Set(WindowInfo.getOnScreenWindows().map(\.windowID))
            try await click(item: item, with: mouseButton)
            let window = await waitForItemInterface(item, excluding: initialWindows)
            if let index = tempShownItemContexts.firstIndex(where: { $0.info == item.info }) {
                tempShownItemContexts[index].shownInterfaceWindow = window
            }
        } catch is CancellationError {
            return
        } catch {
            Logger.itemManager.error("Could not temporarily activate item: \(error)")
        }
    }

    private func waitForItemInterface(_ item: MenuBarItem, excluding existingWindows: Set<CGWindowID>) async -> WindowInfo? {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        repeat {
            guard !Task.isCancelled else { return nil }
            if let window = WindowInfo.getOnScreenWindows().first(where: {
                $0.ownerPID == item.ownerPID && !existingWindows.contains($0.windowID) &&
                $0.layer != CGWindowLevelForKey(.statusWindow) &&
                $0.layer != CGWindowLevelForKey(.draggingWindow)
            }) {
                return window
            }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
        } while ContinuousClock.now < deadline
        return nil
    }

    /// Rehides all temporarily shown items.
    ///
    /// If an item is currently showing its interface, this method waits for the
    /// interface to close before hiding the items.
    private func rehideTempShownItems() async {
        guard isSetUp, !Task.isCancelled else { return }
        guard !isActivatingPanelItem, !isMovingAccessibleItem else {
            runTempShownItemTimer(for: 3)
            return
        }
        isRestoringTempShownItems = true
        defer { isRestoringTempShownItems = false }
        itemMoveCount += 1
        defer {
            itemMoveCount -= 1
        }

        guard !tempShownItemContexts.isEmpty else {
            return
        }

        guard !isMouseButtonDown else {
            Logger.itemManager.debug("Mouse button is down, so waiting to rehide")
            runTempShownItemTimer(for: 3)
            return
        }
        guard !tempShownItemContexts.contains(where: { $0.isShowingInterface }) else {
            Logger.itemManager.debug("Menu bar item interface is shown, so waiting to rehide")
            runTempShownItemTimer(for: 3)
            return
        }

        Logger.itemManager.info("Rehiding temporarily shown items")

        var failedContexts = [TempShownItemContext]()

        let items = menuBarItems(onScreenOnly: false, activeSpaceOnly: true)

        MouseCursor.hide()

        defer {
            MouseCursor.show()
        }

        while !Task.isCancelled, let context = tempShownItemContexts.popLast() {
            guard let item = items.first(where: { $0.info == context.info }) else {
                continue
            }
            do {
                try await move(item: item, to: context.returnDestination)
            } catch is CancellationError {
                failedContexts.append(context)
                break
            } catch {
                Logger.itemManager.error("Failed to rehide \(item.logString) (error: \(error))")
                failedContexts.append(context)
            }
        }

        tempShownItemContexts.append(contentsOf: failedContexts)
        if tempShownItemContexts.isEmpty {
            tempShownItemDelay.cancel()
        } else {
            Logger.itemManager.warning("Some items failed to rehide")
            runTempShownItemTimer(for: 3)
        }
    }

    /// Removes a temporarily shown item from the cache.
    ///
    /// This ensures that the item will _not_ be returned to its previous location.
    func removeTempShownItemFromCache(with info: MenuBarItemInfo) {
        tempShownItemContexts.removeAll { $0.info == info }
    }
}

// MARK: - Arrange Items

extension MenuBarItemManager {
    /// Enforces the order of the given control items, ensuring that the always-hidden
    /// control item stays to the left of the hidden control item.
    ///
    /// - Parameters:
    ///   - hiddenControlItem: A menu bar item that represents the control item for the
    ///     hidden section.
    ///   - alwaysHiddenControlItem: A menu bar item that represents the control item
    ///     for the always-hidden section.
    func enforceControlItemOrder(hiddenControlItem: MenuBarItem, alwaysHiddenControlItem: MenuBarItem) async throws {
        guard !isMouseButtonDown else {
            Logger.itemManager.debug("Mouse button is down, so will not enforce control item order")
            return
        }
        guard !mouseHasRecentlyMoved else {
            Logger.itemManager.debug("Mouse has recently moved, so will not enforce control item order")
            return
        }
        if hiddenControlItem.frame.maxX <= alwaysHiddenControlItem.frame.minX {
            Logger.itemManager.info("Arranging menu bar items")
            try await slowMove(item: alwaysHiddenControlItem, to: .leftOfItem(hiddenControlItem))
        }
    }
}

// MARK: - Menu Bar Item Event Helper Types

/// Button states for menu bar item events.
private enum MenuBarItemEventButtonState {
    case leftMouseDown
    case leftMouseUp
    case rightMouseDown
    case rightMouseUp
    case otherMouseDown
    case otherMouseUp
}

/// Event types for menu bar item events.
private enum MenuBarItemEventType {
    /// The event type for moving a menu bar item.
    case move(MenuBarItemEventButtonState)

    /// The event type for clicking a menu bar item.
    case click(MenuBarItemEventButtonState)

    /// The button state of this event type.
    var buttonState: MenuBarItemEventButtonState {
        switch self {
        case .move(let state), .click(let state): state
        }
    }

    /// This event type's equivalent CGEventType.
    var cgEventType: CGEventType {
        switch buttonState {
        case .leftMouseDown: .leftMouseDown
        case .leftMouseUp: .leftMouseUp
        case .rightMouseDown: .rightMouseDown
        case .rightMouseUp: .rightMouseUp
        case .otherMouseDown: .otherMouseDown
        case .otherMouseUp: .otherMouseUp
        }
    }

    /// The event flags for this event type.
    var cgEventFlags: CGEventFlags {
        switch self {
        case .move(.leftMouseDown): .maskCommand
        case .move, .click: []
        }
    }

    /// The mouse button for this event type.
    var mouseButton: CGMouseButton {
        switch buttonState {
        case .leftMouseDown, .leftMouseUp: .left
        case .rightMouseDown, .rightMouseUp: .right
        case .otherMouseDown, .otherMouseUp: .center
        }
    }
}

// MARK: - CGEventField Helpers

private extension CGEventField {
    /// Key to access a field that contains the event's window identifier.
    static let windowID = CGEventField(rawValue: 0x33)! // swiftlint:disable:this force_unwrapping

    /// An array of integer event fields that can be used to compare menu bar item events.
    static let menuBarItemEventFields: [CGEventField] = [
        .eventSourceUserData,
        .mouseEventWindowUnderMousePointer,
        .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
        .windowID,
    ]
}

// MARK: - CGEventFilterMask Helpers

private extension CGEventFilterMask {
    /// Specifies that all events should be permitted during event suppression states.
    static let permitAllEvents: CGEventFilterMask = [
        .permitLocalMouseEvents,
        .permitLocalKeyboardEvents,
        .permitSystemDefinedEvents,
    ]
}

// MARK: - CGEventType Helpers

private extension CGEventType {
    /// A string to use for logging purposes.
    var logString: String {
        switch self {
        case .null: "null event"
        case .leftMouseDown: "leftMouseDown event"
        case .leftMouseUp: "leftMouseUp event"
        case .rightMouseDown: "rightMouseDown event"
        case .rightMouseUp: "rightMouseUp event"
        case .mouseMoved: "mouseMoved event"
        case .leftMouseDragged: "leftMouseDragged event"
        case .rightMouseDragged: "rightMouseDragged event"
        case .keyDown: "keyDown event"
        case .keyUp: "keyUp event"
        case .flagsChanged: "flagsChanged event"
        case .scrollWheel: "scrollWheel event"
        case .tabletPointer: "tabletPointer event"
        case .tabletProximity: "tabletProximity event"
        case .otherMouseDown: "otherMouseDown event"
        case .otherMouseUp: "otherMouseUp event"
        case .otherMouseDragged: "otherMouseDragged event"
        case .tapDisabledByTimeout: "tapDisabledByTimeout event"
        case .tapDisabledByUserInput: "tapDisabledByUserInput event"
        @unknown default: "unknown event"
        }
    }
}

// MARK: - CGMouseButton Helpers

private extension CGMouseButton {
    /// A string to use for logging purposes.
    var logString: String {
        switch self {
        case .left: "left mouse button"
        case .right: "right mouse button"
        case .center: "center mouse button"
        @unknown default: "unknown mouse button"
        }
    }

    /// The equivalent down and up button states for menu bar item click events.
    var buttonStates: (down: MenuBarItemEventButtonState, up: MenuBarItemEventButtonState) {
        switch self {
        case .left: (.leftMouseDown, .leftMouseUp)
        case .right: (.rightMouseDown, .rightMouseUp)
        default: (.otherMouseDown, .otherMouseUp)
        }
    }
}

// MARK: - CGEvent Constructor

private extension CGEvent {
    /// Returns an event that can be sent to the given menu bar item.
    ///
    /// - Parameters:
    ///   - type: The type of the event.
    ///   - location: The location of the event. Does not need to be within the bounds of the item.
    ///   - item: The target item of the event.
    ///   - pid: The target process identifier of the event. Does not need to be the item's `ownerPID`.
    ///   - source: The source of the event.
    class func menuBarItemEvent(type: MenuBarItemEventType, location: CGPoint, item: MenuBarItem, pid: pid_t, source: CGEventSource) -> CGEvent? {
        let mouseType = type.cgEventType
        let mouseButton = type.mouseButton

        guard let event = CGEvent(mouseEventSource: source, mouseType: mouseType, mouseCursorPosition: location, mouseButton: mouseButton) else {
            return nil
        }

        event.flags = type.cgEventFlags

        let targetPID = Int64(pid)
        let userData = Int64(truncatingIfNeeded: Int(bitPattern: ObjectIdentifier(event)))
        guard let itemWindowID = item.windowID else { return nil }
        let windowID = Int64(itemWindowID)

        event.setIntegerValueField(.eventTargetUnixProcessID, value: targetPID)
        event.setIntegerValueField(.eventSourceUserData, value: userData)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowID)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowID)
        event.setIntegerValueField(.windowID, value: windowID)

        if case .click = type {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }

        return event
    }
}

// MARK: - Logger

private extension Logger {
    /// The logger to use for the menu bar item manager.
    static let itemManager = Logger(category: "MenuBarItemManager")
}

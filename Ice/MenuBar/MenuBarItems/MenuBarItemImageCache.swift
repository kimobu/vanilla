//
//  MenuBarItemImageCache.swift
//  Ice
//

import Cocoa
import Combine

/// Cache for menu bar item images.
@MainActor
final class MenuBarItemImageCache: ObservableObject {
    /// The cached item images.
    @Published private(set) var images = [MenuBarItemInfo: MenuBarItemImage]()

    /// Updated together with images; classification runs on the capture actor.
    private(set) var previewBackgrounds = [MenuBarItemInfo: MenuBarImageContrast.Background]()

    /// The screen of the cached item images.
    private(set) var screen: NSScreen?

    /// The height of the menu bar of the cached item images.
    private(set) var menuBarHeight: CGFloat?

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()
    private let refreshRequests = CoalescingTask()

    /// Creates a cache with the given app state.
    init(appState: AppState) {
        self.appState = appState
    }

    /// Sets up the cache.
    func performSetup() {
        performTeardown()
        configureCancellables()
    }

    isolated deinit {
        performTeardown()
    }

    func performTeardown() {
        cancellables.removeAll()
        refreshRequests.cancel()
        refresh.cancel()
    }

    /// Configures the internal observers for the cache.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let appState {
            Publishers.Merge3(
                // Update every 3 seconds at minimum.
                Timer.publish(every: 3, on: .main, in: .default).autoconnect().mapToVoid(),

                // Update when the active space or screen parameters change.
                Publishers.Merge(
                    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
                    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                )
                .mapToVoid(),

                // Update when the average menu bar color or cached items change.
                Publishers.Merge(
                    appState.menuBarManager.$averageColorInfo.removeDuplicates().mapToVoid(),
                    appState.itemManager.$itemCache.removeDuplicates().mapToVoid()
                )
            )
            .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: false)
            .sink { [weak self] in
                guard let self else {
                    return
                }
                refreshRequests.schedule { [weak self] in
                    guard let self else { return }
                    if refreshPermissionState() {
                        await updateCache()
                    }
                }
            }
            .store(in: &c)
        }

        cancellables = c
    }

    /// Rechecks permission and clears images when access has been revoked.
    @discardableResult
    func refreshPermissionState() -> Bool {
        appState?.permissionsManager.refreshPermissions()
        guard appState?.permissionsManager.screenRecordingPermission.hasPermission == true else {
            invalidate()
            return false
        }
        return true
    }

    private func invalidate() {
        refresh.cancel()
        screen = nil
        menuBarHeight = nil
        previewBackgrounds = [:]
        if !images.isEmpty {
            images = [:]
        }
    }

    /// Logs a reason for skipping the cache.
    private func logSkippingCache(reason: String) {
        Logger.imageCache.debug("Skipping menu bar item image cache as \(reason)")
    }

    /// Returns a Boolean value that indicates whether caching menu bar items failed for
    /// the given section.
    func cacheFailed(for section: MenuBarSection.Name) -> Bool {
        guard ScreenCapture.cachedCheckPermissions() else {
            return true
        }
        let items = appState?.itemManager.itemCache[section] ?? []
        guard !items.isEmpty else {
            return false
        }
        let keys = Set(images.keys)
        for item in items where keys.contains(item.info) {
            return false
        }
        return true
    }

    private struct Snapshot: Equatable {
        let display: CaptureDisplayGeometry
        let menuBarHeight: CGFloat?
        let requests: [WindowCaptureRequest]
        let infos: [CGWindowID: MenuBarItemInfo]
        let frames: [CGRect]
        let regions: [MenuBarItemInfo: CGRect]
    }

    private struct Captures {
        let images: [MenuBarItemInfo: CGImage]
        let barImages: [MenuBarItemInfo: CGImage]
        let backgrounds: [MenuBarItemInfo: MenuBarImageContrast.Background]
    }

    private let refresh = LatestTask<Snapshot, Captures>()

    private func snapshot(sections: [MenuBarSection.Name], screen: NSScreen) -> Snapshot {
        let display = CaptureDisplayGeometry(
            id: screen.displayID,
            bounds: CGDisplayBounds(screen.displayID),
            scale: screen.backingScaleFactor
        )
        var requests = [WindowCaptureRequest]()
        var infos = [CGWindowID: MenuBarItemInfo]()
        var frames = [CGRect]()
        var regions = [MenuBarItemInfo: CGRect]()
        let menuBarBounds = appState?.itemManager.menuBarRow(on: screen)
        let hostWindows: [WindowInfo]
        if #unavailable(macOS 27) {
            hostWindows = WindowInfo.getAllWindows().filter { window in
                window.isMenuBarItem && window.frame.minY == menuBarBounds?.minY && window.frame.height == menuBarBounds?.height
            }
        } else {
            hostWindows = []
        }
        for section in sections {
            guard let control = appState?.menuBarManager.section(withName: section)?.controlItem else { continue }
            guard section == .visible || control.isAddedToMenuBar else { continue }
            if #available(macOS 27, *), !control.permitsItemCapture { continue }
            for item in appState?.itemManager.itemCache[section] ?? [] {
                if item.accessibleItem != nil {
                    guard !item.frame.isEmpty, !item.frame.isNull else { continue }
                    if menuBarBounds?.contains(item.frame) == true, display.bounds.contains(item.frame) {
                        regions[item.info] = item.frame
                    } else if #unavailable(macOS 27) {
                        let matches = hostWindows.filter { CaptureGeometry.matchesHostWindow($0.frame, item: item.frame) }
                        guard matches.count == 1, let window = matches.first, infos[window.windowID] == nil else { continue }
                        requests.append(WindowCaptureRequest(
                            windowID: window.windowID,
                            screenBounds: item.frame,
                            scale: display.scale,
                            method: .macOS26MenuBar,
                            expectedFrame: window.frame
                        ))
                        infos[window.windowID] = item.info
                    } else {
                        continue
                    }
                    frames.append(item.frame)
                    continue
                }
                guard let windowID = item.windowID, let frame = Bridging.getWindowFrame(for: windowID), frame.minY == display.bounds.minY else { continue }
                requests.append(WindowCaptureRequest(windowID: windowID, scale: display.scale))
                infos[windowID] = item.info
                frames.append(frame)
            }
        }
        return Snapshot(display: display, menuBarHeight: menuBarBounds?.height, requests: requests, infos: infos, frames: frames, regions: regions)
    }

    /// Updates requested sections, coalescing equivalent work and rejecting changed layouts.
    func updateCacheWithoutChecks(sections: [MenuBarSection.Name]) async {
        guard refreshPermissionState() else { return }
        guard let screen = NSScreen.main else { return }
        let request = snapshot(sections: sections, screen: screen)
        guard let captures = await refresh.value(for: request, operation: { [request] in
            let regions = await ScreenCapture.captureRegions(request.regions, within: request.display.bounds)
            var captures = regions.mapValues(\.image)
            let windows = await ScreenCapture.captureImages(request.requests)
            for (windowID, info) in request.infos { captures[info] = windows[windowID] }
            let backgrounds = await ScreenCapture.previewBackgrounds(for: captures)
            return Captures(images: captures, barImages: regions.compactMapValues(\.foreground), backgrounds: backgrounds)
        }) else { return }
        guard
            !Task.isCancelled,
            NSScreen.main == screen,
            request == snapshot(sections: sections, screen: screen),
            ScreenCapture.cachedCheckPermissions()
        else { return }

        var updated = images
        var updatedBackgrounds = previewBackgrounds
        for info in Set(request.infos.values).union(request.regions.keys) {
            updated[info] = captures.images[info].map {
                MenuBarItemImage(cgImage: $0, scale: request.display.scale, barCGImage: captures.barImages[info])
            }
            updatedBackgrounds[info] = captures.backgrounds[info]
        }
        let currentInfos = Set(appState?.itemManager.itemCache.allItems.map(\.info) ?? [])
        updated = updated.filter { currentInfos.contains($0.key) }
        // Publish image changes only after their display geometry is consistent.
        self.screen = screen
        self.menuBarHeight = request.menuBarHeight
        previewBackgrounds = updatedBackgrounds.filter { currentInfos.contains($0.key) }
        images = updated
        Logger.imageCache.debug("Updated \(captures.images.count) item images from \(request.regions.count) screen regions and \(request.requests.count) windows")
    }

    /// Updates the cache for the given sections, if necessary.
    func updateCache(sections: [MenuBarSection.Name]) async {
        guard let appState else {
            return
        }

        guard !appState.itemManager.isRefreshingHiddenImages else { return }

        let isIceBarPresented = appState.navigationState.isIceBarPresented
        let isSearchPresented = appState.navigationState.isSearchPresented

        if !isIceBarPresented && !isSearchPresented {
            guard appState.navigationState.isAppFrontmost else {
                logSkippingCache(reason: "Vanilla Bar not visible, app not frontmost")
                return
            }
            guard appState.navigationState.isSettingsPresented else {
                logSkippingCache(reason: "Vanilla Bar not visible, Settings not visible")
                return
            }
            guard case .menuBarLayout = appState.navigationState.settingsNavigationIdentifier else {
                logSkippingCache(reason: "Vanilla Bar not visible, Settings visible but not on Menu Bar Layout")
                return
            }
        }

        guard !appState.itemManager.isMovingItem else {
            logSkippingCache(reason: "an item is currently being moved")
            return
        }

        guard !appState.itemManager.itemHasRecentlyMoved else {
            logSkippingCache(reason: "an item was recently moved")
            return
        }

        await updateCacheWithoutChecks(sections: sections)
    }

    /// Updates the cache for all sections, if necessary.
    func updateCache() async {
        guard let appState else {
            return
        }

        let isIceBarPresented = appState.navigationState.isIceBarPresented
        let isSearchPresented = appState.navigationState.isSearchPresented
        let isSettingsPresented = appState.navigationState.isSettingsPresented

        var sectionsNeedingDisplay = [MenuBarSection.Name]()
        if isSettingsPresented || isSearchPresented {
            sectionsNeedingDisplay = MenuBarSection.Name.allCases
        } else if
            isIceBarPresented,
            let section = appState.menuBarManager.iceBarPanel.currentSection
        {
            sectionsNeedingDisplay.append(section)
        }

        await updateCache(sections: sectionsNeedingDisplay)
    }
}

// MARK: - Logger

private extension Logger {
    static let imageCache = Logger(category: "MenuBarItemImageCache")
}

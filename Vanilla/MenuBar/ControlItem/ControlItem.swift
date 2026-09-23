//
//  ControlItem.swift
//  Ice
//

import Cocoa
import Combine

/// A status item that controls a section in the menu bar.
@MainActor
final class ControlItem: NSObject {
    /// Possible identifiers for control items.
    enum Identifier: String, CaseIterable {
        case iceIcon = "SItem"
        case hidden = "HItem"
        case alwaysHidden = "AHItem"
    }

    /// Possible hiding states for control items.
    enum HidingState {
        case hideItems, showItems
    }

    /// Possible lengths for control items.
    enum Lengths {
        static let standard: CGFloat = NSStatusItem.variableLength
        static let expanded: CGFloat = 10_000
    }

    /// The control item's hiding state (`@Published`).
    @Published var state = HidingState.hideItems

    /// A Boolean value that indicates whether the control item is visible (`@Published`).
    @Published var isVisible = true

    /// The frame of the control item's window (`@Published`).
    @Published private(set) var windowFrame: CGRect?

    /// The shared app state.
    private weak var appState: AppState?

    /// The control item's underlying status item.
    private let statusItem: NSStatusItem
    private var supplementalItems = [NSStatusItem]()
    private var supplementalItemsPositioned = false
    private var isTemporarilyRevealed = false
    private var isShowingContextMenu = false
    private var menuBeforeContext: NSMenu?
    private let contextMenuPreparation = PanelPresentation()
    private var isPreparingContextMenu = false
    private var expandedInterfaceOpenedAt: TimeInterval = 0
    private var closesExpandedInterfaceOnMouseUp = false
    private var suppressesExpandedInterfaceUntilNextClick = false

    var accessibilityIdentifier: String { identifier.rawValue }

    /// Internal spacer identities are stable; the section's original identifier remains unchanged.
    var supplementalIdentifiers: [String] { supplementalItems.map { $0.autosaveName as String } }

    var needsSupplementalPlacement: Bool {
        if #available(macOS 27, *) {
            return isSectionDivider && isAddedToMenuBar && !supplementalItemsPositioned
        }
        return false
    }

    /// A collapsed section can retain old onscreen AX bounds while macOS lays
    /// out its proxy controls. Those bounds must not replace its cached images.
    var permitsItemCapture: Bool {
        !isSectionDivider || state == .showItems || isTemporarilyRevealed || needsSupplementalPlacement
    }

    /// The control item's identifier.
    private let identifier: Identifier

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The menu bar section associated with the control item.
    private weak var section: MenuBarSection? {
        appState?.menuBarManager.sections.first { $0.controlItem === self }
    }

    /// The control item's window.
    var window: NSWindow? {
        statusItem.button?.window
    }

    /// The identifier of the control item's window.
    var windowID: CGWindowID? {
        guard let window else {
            return nil
        }
        return CGWindowID(window.windowNumber)
    }

    /// A Boolean value that indicates whether the control item serves as
    /// a divider between sections.
    var isSectionDivider: Bool {
        identifier != .iceIcon
    }

    /// A Boolean value that indicates whether the control item is currently
    /// displayed in the menu bar.
    var isAddedToMenuBar: Bool {
        statusItem.isVisible
    }

    /// Creates a control item with the given identifier and app state.
    init(identifier: Identifier, appState: AppState) {
        let autosaveName = identifier.rawValue

        // If the status item doesn't have a preferred position, set it
        // according to the identifier.
        if StatusItemDefaults[.preferredPosition, autosaveName] == nil {
            switch identifier {
            case .iceIcon:
                StatusItemDefaults[.preferredPosition, autosaveName] = 0
            case .hidden:
                StatusItemDefaults[.preferredPosition, autosaveName] = 1
            case .alwaysHidden:
                break
            }
        }

        self.statusItem = NSStatusBar.system.statusItem(withLength: 0)
        self.statusItem.autosaveName = autosaveName
        self.identifier = identifier
        self.appState = appState

        super.init()
        configureStatusItem()
    }

    /// Removes the status item without clearing its stored position.
    isolated deinit {
        removeStatusItemPreservingPosition()
    }

    private func removeStatusItemPreservingPosition() {
        // Removing the status item has the unwanted side effect of deleting
        // the preferredPosition. Cache and restore it.
        let autosaveName = statusItem.autosaveName as String
        let cached = StatusItemDefaults[.preferredPosition, autosaveName]
        NSStatusBar.system.removeStatusItem(statusItem)
        StatusItemDefaults[.preferredPosition, autosaveName] = cached
        for item in supplementalItems {
            let name = item.autosaveName as String
            let position = StatusItemDefaults[.preferredPosition, name]
            NSStatusBar.system.removeStatusItem(item)
            StatusItemDefaults[.preferredPosition, name] = position
        }
    }

    /// Configures the internal observers for the control item.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if #available(macOS 27, *), identifier == .iceIcon {
            UniversalEventMonitor.publisher(for: [.leftMouseDown, .leftMouseUp, .keyDown])
                .sink { [weak self] event in self?.handleExpandedInterfaceClick(event) }
                .store(in: &c)
        }

        $state
            .sink { [weak self] state in
                self?.updateStatusItem(with: state)
            }
            .store(in: &c)

        Publishers.CombineLatest($isVisible, $state)
            .sink { [weak self] (isVisible, state) in
                self?.updateLength(isVisible: isVisible, state: state)
            }
            .store(in: &c)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                supplementalItemsPositioned = false
                updateLength(isVisible: isVisible, state: state)
            }
            .store(in: &c)

        statusItem.publisher(for: \.isVisible)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isVisible in
                guard
                    let self,
                    let appState,
                    let section
                else {
                    return
                }

                let manager = appState.settingsManager.hotkeySettingsManager

                let hotkey: Hotkey? = switch section.name {
                case .visible: nil
                case .hidden: manager.hotkey(withAction: .toggleHiddenSection)
                case .alwaysHidden: manager.hotkey(withAction: .toggleAlwaysHiddenSection)
                }

                guard let hotkey else {
                    return
                }

                if isVisible {
                    hotkey.enable()
                } else {
                    hotkey.disable()
                }
            }
            .store(in: &c)

        window?.publisher(for: \.frame)
            .sink { [weak self] frame in
                guard
                    let self,
                    let screen = window?.screen,
                    screen.frame.intersects(frame)
                else {
                    return
                }
                windowFrame = frame
            }
            .store(in: &c)

        if let appState {
            appState.settingsManager.generalSettingsManager.$showIceIcon
                .receive(on: DispatchQueue.main)
                .sink { [weak self] showIceIcon in
                    guard
                        let self,
                        !isSectionDivider
                    else {
                        return
                    }
                    if showIceIcon {
                        addToMenuBar()
                    } else {
                        removeFromMenuBar()
                    }
                }
                .store(in: &c)

            appState.settingsManager.generalSettingsManager.$iceIcon
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else {
                        return
                    }
                    updateStatusItem(with: state)
                }
                .store(in: &c)

            appState.settingsManager.generalSettingsManager.$customIceIconIsTemplate
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else {
                        return
                    }
                    updateStatusItem(with: state)
                }
                .store(in: &c)

            appState.settingsManager.generalSettingsManager.$useIceBar
                .receive(on: DispatchQueue.main)
                .sink { [weak self] useIceBar in
                    guard
                        let self,
                        let button = statusItem.button
                    else {
                        return
                    }
                    if #available(macOS 27, *), identifier == .iceIcon {
                        if !useIceBar { statusItem.expandedInterfaceSession?.cancel() }
                        statusItem.expandedInterfaceDelegate = useIceBar ? self : nil
                        button.target = self
                        button.action = #selector(performAction)
                        if useIceBar {
                            // Keep the button's normal mouse-up tracking so a
                            // second click can end AppKit's expanded session.
                            // The delegate owns presentation; target/action
                            // handles only the additional right-click menu.
                            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                            return
                        }
                    }
                    if useIceBar {
                        button.sendAction(on: [.leftMouseDown, .rightMouseUp])
                    } else {
                        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                    }
                }
                .store(in: &c)

            appState.settingsManager.advancedSettingsManager.$showSectionDividers
                .receive(on: DispatchQueue.main)
                .sink { [weak self] shouldShow in
                    guard
                        let self,
                        isSectionDivider,
                        state == .showItems
                    else {
                        return
                    }
                    isVisible = shouldShow
                }
                .store(in: &c)

            appState.settingsManager.advancedSettingsManager.$enableAlwaysHiddenSection
                .receive(on: DispatchQueue.main)
                .sink { [weak self] enable in
                    guard
                        let self,
                        identifier == .alwaysHidden
                    else {
                        return
                    }
                    if enable {
                        addToMenuBar()
                    } else {
                        removeFromMenuBar()
                    }
                }
                .store(in: &c)
        }

        cancellables = c
    }

    private func updateLength(isVisible: Bool, state: HidingState) {
        if #available(macOS 27, *), isSectionDivider {
            let widths = NSScreen.screens.map { $0.auxiliaryTopRightArea?.width ?? $0.frame.width }
            let expanded = MenuBarDividerGeometry.maximumLength(availableWidths: widths) ?? 1
            // A one-point, transparent delimiter remains discoverable when divider
            // images are disabled. Do not resize MenuBarAgent's proxy window.
            let collapse = isVisible && state == .hideItems && supplementalItemsPositioned && !isTemporarilyRevealed
            statusItem.length = collapse ? expanded : (isVisible ? 18 : 1)
            statusItem.button?.isTransparent = !isVisible
            let count = MenuBarDividerGeometry.supplementalCount(availableWidths: widths)
            for (index, item) in supplementalItems.enumerated() {
                let isExpanded = collapse && index < count
                item.button?.isTransparent = !isExpanded
                item.length = isExpanded ? expanded : 1
            }
            return
        }
        if isSectionDivider {
            // Control Center also hosts proxy status items on macOS 26.5.
            // A transparent one-point delimiter preserves its AX identity;
            // resizing the proxy window does not resize its hosted control.
            let collapse = isVisible && state == .hideItems && !isTemporarilyRevealed
            statusItem.length = collapse ? Lengths.expanded : (isVisible || isTemporarilyRevealed ? Lengths.standard : 1)
            statusItem.button?.isTransparent = !isVisible && !isTemporarilyRevealed
            return
        }
        guard let section else { return }
        if isVisible {
            statusItem.length = switch section.name {
            case .visible: Lengths.standard
            case .hidden, .alwaysHidden:
                switch state {
                case .hideItems: Lengths.expanded
                case .showItems: Lengths.standard
                }
            }
        } else {
            statusItem.length = 0
        }
    }

    /// Create small, discoverable spacers first. The manager verifies their placement
    /// next to this delimiter before any of them expands and displaces other apps.
    @available(macOS 27, *)
    func prepareSupplementalItems() {
        guard isSectionDivider, isAddedToMenuBar else { return }
        supplementalItemsPositioned = false
        let widths = NSScreen.screens.map { $0.auxiliaryTopRightArea?.width ?? $0.frame.width }
        let count = MenuBarDividerGeometry.supplementalCount(availableWidths: widths)
        while supplementalItems.count < count {
            let item = NSStatusBar.system.statusItem(withLength: 1)
            let name = "\(identifier.rawValue).Spacer.\(supplementalItems.count)"
            item.autosaveName = name
            item.button?.setAccessibilityIdentifier(name)
            item.button?.setAccessibilityLabel("Vanilla section spacer")
            item.button?.isTransparent = true
            item.button?.cell?.isEnabled = false
            supplementalItems.append(item)
        }
        // Retaining surplus one-point spacers preserves their saved placement.
        // They may be needed again when a wider display reconnects.
        // Assigning an autosave name can restore visibility from a prior launch
        // with this section disabled. An enabled group needs every spacer present.
        for item in supplementalItems { item.isVisible = true }
        updateLength(isVisible: isVisible, state: state)
    }

    @available(macOS 27, *)
    func finishSupplementalPlacement() {
        supplementalItemsPositioned = true
        updateLength(isVisible: isVisible, state: state)
    }

    /// Temporarily exposes real icons for capture or movement without changing the user's
    /// section state or resetting the verified spacer order.
    func setTemporarilyRevealed(_ revealed: Bool) {
        isTemporarilyRevealed = revealed
        updateLength(isVisible: isVisible, state: state)
    }

    /// Sets the initial configuration for the status item.
    private func configureStatusItem() {
        defer {
            configureCancellables()
            updateStatusItem(with: state)
        }
        guard let button = statusItem.button else {
            return
        }
        button.setAccessibilityIdentifier(identifier.rawValue)
        let accessibilityLabel = switch identifier {
        case .iceIcon: "Vanilla"
        case .hidden: "Vanilla hidden section"
        case .alwaysHidden: "Vanilla always-hidden section"
        }
        button.setAccessibilityLabel(accessibilityLabel)
        button.target = self
        button.action = #selector(performAction)
    }

    /// Updates the appearance of the status item using the given hiding state.
    private func updateStatusItem(with state: HidingState) {
        guard
            let appState,
            let section,
            let button = statusItem.button
        else {
            return
        }

        switch section.name {
        case .visible:
            isVisible = true
            // Enable the cell, as it may have been previously disabled.
            button.cell?.isEnabled = true
            let icon = appState.settingsManager.generalSettingsManager.iceIcon
            // We can usually just set the image directly from the icon.
            button.image = switch state {
            case .hideItems: icon.hidden.nsImage(for: appState)
            case .showItems: icon.visible.nsImage(for: appState)
            }
            if
                case .custom = icon.name,
                let originalImage = button.image
            {
                // Custom icons need to be resized to fit inside the button.
                let originalWidth = originalImage.size.width
                let originalHeight = originalImage.size.height
                let ratio = max(originalWidth / 25, originalHeight / 17)
                let newSize = CGSize(width: originalWidth / ratio, height: originalHeight / ratio)
                button.image = originalImage.resized(to: newSize)
            }
        case .hidden, .alwaysHidden:
            switch state {
            case .hideItems:
                isVisible = true
                // Prevent the cell from highlighting while expanded.
                button.cell?.isEnabled = false
                // Cell still sometimes briefly flashes on expansion unless manually unhighlighted.
                button.isHighlighted = false
                button.image = nil
            case .showItems:
                isVisible = appState.settingsManager.advancedSettingsManager.showSectionDividers
                // Enable the cell, as it may have been previously disabled.
                button.cell?.isEnabled = true
                // Set the image based on the section name and the hiding state.
                switch section.name {
                case .hidden:
                    button.image = ControlItemImage.builtin(.chevronLarge).nsImage(for: appState)
                case .alwaysHidden:
                    button.image = ControlItemImage.builtin(.chevronSmall).nsImage(for: appState)
                case .visible: break
                }
            }
        }
    }

    /// Performs the control item's action.
    @objc private func performAction() {
        guard
            let appState,
            let event = NSApp.currentEvent
        else {
            return
        }
        switch event.type {
        case .leftMouseDown, .leftMouseUp:
            if #available(macOS 27, *), statusItem.expandedInterfaceDelegate != nil {
                // AppKit opens the panel through the expanded-interface delegate.
                return
            }
            if NSEvent.modifierFlags == .control {
                showContextMenu(with: appState)
            } else if
                NSEvent.modifierFlags == .option,
                appState.settingsManager.advancedSettingsManager.canToggleAlwaysHiddenSection
            {
                if let alwaysHiddenSection = appState.menuBarManager.section(withName: .alwaysHidden) {
                    alwaysHiddenSection.toggle()
                }
            } else {
                section?.toggle()
            }
        case .rightMouseUp:
            showContextMenu(with: appState)
        default:
            break
        }
    }

    private func showContextMenu(with appState: AppState) {
        guard !isShowingContextMenu else { return }
        isShowingContextMenu = true
        if #available(macOS 27, *) { statusItem.expandedInterfaceSession?.cancel() }
        let menu = createMenu(with: appState)
        menu.delegate = self
        // MenuBarAgent opens menus asynchronously. Keep the menu assigned until
        // tracking ends so AppKit does not start our custom-panel session instead.
        menuBeforeContext = statusItem.menu
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    /// Creates a menu to show under the control item.
    private func createMenu(with appState: AppState) -> NSMenu {
        func hotkey(withAction action: HotkeyAction) -> Hotkey? {
            let hotkeySettingsManager = appState.settingsManager.hotkeySettingsManager
            return hotkeySettingsManager.hotkey(withAction: action)
        }

        let menu = NSMenu(title: "Vanilla")

        let settingsItem = NSMenuItem(
            title: "Vanilla Settings…",
            action: #selector(AppDelegate.openSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let searchItem = NSMenuItem(
            title: "Search Menu Bar Items",
            action: #selector(showSearchPanel),
            keyEquivalent: ""
        )
        searchItem.target = self
        if
            let hotkey = hotkey(withAction: .searchMenuBarItems),
            let keyCombination = hotkey.keyCombination
        {
            searchItem.keyEquivalent = keyCombination.key.keyEquivalent
            searchItem.keyEquivalentModifierMask = keyCombination.modifiers.nsEventFlags
        }
        menu.addItem(searchItem)

        menu.addItem(.separator())

        // Add menu items to toggle the hidden and always-hidden sections.
        let sectionNames: [MenuBarSection.Name] = [.hidden, .alwaysHidden]
        for name in sectionNames {
            guard
                let section = appState.menuBarManager.section(withName: name),
                section.controlItem.isAddedToMenuBar
            else {
                // Section doesn't exist, or is disabled.
                continue
            }
            let item = NSMenuItem(
                title: "\(section.isHidden ? "Show" : "Hide") the \(name.displayString) Section",
                action: #selector(toggleMenuBarSection),
                keyEquivalent: ""
            )
            item.target = self
            Self.sectionStorage.weakSet(section, for: item)
            switch name {
            case .visible:
                break
            case .hidden:
                if
                    let hotkey = hotkey(withAction: .toggleHiddenSection),
                    let keyCombination = hotkey.keyCombination
                {
                    item.keyEquivalent = keyCombination.key.keyEquivalent
                    item.keyEquivalentModifierMask = keyCombination.modifiers.nsEventFlags
                }
            case .alwaysHidden:
                if
                    let hotkey = hotkey(withAction: .toggleAlwaysHiddenSection),
                    let keyCombination = hotkey.keyCombination
                {
                    item.keyEquivalent = keyCombination.key.keyEquivalent
                    item.keyEquivalentModifierMask = keyCombination.modifiers.nsEventFlags
                }
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        if appState.updatesManager.isConfigured {
            let checkForUpdatesItem = NSMenuItem(
                title: "Check for Updates…",
                action: #selector(checkForUpdates),
                keyEquivalent: ""
            )
            checkForUpdatesItem.target = self
            menu.addItem(checkForUpdatesItem)
            menu.addItem(.separator())
        }

        let quitItem = NSMenuItem(
            title: "Quit Vanilla",
            action: #selector(NSApp.terminate),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)

        return menu
    }

    /// Toggles the menu bar section associated with the given menu item.
    @objc private func toggleMenuBarSection(for menuItem: NSMenuItem) {
        Self.sectionStorage.value(for: menuItem)?.toggle()
    }

    /// Opens the menu bar search panel.
    @objc private func showSearchPanel() {
        guard
            let appState,
            let screen = MenuBarSearchPanel.defaultScreen
        else {
            return
        }
        appState.menuBarManager.searchPanel.show(on: screen)
    }

    /// Opens the settings window and checks for app updates.
    @objc private func checkForUpdates() {
        guard let appState else {
            return
        }
        appState.updatesManager.checkForUpdates()
    }

    /// Adds the control item to the menu bar.
    func addToMenuBar() {
        guard !isAddedToMenuBar else {
            return
        }
        statusItem.isVisible = true
        supplementalItemsPositioned = false
        for item in supplementalItems { item.isVisible = true }
    }

    /// Removes the control item from the menu bar.
    func removeFromMenuBar() {
        guard isAddedToMenuBar else {
            return
        }
        // Setting `statusItem.isVisible` to `false` has the unwanted side
        // effect of deleting the preferredPosition. Cache and restore it.
        let autosaveName = statusItem.autosaveName as String
        let cached = StatusItemDefaults[.preferredPosition, autosaveName]
        statusItem.isVisible = false
        StatusItemDefaults[.preferredPosition, autosaveName] = cached
        supplementalItemsPositioned = false
        for item in supplementalItems {
            let name = item.autosaveName as String
            let position = StatusItemDefaults[.preferredPosition, name]
            item.isVisible = false
            StatusItemDefaults[.preferredPosition, name] = position
        }
    }
}

// MARK: - Native status-item panel lifecycle

// AppKit owns left-click and keyboard session tracking on macOS 27. The panel
// cancels the session when an item action or another app path closes it.
// https://developer.apple.com/documentation/appkit/nsstatusitem/expandedinterfacedelegate
@available(macOS 27, *)
extension ControlItem: @MainActor NSStatusItemExpandedInterfaceDelegate {
    private func handleExpandedInterfaceClick(_ event: NSEvent) {
        guard let appState, statusItem.expandedInterfaceDelegate != nil else { return }
        if let cgEvent = event.cgEvent, MenuBarItemClick.isGeneratedEvent(cgEvent) { return }
        if event.type == .keyDown {
            suppressesExpandedInterfaceUntilNextClick = false
            return
        }
        if event.type == .leftMouseDown {
            suppressesExpandedInterfaceUntilNextClick = false
            closesExpandedInterfaceOnMouseUp = false
            guard
                appState.menuBarManager.iceBarPanel.currentSection != nil,
                event.timestamp > expandedInterfaceOpenedAt,
                event.modifierFlags.isDisjoint(with: [.control, .option, .command]),
                let point = event.cgEvent?.location
            else { return }
            // Hosted status-item proxy windows are not the icon's bounds on
            // external displays. Compare the click with current AX geometry.
            closesExpandedInterfaceOnMouseUp = appState.itemManager
                .menuBarItems(onScreenOnly: true, activeSpaceOnly: true)
                .contains { $0.info == .iceIcon && $0.frame.contains(point) }
            Logger.controlItem.debug("Expanded interface mouse-down hit icon: \(self.closesExpandedInterfaceOnMouseUp)")
        } else if closesExpandedInterfaceOnMouseUp {
            closesExpandedInterfaceOnMouseUp = false
            suppressesExpandedInterfaceUntilNextClick = true
            Logger.controlItem.debug("Closing expanded interface after repeated icon click")
            appState.menuBarManager.iceBarPanel.close()
        }
    }

    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        Logger.controlItem.debug("Status-item expanded interface began")
        guard !suppressesExpandedInterfaceUntilNextClick else {
            session.cancel()
            return
        }
        guard !isShowingContextMenu else {
            return
        }
        guard let appState else {
            session.cancel()
            return
        }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseDown || event?.type == .rightMouseUp || NSEvent.modifierFlags == .control {
            session.cancel()
            showContextMenu(with: appState)
            return
        }
        let alwaysHidden = NSEvent.modifierFlags == .option && appState.settingsManager.advancedSettingsManager.canToggleAlwaysHiddenSection
        let name: MenuBarSection.Name = alwaysHidden ? .alwaysHidden : .hidden
        guard appState.menuBarManager.section(withName: name)?.isEnabled == true, let screen = NSScreen.screenWithMouse ?? NSScreen.main else {
            session.cancel()
            return
        }
        if appState.menuBarManager.iceBarPanel.currentSection == name {
            suppressesExpandedInterfaceUntilNextClick = true
            appState.menuBarManager.iceBarPanel.close()
            session.cancel()
            return
        }
        expandedInterfaceOpenedAt = ProcessInfo.processInfo.systemUptime
        for section in appState.menuBarManager.sections { section.controlItem.state = .hideItems }
        appState.menuBarManager.iceBarPanel.show(section: name, on: screen, expandedInterfaceStatusItem: statusItem)
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        Logger.controlItem.debug("Status-item expanded interface ended")
        appState?.menuBarManager.iceBarPanel.closeExpandedInterface(for: statusItem)
    }
}

extension ControlItem: @MainActor NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        guard
            let appState,
            appState.isActiveSpaceFullscreen,
            appState.imageCache.refreshPermissionState(),
            appState.imageCache.images.isEmpty || appState.itemManager.itemCache.managedItems.contains(where: {
                $0.owningApplication != .current && appState.imageCache.images[$0.info] == nil
            })
        else { return }

        // On macOS 26.5 the native bar retracts when a menu command runs.
        // Obtain missing images while menu tracking keeps that bar onscreen.
        // Dismissal cancels this waiter; the manager owns shared capture cleanup.
        isPreparingContextMenu = true
        let loadingItem = NSMenuItem(title: "Loading menu bar items…", action: nil, keyEquivalent: "")
        menu.insertItem(loadingItem, at: 0)
        menu.update()
        contextMenuPreparation.show { [weak appState] in
            await appState?.itemManager.cacheItemsIfNeeded()
            guard !Task.isCancelled else { return }
            await appState?.itemManager.refreshImagesForPresentation()
        } present: { [weak self, weak menu] in
            self?.isPreparingContextMenu = false
            menu?.removeItem(loadingItem)
            menu?.update()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        contextMenuPreparation.dismiss()
        isPreparingContextMenu = false
        statusItem.menu = menuBeforeContext
        menuBeforeContext = nil
        isShowingContextMenu = false
    }
}

extension ControlItem: @MainActor NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        !isPreparingContextMenu || (
            menuItem.action != #selector(showSearchPanel) &&
            menuItem.action != #selector(toggleMenuBarSection)
        )
    }
}

private extension ControlItem {
    /// Storage for menu items that toggle a menu bar section.
    ///
    /// When one of these menu items is created, its section is stored here.
    /// When its action is invoked, the section is retrieved from storage.
    static let sectionStorage = ObjectStorage<MenuBarSection>()
}

// MARK: - Logger
private extension Logger {
    /// The logger to use for control items.
    static let controlItem = Logger(category: "ControlItem")
}

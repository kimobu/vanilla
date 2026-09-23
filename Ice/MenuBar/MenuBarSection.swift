//
//  MenuBarSection.swift
//  Ice
//

import Cocoa

/// A representation of a section in a menu bar.
@MainActor
final class MenuBarSection {
    /// The name of a menu bar section.
    enum Name: CaseIterable {
        case visible
        case hidden
        case alwaysHidden

        /// A string to show in the interface.
        var displayString: String {
            switch self {
            case .visible: "Visible"
            case .hidden: "Hidden"
            case .alwaysHidden: "Always-Hidden"
            }
        }

        /// A string to use for logging purposes.
        var logString: String {
            switch self {
            case .visible: "visible section"
            case .hidden: "hidden section"
            case .alwaysHidden: "always-hidden section"
            }
        }
    }

    /// The name of the section.
    let name: Name

    /// The control item that manages the section.
    let controlItem: ControlItem

    /// The shared app state.
    private weak var appState: AppState?

    /// Owns the pending timed-rehide request.
    private let rehideAction = DelayedAction<Bool>()

    /// An event monitor that handles starting the rehide timer when the mouse
    /// is outside of the menu bar.
    private var rehideMonitor: UniversalEventMonitor?

    /// A Boolean value that indicates whether the Ice Bar should be used.
    private var useIceBar: Bool {
        appState?.settingsManager.generalSettingsManager.useIceBar ?? false
    }

    /// A weak reference to the menu bar manager's Ice Bar panel.
    private weak var iceBarPanel: IceBarPanel? {
        appState?.menuBarManager.iceBarPanel
    }

    /// The best screen to show the Ice Bar on.
    private weak var screenForIceBar: NSScreen? {
        guard let appState else {
            return nil
        }
        if appState.isActiveSpaceFullscreen {
            return NSScreen.screenWithMouse ?? NSScreen.main
        } else {
            return NSScreen.main
        }
    }

    /// A Boolean value that indicates whether the section is hidden.
    var isHidden: Bool {
        if useIceBar {
            if controlItem.state == .showItems {
                return false
            }
            switch name {
            case .visible, .hidden:
                return iceBarPanel?.currentSection != .hidden
            case .alwaysHidden:
                return iceBarPanel?.currentSection != .alwaysHidden
            }
        }
        switch name {
        case .visible, .hidden:
            if iceBarPanel?.currentSection == .hidden {
                return false
            }
            return controlItem.state == .hideItems
        case .alwaysHidden:
            if iceBarPanel?.currentSection == .alwaysHidden {
                return false
            }
            return controlItem.state == .hideItems
        }
    }

    /// A Boolean value that indicates whether the section is enabled.
    var isEnabled: Bool {
        if case .visible = name {
            // The visible section should always be enabled.
            return true
        }
        return controlItem.isAddedToMenuBar
    }

    /// Creates a section with the given name, control item, and app state.
    init(name: Name, controlItem: ControlItem, appState: AppState) {
        self.name = name
        self.controlItem = controlItem
        self.appState = appState
    }

    /// Creates a section with the given name and app state.
    convenience init(name: Name, appState: AppState) {
        let controlItem = switch name {
        case .visible:
            ControlItem(identifier: .iceIcon, appState: appState)
        case .hidden:
            ControlItem(identifier: .hidden, appState: appState)
        case .alwaysHidden:
            ControlItem(identifier: .alwaysHidden, appState: appState)
        }
        self.init(name: name, controlItem: controlItem, appState: appState)
    }

    isolated deinit {
        rehideMonitor?.stop()
    }

    /// Shows the section.
    func show() {
        guard
            let appState,
            isHidden
        else {
            return
        }
        guard controlItem.isAddedToMenuBar else {
            // The section is disabled.
            // TODO: Can we use isEnabled for this check?
            return
        }
        switch name {
        case _ where useIceBar:
            guard let screenForIceBar, let iceBarPanel else { return }
            for section in appState.menuBarManager.sections {
                section.controlItem.state = .hideItems
            }
            let section: Name = name == .alwaysHidden ? .alwaysHidden : .hidden
            iceBarPanel.show(section: section, on: screenForIceBar)
        case .visible:
            iceBarPanel?.close()
            guard let hiddenSection = appState.menuBarManager.section(withName: .hidden) else {
                return
            }
            controlItem.state = .showItems
            hiddenSection.controlItem.state = .showItems
        case .hidden:
            iceBarPanel?.close()
            guard let visibleSection = appState.menuBarManager.section(withName: .visible) else {
                return
            }
            controlItem.state = .showItems
            visibleSection.controlItem.state = .showItems
        case .alwaysHidden:
            iceBarPanel?.close()
            guard
                let hiddenSection = appState.menuBarManager.section(withName: .hidden),
                let visibleSection = appState.menuBarManager.section(withName: .visible)
            else {
                return
            }
            controlItem.state = .showItems
            hiddenSection.controlItem.state = .showItems
            visibleSection.controlItem.state = .showItems
        }
        appState.menuBarManager.section(withName: name == .visible ? .hidden : name)?.startRehideChecks()
    }

    /// Hides the section.
    func hide() {
        stopRehideChecks()
        appState?.menuBarManager.cancelPendingRehide()
        guard
            let appState,
            !isHidden
        else {
            return
        }
        iceBarPanel?.close()
        switch name {
        case _ where useIceBar:
            for section in appState.menuBarManager.sections {
                section.controlItem.state = .hideItems
            }
        case .visible:
            guard
                let hiddenSection = appState.menuBarManager.section(withName: .hidden),
                let alwaysHiddenSection = appState.menuBarManager.section(withName: .alwaysHidden)
            else {
                return
            }
            controlItem.state = .hideItems
            hiddenSection.controlItem.state = .hideItems
            alwaysHiddenSection.controlItem.state = .hideItems
        case .hidden:
            guard
                let visibleSection = appState.menuBarManager.section(withName: .visible),
                let alwaysHiddenSection = appState.menuBarManager.section(withName: .alwaysHidden)
            else {
                return
            }
            controlItem.state = .hideItems
            visibleSection.controlItem.state = .hideItems
            alwaysHiddenSection.controlItem.state = .hideItems
        case .alwaysHidden:
            controlItem.state = .hideItems
        }
        appState.allowShowOnHover()
        for section in appState.menuBarManager.sections where section.isHidden {
            section.stopRehideChecks()
        }
    }

    /// Toggles the visibility of the section.
    func toggle() {
        if isHidden {
            show()
        } else {
            hide()
        }
    }

    /// Starts a new timed-rehide session using the current settings.
    func startRehideChecks() {
        stopRehideChecks()
        guard name != .visible, canRehide else { return }
        // Panel preparation can take longer than the delay. Start its timer
        // after presentation, including native status-item sessions on macOS 27.
        if useIceBar, iceBarPanel?.isVisible != true { return }
        rehideMonitor = UniversalEventMonitor(mask: .mouseMoved) { [weak self] event in
            self?.updateRehideRequest()
            return event
        }
        rehideMonitor?.start()
        updateRehideRequest()
    }

    private var canRehide: Bool {
        guard let settings = appState?.settingsManager.generalSettingsManager else { return false }
        return !isHidden && settings.autoRehide && settings.rehideStrategy == .timed
    }

    private func updateRehideRequest() {
        guard canRehide, let appState else {
            stopRehideChecks()
            return
        }
        guard let screen = NSScreen.main, NSEvent.mouseLocation.y < screen.visibleFrame.maxY else {
            rehideAction.cancel()
            return
        }
        let interval = appState.settingsManager.generalSettingsManager.rehideInterval
        guard interval.isFinite, interval >= 0 else {
            rehideAction.cancel()
            return
        }
        rehideAction.schedule(key: true, after: .seconds(interval)) { [weak self] in
            guard let self, canRehide else {
                self?.stopRehideChecks()
                return
            }
            guard let screen = NSScreen.main, NSEvent.mouseLocation.y < screen.visibleFrame.maxY else { return }
            Logger.menuBarSection.debug("Timed rehide reached its deadline")
            hide()
        }
    }

    /// Stops both pointer monitoring and any pending rehide action.
    func stopRehideChecks() {
        rehideAction.cancel()
        rehideMonitor?.stop()
        rehideMonitor = nil
    }
}

// MARK: MenuBarSection: BindingExposable
extension MenuBarSection: BindingExposable { }

// MARK: - Logger
private extension Logger {
    static let menuBarSection = Logger(category: "MenuBarSection")
}

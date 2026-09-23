//
//  MenuBarItem.swift
//  Ice
//

import Cocoa

// MARK: - MenuBarItem

/// A representation of an item in the menu bar.
struct MenuBarItem: Identifiable {
    enum Identifier: Hashable {
        case window(CGWindowID)
        case accessibility(UUID)
    }

    private enum Source {
        case window(WindowInfo)
        case accessibility(AccessibleMenuBarItem)
    }

    private let source: Source

    var accessibleItem: AccessibleMenuBarItem? {
        if case .accessibility(let item) = source { return item }
        return nil
    }

    var id: Identifier {
        switch source {
        case .window(let window): .window(window.windowID)
        case .accessibility(let item): .accessibility(item.id)
        }
    }

    /// The menu bar item info associated with this item.
    let info: MenuBarItemInfo

    /// The identifier of the item's window.
    var windowID: CGWindowID? {
        if case .window(let window) = source { return window.windowID }
        return nil
    }

    /// The frame of the item's window.
    var frame: CGRect {
        switch source {
        case .window(let window): window.frame
        case .accessibility(let item): item.frame ?? .null
        }
    }

    /// The title of the item's window.
    var title: String? {
        switch source {
        case .window(let window): window.title
        case .accessibility(let item): item.accessibilityIdentifier
        }
    }

    /// A Boolean value that indicates whether the item is on screen.
    var isOnScreen: Bool {
        switch source {
        case .window(let window): window.isOnScreen
        case .accessibility(let item): item.frame.map { frame in NSScreen.screens.contains { CGDisplayBounds($0.displayID).contains(frame) } } ?? false
        }
    }

    /// A Boolean value that indicates whether the item can be moved.
    var isMovable: Bool {
        if let item = accessibleItem {
            return !["com.apple.menuextra.clock", "com.apple.menuextra.siri", "com.apple.menuextra.controlcenter"].contains(item.accessibilityIdentifier)
        }
        let immovableItems = Set(MenuBarItemInfo.immovableItems)
        return !immovableItems.contains(info)
    }

    /// A Boolean value that indicates whether the item can be hidden.
    var canBeHidden: Bool {
        if let item = accessibleItem {
            return !["com.apple.menuextra.audiovideo", "com.apple.menuextra.facetime", "com.apple.menuextra.musicrecognition"].contains(item.accessibilityIdentifier)
        }
        let nonHideableItems = Set(MenuBarItemInfo.nonHideableItems)
        return !nonHideableItems.contains(info)
    }

    /// The process identifier of the application that owns the item.
    var ownerPID: pid_t {
        switch source {
        case .window(let window): window.ownerPID
        case .accessibility(let item): item.processID
        }
    }

    /// The name of the application that owns the item.
    ///
    /// This may have a value when ``owningApplication`` does not have
    /// a localized name.
    var ownerName: String? {
        switch source {
        case .window(let window): window.ownerName
        case .accessibility(let item): item.applicationName
        }
    }

    /// The application that owns the item.
    var owningApplication: NSRunningApplication? {
        switch source {
        case .window(let window): window.owningApplication
        case .accessibility(let item): NSRunningApplication(processIdentifier: item.processID)
        }
    }

    /// A name associated with the item that is suited for display to
    /// the user.
    var displayName: String {
        if let item = accessibleItem {
            return item.label.flatMap { $0.isEmpty ? nil : $0 } ?? item.applicationName
        }
        var fallback: String { "Unknown" }
        guard let owningApplication else {
            return ownerName ?? title ?? fallback
        }
        var bestName: String {
            owningApplication.localizedName ??
            ownerName ??
            owningApplication.bundleIdentifier ??
            fallback
        }
        guard let title else {
            return bestName
        }
        // by default, use the application name, but handle a few special cases
        return switch MenuBarItemInfo.Namespace(owningApplication.bundleIdentifier) {
        case .controlCenter:
            switch title {
            case "AccessibilityShortcuts": "Accessibility Shortcuts"
            case "BentoBox": bestName // Control Center
            case "FocusModes": "Focus"
            case "KeyboardBrightness": "Keyboard Brightness"
            case "MusicRecognition": "Music Recognition"
            case "NowPlaying": "Now Playing"
            case "ScreenMirroring": "Screen Mirroring"
            case "StageManager": "Stage Manager"
            case "UserSwitcher": "Fast User Switching"
            case "WiFi": "Wi-Fi"
            default: title
            }
        case .systemUIServer:
            switch title {
            case "TimeMachine.TMMenuExtraHost"/*Sonoma*/, "TimeMachineMenuExtra.TMMenuExtraHost"/*Sequoia*/: "Time Machine"
            default: title
            }
        case MenuBarItemInfo.Namespace("com.apple.Passwords.MenuBarExtra"): "Passwords"
        default:
            bestName
        }
    }

    /// A Boolean value that indicates whether the item is currently
    /// in the menu bar.
    var isCurrentlyInMenuBar: Bool {
        guard let windowID else { return isOnScreen }
        let list = Set(Bridging.getWindowList(option: .menuBarItems))
        return list.contains(windowID)
    }

    /// A string to use for logging purposes.
    var logString: String {
        if let item = accessibleItem {
            return "Accessibility item \(item.id)"
        }
        return String(describing: info)
    }

    /// Runtime cache keys keep duplicate or unnamed AX items distinct. These keys
    /// are not saved preferences; control identifiers retain their existing meaning.
    init(accessibleItem item: AccessibleMenuBarItem) {
        source = .accessibility(item)
        let isControl = item.bundleIdentifier == Constants.bundleIdentifier &&
            ["SItem", "HItem", "AHItem"].contains(item.accessibilityIdentifier)
        info = MenuBarItemInfo(
            namespace: MenuBarItemInfo.Namespace(item.bundleIdentifier),
            title: isControl ? (item.accessibilityIdentifier ?? "") : "AX:\(item.id)"
        )
    }

    /// Creates a menu bar item from the given window.
    ///
    /// This initializer does not perform any checks on the window to ensure that
    /// it is a valid menu bar item window. Only call this initializer if you are
    /// certain that the window is valid.
    private init(uncheckedItemWindow itemWindow: WindowInfo) {
        self.source = .window(itemWindow)
        self.info = MenuBarItemInfo(uncheckedItemWindow: itemWindow)
    }

    /// Creates a menu bar item.
    ///
    /// The parameters passed into this initializer are verified during the menu
    /// bar item's creation. If `itemWindow` does not represent a menu bar item,
    /// the initializer will fail.
    ///
    /// - Parameter itemWindow: A window that contains information about the item.
    init?(itemWindow: WindowInfo) {
        guard itemWindow.isMenuBarItem else {
            return nil
        }
        self.init(uncheckedItemWindow: itemWindow)
    }

    /// Creates a menu bar item with the given window identifier.
    ///
    /// The parameters passed into this initializer are verified during the menu
    /// bar item's creation. If `windowID` does not represent a menu bar item,
    /// the initializer will fail.
    ///
    /// - Parameter windowID: An identifier for a window that contains information
    ///   about the item.
    init?(windowID: CGWindowID) {
        guard let window = WindowInfo(windowID: windowID) else {
            return nil
        }
        self.init(itemWindow: window)
    }
}

// MARK: MenuBarItem Getters
extension MenuBarItem {
    /// Returns an array of the current menu bar items in the menu bar on the given display.
    ///
    /// - Parameters:
    ///   - display: The display to retrieve the menu bar items on. Pass `nil` to return the
    ///     menu bar items across all displays.
    ///   - onScreenOnly: A Boolean value that indicates whether only the menu bar items that
    ///     are on screen should be returned.
    ///   - activeSpaceOnly: A Boolean value that indicates whether only the menu bar items
    ///     that are on the active space should be returned.
    static func getMenuBarItems(on display: CGDirectDisplayID? = nil, onScreenOnly: Bool, activeSpaceOnly: Bool) -> [MenuBarItem] {
        var option: Bridging.WindowListOption = [.menuBarItems]

        var titlePredicate: (MenuBarItem) -> Bool = { _ in true }
        var boundsPredicate: (CGWindowID) -> Bool = { _ in true }

        if onScreenOnly {
            option.insert(.onScreen)
        }
        if activeSpaceOnly {
            option.insert(.activeSpace)
            titlePredicate = { $0.title != "" }
        }
        if let display {
            let displayBounds = CGDisplayBounds(display)
            boundsPredicate = { windowID in
                guard let windowFrame = Bridging.getWindowFrame(for: windowID) else {
                    return false
                }
                return displayBounds.intersects(windowFrame)
            }
        }

        return Bridging.getWindowList(option: option).lazy
            .filter(boundsPredicate)
            .compactMap { windowID in
                MenuBarItem(windowID: windowID)
            }
            .filter(titlePredicate)
            .sortedByOrderInMenuBar()
    }
}

// MARK: MenuBarItem: Equatable
extension MenuBarItem: Equatable {
    static func == (lhs: MenuBarItem, rhs: MenuBarItem) -> Bool {
        switch (lhs.source, rhs.source) {
        case (.window(let lhs), .window(let rhs)): lhs == rhs
        case (.accessibility(let lhs), .accessibility(let rhs)): lhs == rhs
        default: false
        }
    }
}

// MARK: MenuBarItem: Hashable
extension MenuBarItem: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: MenuBarItemInfo Unchecked Item Window Initializer
private extension MenuBarItemInfo {
    /// Creates a simplified item from the given window.
    ///
    /// This initializer does not perform any checks on the window to ensure that
    /// it is a valid menu bar item window. Only call this initializer if you are
    /// certain that the window is valid.
    init(uncheckedItemWindow itemWindow: WindowInfo) {
        if let bundleIdentifier = itemWindow.owningApplication?.bundleIdentifier {
            self.namespace = Namespace(bundleIdentifier)
        } else {
            self.namespace = .null
        }
        if let title = itemWindow.title {
            self.title = title
        } else {
            self.title = ""
        }
    }
}

//
//  IceBar.swift
//  Ice
//

import Combine
import SwiftUI

// MARK: - IceBarPanel

final class IceBarPanel: NSPanel {
    private weak var appState: AppState?

    private(set) var currentSection: MenuBarSection.Name?
    // SwiftUI can size the panel after its initial origin is set. In full screen
    // on macOS 26.5 that origin can be offscreen, so NSWindow.screen is nil.
    // Keep the requested display until close so the size update can reposition it.
    private var presentationScreen: NSScreen?

    private lazy var colorManager = IceBarColorManager(iceBarPanel: self)

    private var cancellables = Set<AnyCancellable>()
    private let presentation = PanelPresentation()
    private weak var expandedInterfaceStatusItem: NSStatusItem?
    private lazy var keyDownMonitor = UniversalEventMonitor(mask: .keyDown) { [weak self] event in
        guard KeyCode(rawValue: Int(event.keyCode)) == .escape else { return event }
        self?.close()
        return nil
    }

    init(appState: AppState) {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        self.appState = appState
        self.title = "Vanilla Bar"
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.allowsToolTipsWhenApplicationIsInactive = true
        self.isFloatingPanel = true
        self.animationBehavior = .none
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .mainMenu + 1
        self.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .moveToActiveSpace]
    }

    func performSetup() {
        configureCancellables()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        // Close the panel when the active space changes, or when the screen parameters change.
        Publishers.Merge(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
        )
        .sink { [weak self] _ in
            self?.close()
        }
        .store(in: &c)

        if
            let section = appState?.menuBarManager.section(withName: .hidden),
            let window = section.controlItem.window
        {
            window.publisher(for: \.frame)
                .debounce(for: 0.1, scheduler: DispatchQueue.main)
                .sink { [weak self, weak window] _ in
                    guard
                        let self,
                        let appState,
                        // Only continue if the menu bar is automatically hidden, as Ice
                        // can't currently display its menu bar items.
                        appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults,
                        let info = window.flatMap({ WindowInfo(windowID: CGWindowID($0.windowNumber)) }),
                        // Window being offscreen means the menu bar is currently hidden.
                        // Close the bar, as things will start to look weird if we don't.
                        !info.isOnScreen
                    else {
                        return
                    }
                    close()
                }
                .store(in: &c)
        }

        // Update the panel's origin whenever its size changes.
        publisher(for: \.frame)
            .map(\.size)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard
                    let self,
                    let screen = presentationScreen
                else {
                    return
                }
                updateOrigin(for: screen)
            }
            .store(in: &c)

        cancellables = c
    }

    private func updateOrigin(for screen: NSScreen) {
        guard let appState else {
            return
        }

        func getOrigin(for iceBarLocation: IceBarLocation) -> CGPoint {
            let menuBarHeight = screen.getMenuBarHeight() ?? 0
            let originY = ((screen.frame.maxY - 1) - menuBarHeight) - frame.height

            var originForRightOfScreen: CGPoint {
                CGPoint(x: screen.frame.maxX - frame.width, y: originY)
            }

            switch iceBarLocation {
            case .dynamic:
                if appState.eventManager.isMouseInsideEmptyMenuBarSpace {
                    return getOrigin(for: .mousePointer)
                }
                return getOrigin(for: .iceIcon)
            case .mousePointer:
                guard let location = MouseCursor.locationAppKit else {
                    return getOrigin(for: .iceIcon)
                }

                let lowerBound = screen.frame.minX
                let upperBound = screen.frame.maxX - frame.width

                guard lowerBound <= upperBound else {
                    return originForRightOfScreen
                }

                return CGPoint(x: (location.x - frame.width / 2).clamped(to: lowerBound...upperBound), y: originY)
            case .iceIcon:
                let lowerBound = screen.frame.minX
                let upperBound = screen.frame.maxX - frame.width

                guard
                    lowerBound <= upperBound,
                    let itemFrame = appState.itemManager.menuBarItems(on: screen.displayID, onScreenOnly: true, activeSpaceOnly: true)
                        .first(where: { $0.info == .iceIcon })?.frame
                else {
                    return originForRightOfScreen
                }

                return CGPoint(x: (itemFrame.midX - frame.width / 2).clamped(to: lowerBound...upperBound), y: originY)
            }
        }

        setFrameOrigin(getOrigin(for: appState.settingsManager.generalSettingsManager.iceBarLocation))
    }

    func show(section: MenuBarSection.Name, on screen: NSScreen, expandedInterfaceStatusItem: NSStatusItem? = nil) {
        guard let appState else {
            return
        }
        close()
        Logger.iceBarPanel.debug("Requested Vanilla Bar presentation")
        presentationScreen = screen
        self.expandedInterfaceStatusItem = expandedInterfaceStatusItem

        // Important that we set the navigation state and current section before updating the cache.
        appState.navigationState.isIceBarPresented = true
        currentSection = section
        // Capture can delay ordering the window in. Escape must also dismiss a
        // pending presentation, including panels opened through a hotkey on 26.
        keyDownMonitor.start()

        presentation.show { [weak self] in
            await self?.prepare(section: section, on: screen)
        } present: { [weak self] in
            guard let self else { return }
            orderFrontRegardless()
            // On macOS 26.5, ordering this borderless panel in leaves its
            // SwiftUI layers undrawn until the initial AppKit display pass.
            // https://developer.apple.com/documentation/appkit/nswindow/display()
            display()
            Logger.iceBarPanel.debug("Presented Vanilla Bar")
            colorManager.startUpdating()
            self.appState?.menuBarManager.section(withName: section)?.startRehideChecks()
        }
    }

    private func prepare(section: MenuBarSection.Name, on screen: NSScreen) async {
        guard let appState else { return }

        await appState.itemManager.cacheItemsIfNeeded()
        guard !Task.isCancelled else { return }

        if appState.imageCache.refreshPermissionState() {
            let needsCapture: Bool
            if #available(macOS 27, *) {
                // Hosted overflow icons must be exposed to capture them on 27.
                // Reuse complete previews so opening the bar does not briefly
                // reveal every hidden icon. Normal capture updates these images
                // when the section is exposed; new items still need a capture.
                let items = appState.itemManager.itemCache.managedItems(for: section)
                needsCapture = items.contains { appState.imageCache.images[$0.info] == nil }
            } else {
                needsCapture = true
            }
            if needsCapture {
                await appState.itemManager.refreshImagesForPresentation()
            } else {
                Logger.iceBarPanel.debug("Reusing cached Vanilla Bar previews")
            }
        }
        guard !Task.isCancelled else { return }

        contentView = IceBarHostingView(appState: appState, colorManager: colorManager, screen: screen, section: section) { [weak self] in
            self?.close()
        }

        updateOrigin(for: screen)

        // Color manager must be updated after updating the panel's origin, but before it is shown.
        //
        // Color manager handles frame changes automatically, but does so on the main queue, so we
        // need to update manually once before showing the panel to prevent the color from flashing.
        await colorManager.updateAllProperties(with: frame, screen: screen)
    }

    override func close() {
        presentationScreen = nil
        let statusItem = expandedInterfaceStatusItem
        expandedInterfaceStatusItem = nil
        presentation.dismiss()
        colorManager.stopUpdating()
        appState?.menuBarManager.cancelPendingRehide()
        for section in appState?.menuBarManager.sections ?? [] { section.stopRehideChecks() }
        keyDownMonitor.stop()
        super.close()
        contentView = nil
        currentSection = nil
        appState?.navigationState.isIceBarPresented = false
        if #available(macOS 27, *) { statusItem?.expandedInterfaceSession?.cancel() }
    }

    func closeExpandedInterface(for statusItem: NSStatusItem) {
        guard expandedInterfaceStatusItem === statusItem else { return }
        close()
    }
}

private extension Logger {
    static let iceBarPanel = Logger(category: "IceBarPanel")
}

// MARK: - IceBarHostingView

private final class IceBarHostingView: NSHostingView<AnyView> {
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets()
    }

    init(
        appState: AppState,
        colorManager: IceBarColorManager,
        screen: NSScreen,
        section: MenuBarSection.Name,
        closePanel: @escaping () -> Void
    ) {
        super.init(
            rootView: IceBarContentView(screen: screen, section: section, closePanel: closePanel)
                .environmentObject(appState)
                .environmentObject(appState.imageCache)
                .environmentObject(appState.itemManager)
                .environmentObject(appState.menuBarManager)
                .environmentObject(colorManager)
                .erasedToAnyView()
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @available(*, unavailable)
    required init(rootView: AnyView) {
        fatalError("init(rootView:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

// MARK: - IceBarContentView

private struct IceBarContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var colorManager: IceBarColorManager
    @EnvironmentObject var itemManager: MenuBarItemManager
    @EnvironmentObject var imageCache: MenuBarItemImageCache
    @EnvironmentObject var menuBarManager: MenuBarManager
    @State private var frame = CGRect.zero
    @State private var scrollIndicatorsFlashTrigger = 0

    let screen: NSScreen
    let section: MenuBarSection.Name
    let closePanel: () -> Void

    private var items: [MenuBarItem] {
        itemManager.itemCache.managedItems(for: section)
    }

    private var configuration: MenuBarAppearanceConfigurationV2 {
        appState.appearanceManager.configuration
    }

    private var horizontalPadding: CGFloat {
        configuration.hasRoundedShape ? 7 : 5
    }

    private var verticalPadding: CGFloat {
        screen.hasNotch ? 0 : 2
    }

    private var contentHeight: CGFloat? {
        guard let menuBarHeight = imageCache.menuBarHeight ?? screen.getMenuBarHeight() else {
            return nil
        }
        if configuration.shapeKind != .none && configuration.isInset && screen.hasNotch {
            return menuBarHeight - appState.appearanceManager.menuBarInsetAmount * 2
        }
        return menuBarHeight
    }

    private var clipShape: AnyInsettableShape {
        if configuration.hasRoundedShape {
            AnyInsettableShape(Capsule())
        } else {
            AnyInsettableShape(RoundedRectangle(cornerRadius: frame.height / 5, style: .continuous))
        }
    }

    private var shadowOpacity: CGFloat {
        configuration.current.hasShadow ? 0.5 : 0.33
    }

    var body: some View {
        ZStack {
            content
                .frame(height: contentHeight)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .layoutBarStyle(appState: appState, averageColorInfo: colorManager.colorInfo, usesSolidBackground: true)
                .foregroundStyle(colorManager.colorInfo?.color.brightness ?? 0 > 0.67 ? .black : .white)
                .clipShape(clipShape)
                .shadow(color: .black.opacity(shadowOpacity), radius: 2.5)

            if configuration.current.hasBorder {
                clipShape
                    .inset(by: configuration.current.borderWidth / 2)
                    .stroke(lineWidth: configuration.current.borderWidth)
                    .foregroundStyle(Color(cgColor: configuration.current.borderColor))
            }
        }
        .padding(5)
        .frame(maxWidth: screen.frame.width)
        .fixedSize()
        .onFrameChange(update: $frame)
    }

    @ViewBuilder
    private var content: some View {
        if !ScreenCapture.cachedCheckPermissions() {
            HStack {
                Text("The Vanilla Bar requires screen recording permissions.")

                Button {
                    closePanel()
                    appState.navigationState.settingsNavigationIdentifier = .advanced
                    appState.appDelegate?.openSettingsWindow()
                } label: {
                    Text("Open Vanilla Settings")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.link)
            }
            .padding(.horizontal, 10)
        } else if menuBarManager.isMenuBarHiddenBySystemUserDefaults {
            Text("Vanilla cannot display menu bar items for automatically hidden menu bars")
                .padding(.horizontal, 10)
        } else if imageCache.cacheFailed(for: section) {
            Text("Unable to display menu bar items")
                .padding(.horizontal, 10)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(items, id: \.id) { item in
                        IceBarItemView(item: item, closePanel: closePanel)
                    }
                }
            }
            .environment(\.isScrollEnabled, frame.width == screen.frame.width)
            .defaultScrollAnchor(.trailing)
            .scrollIndicatorsFlash(trigger: scrollIndicatorsFlashTrigger)
            .task {
                scrollIndicatorsFlashTrigger += 1
            }
        }
    }
}

// MARK: - IceBarItemView

private struct IceBarItemView: View {
    @EnvironmentObject var imageCache: MenuBarItemImageCache
    @EnvironmentObject var itemManager: MenuBarItemManager

    let item: MenuBarItem
    let closePanel: () -> Void

    private var leftClickAction: () -> Void {
        return { [weak itemManager] in
            guard let itemManager else {
                return
            }
            closePanel()
            itemManager.showItemAfterClosingPanel(item, mouseButton: .left)
        }
    }

    private var rightClickAction: () -> Void {
        return { [weak itemManager] in
            guard let itemManager else {
                return
            }
            closePanel()
            itemManager.showItemAfterClosingPanel(item, mouseButton: .right)
        }
    }

    private var image: NSImage? {
        imageCache.images[item.info]?.barNSImage
    }

    var body: some View {
        if let image {
            Image(nsImage: image)
                .contentShape(Rectangle())
                .overlay {
                    IceBarItemClickView(item: item, leftClickAction: leftClickAction, rightClickAction: rightClickAction)
                }
                .accessibilityLabel(item.displayName)
                .accessibilityAction(named: "left click", leftClickAction)
                .accessibilityAction(named: "right click", rightClickAction)
        }
    }
}

// MARK: - IceBarItemClickView

private struct IceBarItemClickView: NSViewRepresentable {
    private final class Represented: NSView {
        let item: MenuBarItem

        let leftClickAction: () -> Void
        let rightClickAction: () -> Void

        private var lastLeftMouseDownDate = Date.now
        private var lastRightMouseDownDate = Date.now

        private var lastLeftMouseDownLocation = CGPoint.zero
        private var lastRightMouseDownLocation = CGPoint.zero

        init(item: MenuBarItem, leftClickAction: @escaping () -> Void, rightClickAction: @escaping () -> Void) {
            self.item = item
            self.leftClickAction = leftClickAction
            self.rightClickAction = rightClickAction
            super.init(frame: .zero)
            self.toolTip = item.displayName
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func absoluteDistance(_ p1: CGPoint, _ p2: CGPoint) -> CGFloat {
            hypot(p1.x - p2.x, p1.y - p2.y).magnitude
        }

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            lastLeftMouseDownDate = .now
            lastLeftMouseDownLocation = NSEvent.mouseLocation
        }

        override func rightMouseDown(with event: NSEvent) {
            super.rightMouseDown(with: event)
            lastRightMouseDownDate = .now
            lastRightMouseDownLocation = NSEvent.mouseLocation
        }

        override func mouseUp(with event: NSEvent) {
            super.mouseUp(with: event)
            guard
                Date.now.timeIntervalSince(lastLeftMouseDownDate) < 0.5,
                absoluteDistance(lastLeftMouseDownLocation, NSEvent.mouseLocation) < 5
            else {
                return
            }
            leftClickAction()
        }

        override func rightMouseUp(with event: NSEvent) {
            super.rightMouseUp(with: event)
            guard
                Date.now.timeIntervalSince(lastRightMouseDownDate) < 0.5,
                absoluteDistance(lastRightMouseDownLocation, NSEvent.mouseLocation) < 5
            else {
                return
            }
            rightClickAction()
        }
    }

    let item: MenuBarItem

    let leftClickAction: () -> Void
    let rightClickAction: () -> Void

    func makeNSView(context: Context) -> NSView {
        Represented(item: item, leftClickAction: leftClickAction, rightClickAction: rightClickAction)
    }

    func updateNSView(_ nsView: NSView, context: Context) { }
}

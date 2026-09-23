//
//  IceBarColorManager.swift
//  Ice
//

import Cocoa
import Combine

@MainActor
final class IceBarColorManager: ObservableObject {
    @Published private(set) var colorInfo: MenuBarAverageColorInfo?

    private weak var iceBarPanel: IceBarPanel?

    private var windowImage: CGImage?
    private var colorSource = MenuBarAverageColorInfo.Source.menuBarWindow

    private var cancellables = Set<AnyCancellable>()
    private var captureTask: Task<Void, Never>?
    private var isUpdating = false

    init(iceBarPanel: IceBarPanel) {
        self.iceBarPanel = iceBarPanel
    }

    isolated deinit {
        captureTask?.cancel()
    }

    func startUpdating() {
        guard !isUpdating, iceBarPanel?.isVisible == true else { return }
        isUpdating = true
        configureCancellables()
        Logger.iceBarColor.debug("Started visible panel color updates")
    }

    func stopUpdating() {
        if isUpdating { Logger.iceBarColor.debug("Stopped panel color updates") }
        isUpdating = false
        cancellables.removeAll()
        captureTask?.cancel()
        captureTask = nil
        windowImage = nil
        colorInfo = nil
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let iceBarPanel {
            iceBarPanel.publisher(for: \.screen)
                .dropFirst() // Preparation already captured the panel's initial screen.
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak iceBarPanel] screen in
                    guard
                        let self,
                        isUpdating,
                        iceBarPanel?.isVisible == true,
                        let screen
                    else {
                        return
                    }
                    updateWindowImage(for: screen)
                }
                .store(in: &c)

            Publishers.CombineLatest(
                iceBarPanel.publisher(for: \.frame),
                iceBarPanel.publisher(for: \.isVisible)
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak iceBarPanel] frame, isVisible in
                guard
                    let self,
                    isUpdating,
                    let screen = iceBarPanel?.screen,
                    isVisible
                else {
                    return
                }
                updateColorInfo(with: frame, screen: screen)
            }
            .store(in: &c)

            Publishers.Merge4(
                NSWorkspace.shared.notificationCenter
                    .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
                    .mapToVoid(),
                NotificationCenter.default
                    .publisher(for: NSApplication.didChangeScreenParametersNotification)
                    .mapToVoid(),
                DistributedNotificationCenter.default()
                    .publisher(for: DistributedNotificationCenter.interfaceThemeChangedNotification)
                    .mapToVoid(),
                Timer.publish(every: 5, on: .main, in: .default)
                    .autoconnect()
                    .mapToVoid()
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak iceBarPanel] in
                guard
                    let self,
                    isUpdating,
                    let iceBarPanel,
                    iceBarPanel.isVisible,
                    let screen = iceBarPanel.screen
                else {
                    return
                }
                updateWindowImage(for: screen)
            }
            .store(in: &c)
        }

        cancellables = c
    }

    private func updateWindowImage(for screen: NSScreen) {
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            guard !Task.isCancelled, let self, isUpdating, iceBarPanel?.isVisible == true else { return }
            await captureWindowImage(for: screen)
            guard !Task.isCancelled, let panel = iceBarPanel, panel.isVisible else { return }
            updateColorInfo(with: panel.frame, screen: screen)
        }
    }

    private func captureWindowImage(for screen: NSScreen) async {
        guard !Task.isCancelled else { return }
        Logger.iceBarColor.debug("Capturing panel background color")
        let displayID = screen.displayID
        if #available(macOS 27, *) {
            let bounds = CGDisplayBounds(displayID)
            let strip = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 1)
            let image = await ScreenCapture.captureRegion(strip)
            guard !Task.isCancelled else { return }
            windowImage = image
            colorSource = .menuBarScreen
            return
        }
        if let window = WindowInfo.getMenuBarWindow(for: displayID) {
            let strip = CGRect(x: window.frame.minX, y: window.frame.minY, width: window.frame.width, height: 1)
            let image = await ScreenCapture.captureRegion(strip)
            guard !Task.isCancelled else { return }
            windowImage = image
            colorSource = .menuBarScreen
        } else {
            guard !Task.isCancelled else { return }
            windowImage = nil
        }
    }

    private func updateColorInfo(with frame: CGRect, screen: NSScreen) {
        guard let windowImage else {
            colorInfo = nil
            return
        }

        let imageBounds = CGRect(x: 0, y: 0, width: windowImage.width, height: windowImage.height)
        let insetScreenFrame = screen.frame.insetBy(dx: frame.width / 2, dy: 0)
        let percentage = ((frame.midX - insetScreenFrame.minX) / insetScreenFrame.width).clamped(to: 0...1)
        let cropRect = CGRect(x: imageBounds.width * percentage, y: 0, width: 0, height: 1)
            .insetBy(dx: -50, dy: 0)
            .intersection(imageBounds)

        guard
            let croppedImage = windowImage.cropping(to: cropRect),
            let averageColor = croppedImage.averageColor()
        else {
            colorInfo = nil
            return
        }

        colorInfo = MenuBarAverageColorInfo(color: averageColor, source: colorSource)
    }

    func updateAllProperties(with frame: CGRect, screen: NSScreen) async {
        captureTask?.cancel()
        await captureWindowImage(for: screen)
        guard !Task.isCancelled else { return }
        updateColorInfo(with: frame, screen: screen)
    }
}

private extension Logger {
    static let iceBarColor = Logger(category: "IceBarColor")
}

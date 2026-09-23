//
//  ScreenCapture.swift
//  Ice
//

import CoreGraphics
import ScreenCaptureKit

/// A namespace for screen capture operations.
enum ScreenCapture {
    @MainActor private static var lastCheckResult: Bool?

    /// Returns a Boolean value that indicates whether the app has been granted screen capture permissions.
    @MainActor
    static func checkPermissions() -> Bool {
        if #available(macOS 27, *) { return CGPreflightScreenCaptureAccess() }
        for item in MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true) {
            // Don't check items owned by Ice.
            if item.owningApplication == .current {
                continue
            }
            return item.title != nil
        }
        // CGPreflightScreenCaptureAccess() only returns an initial value for whether the app
        // has permissions, but we can use it as a fallback.
        return CGPreflightScreenCaptureAccess()
    }

    /// Returns a Boolean value that indicates whether the app has been granted screen capture permissions.
    ///
    /// The first time this function is called, the permissions state is computed, cached, and returned.
    /// Subsequent calls either return the cached value, or recompute the permissions state before caching
    /// and returning it.
    @MainActor
    static func cachedCheckPermissions(reset: Bool = false) -> Bool {
        if !reset {
            if let lastCheckResult = lastCheckResult {
                return lastCheckResult
            }
        }

        let realResult = checkPermissions()
        lastCheckResult = realResult
        return realResult
    }

    /// Requests capture permission through ScreenCaptureKit's content discovery flow.
    @MainActor
    static func requestPermissions() {
        SCShareableContent.getWithCompletionHandler { _, _ in }
    }

    /// Captures an individual window without depending on where it appears on a display.
    static func captureWindow(_ windowID: CGWindowID, screenBounds: CGRect? = nil, scale: CGFloat? = nil) async -> CGImage? {
        let request = WindowCaptureRequest(windowID: windowID, screenBounds: screenBounds, scale: scale)
        return await captureImages([request])[windowID]
    }

    /// Captures a composited region in global Quartz coordinates.
    static func captureRegion(_ bounds: CGRect) async -> CGImage? {
        await WindowCaptureService.shared.captureRegion(bounds)
    }

    /// Captures visible AX item regions in one image, then crops off the UI actor.
    static func captureRegions(_ regions: [MenuBarItemInfo: CGRect], within displayBounds: CGRect) async -> [MenuBarItemInfo: MenuBarRegionCapture] {
        await WindowCaptureService.shared.captureRegions(regions, within: displayBounds)
    }

    /// Captures a batch using a single snapshot of ScreenCaptureKit's available windows.
    static func captureImages(_ requests: [WindowCaptureRequest]) async -> [CGWindowID: CGImage] {
        await WindowCaptureService.shared.captureImages(requests)
    }

    static func previewBackgrounds(for images: [MenuBarItemInfo: CGImage]) async -> [MenuBarItemInfo: MenuBarImageContrast.Background] {
        await WindowCaptureService.shared.previewBackgrounds(for: images)
    }
}

struct MenuBarRegionCapture: Sendable {
    let image: CGImage
    let foreground: CGImage?
}

/// Only value data crosses from the UI to the capture service. Bounds use global Quartz points.
struct WindowCaptureRequest: Equatable, Sendable {
    enum Method: Equatable, Sendable {
        case screenCaptureKit, macOS26MenuBar
    }

    let windowID: CGWindowID
    var screenBounds: CGRect?
    var scale: CGFloat?
    var method: Method = .screenCaptureKit
    var expectedFrame: CGRect?
}

/// Owns ScreenCaptureKit objects and image processing away from the main actor.
private actor WindowCaptureService {
    static let shared = WindowCaptureService()
    private let logger = Logger(category: "ScreenCapture")

    func previewBackgrounds(for images: [MenuBarItemInfo: CGImage]) -> [MenuBarItemInfo: MenuBarImageContrast.Background] {
        var backgrounds = [MenuBarItemInfo: MenuBarImageContrast.Background]()
        for (info, image) in images {
            guard !Task.isCancelled else { return [:] }
            backgrounds[info] = MenuBarImageContrast.background(for: image)
        }
        return backgrounds
    }

    func captureImages(_ requests: [WindowCaptureRequest]) async -> [CGWindowID: CGImage] {
        guard !requests.isEmpty, !Task.isCancelled else { return [:] }
        var images = [CGWindowID: CGImage]()
        for request in requests where request.method == .macOS26MenuBar {
            guard !Task.isCancelled else { return [:] }
            guard
                let frame = request.expectedFrame,
                let image = MenuBarWindowCapture.capture(windowID: request.windowID, expectedFrame: frame)
            else { continue }
            if let bounds = request.screenBounds {
                guard let crop = CaptureGeometry.pixelRect(for: bounds, windowFrame: frame, imageSize: CGSize(width: image.width, height: image.height)) else { continue }
                images[request.windowID] = image.cropping(to: crop)
            } else {
                images[request.windowID] = image
            }
        }
        let requests = requests.filter { $0.method == .screenCaptureKit }
        guard !requests.isEmpty else { return images }
        do {
            // Include offscreen and desktop windows: hidden menu bar items need both.
            // https://developer.apple.com/documentation/screencapturekit/scshareablecontent
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            for request in requests {
                guard !Task.isCancelled else { return [:] }
                guard let window = content.windows.first(where: { $0.windowID == request.windowID }) else { continue }
                do {
                    if let image = try await capture(request, window: window) {
                        images[request.windowID] = image
                    }
                } catch {
                    // Record only the error code, never a title or captured content.
                    logger.debug("Window capture returned error code \((error as NSError).code)")
                }
            }
            return images
        } catch {
            logger.debug("Capture discovery returned error code \((error as NSError).code)")
            return images
        }
    }

    func captureRegion(_ bounds: CGRect) async -> CGImage? {
        guard
            !Task.isCancelled, CGPreflightScreenCaptureAccess(),
            !bounds.isNull, !bounds.isEmpty,
            bounds.origin.x.isFinite, bounds.origin.y.isFinite,
            bounds.width.isFinite, bounds.height.isFinite
        else { return nil }
        do {
            // The older rectangle API leaked one image and IOSurface per call
            // in the macOS 26.5 comparison. The macOS 26 screenshot output owns
            // its images correctly in that probe; keep SDR for icon processing.
            // Evidence: docs/audits/2026-09-21-capture-retention.txt.
            let configuration = SCScreenshotConfiguration()
            configuration.showsCursor = false
            configuration.dynamicRange = .sdr
            let output = try await SCScreenshotManager.captureScreenshot(rect: bounds, configuration: configuration)
            try Task.checkCancellation()
            return output.sdrImage
        } catch {
            logger.debug("Region capture returned error code \((error as NSError).code)")
            return nil
        }
    }

    func captureRegions(_ regions: [MenuBarItemInfo: CGRect], within displayBounds: CGRect) async -> [MenuBarItemInfo: MenuBarRegionCapture] {
        guard !regions.isEmpty, !Task.isCancelled else { return [:] }
        // The extra rows sample the backdrop outside the glyphs. Keep the
        // original item rectangles for output size and hit testing.
        let bounds = regions.values.reduce(CGRect.null) { $0.union($1) }
            .insetBy(dx: 0, dy: -2)
            .intersection(displayBounds)
        guard !bounds.isNull, !bounds.isEmpty else { return [:] }
        // All regions are validated against a single display's menu bar before arrival.
        // https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/capturescreenshot(rect:configuration:completionhandler:)
        guard let image = await captureRegion(bounds), !Task.isCancelled else { return [:] }
        let foreground = MenuBarImageBackground.remove(from: image)
        var images = [MenuBarItemInfo: MenuBarRegionCapture]()
        for (info, region) in regions {
            guard let crop = CaptureGeometry.pixelRect(
                for: region,
                windowFrame: bounds,
                imageSize: CGSize(width: image.width, height: image.height)
            ) else { continue }
            guard let cropped = image.cropping(to: crop) else { continue }
            images[info] = MenuBarRegionCapture(image: cropped, foreground: foreground?.cropping(to: crop))
        }
        return images
    }

    private func capture(_ request: WindowCaptureRequest, window: SCWindow) async throws -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = request.scale ?? CGFloat(filter.pointPixelScale)
        guard scale.isFinite, scale > 0, window.frame.width > 0, window.frame.height > 0 else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = Int((window.frame.width * scale).rounded(.up))
        configuration.height = Int((window.frame.height * scale).rounded(.up))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        guard let bounds = request.screenBounds else { return image }
        // Crop the window image in backing pixels, not display or AppKit coordinates.
        guard let crop = CaptureGeometry.pixelRect(
            for: bounds,
            windowFrame: window.frame,
            imageSize: CGSize(width: image.width, height: image.height)
        ) else { return nil }
        return image.cropping(to: crop)
    }
}

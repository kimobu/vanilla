//
//  MenuBarWindowCapture.swift
//  Ice
//

import CoreGraphics
import Darwin
import Foundation

/// macOS 26 compatibility for fully offscreen status-item windows.
/// Both ScreenCaptureKit screenshot APIs returned -3811 for these windows on
/// 26.5 (25F71), while Ice's original capture API returned their images.
/// Keep this SDK-obsolete symbol isolated and optional, with explicit ownership.
/// Evidence: docs/audits/2026-09-21-capture-api-comparison.txt.
enum MenuBarWindowCapture {
    static func capture(windowID: CGWindowID, expectedFrame: CGRect) -> CGImage? {
        guard #unavailable(macOS 27), CGPreflightScreenCaptureAccess() else { return nil }
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "CGWindowListCreateImageFromArray") else { return nil }
        typealias Capture = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        let capture = unsafeBitCast(symbol, to: Capture.self)

        // Window-ID arrays contain raw integer values, not CFNumber objects.
        // CFArray copies that one value; there is no allocated pointer to leak.
        var rawID = UnsafeRawPointer(bitPattern: UInt(windowID))
        guard let windows = CFArrayCreate(kCFAllocatorDefault, &rawID, 1, nil) else { return nil }
        guard
            let descriptions = CGWindowListCreateDescriptionFromArray(windows) as? [[CFString: Any]],
            let description = descriptions.first,
            let bounds = description[kCGWindowBounds] as? NSDictionary,
            CGRect(dictionaryRepresentation: bounds) == expectedFrame,
            description[kCGWindowLayer] as? Int == Int(kCGStatusWindowLevel)
        else { return nil }
        let options: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        return capture(.null, windows, options.rawValue)?.takeRetainedValue()
    }
}

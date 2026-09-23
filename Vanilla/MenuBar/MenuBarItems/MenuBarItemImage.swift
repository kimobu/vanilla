//
//  MenuBarItemImage.swift
//  Ice
//

import AppKit

/// Retained hidden icons may come from a different display than the next refresh.
/// Keep their capture scale with their pixels instead of using the current screen.
struct MenuBarItemImage: Equatable, Sendable {
    let cgImage: CGImage
    let scale: CGFloat
    var barCGImage: CGImage?

    @MainActor
    var nsImage: NSImage {
        let size = CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        return NSImage(cgImage: cgImage, size: size)
    }

    @MainActor
    var barNSImage: NSImage {
        NSImage(cgImage: barCGImage ?? cgImage, size: nsImage.size)
    }
}

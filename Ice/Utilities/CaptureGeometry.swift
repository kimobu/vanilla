//
//  CaptureGeometry.swift
//  Ice
//

import CoreGraphics

/// A value snapshot: an NSScreen reference alone cannot identify capture geometry.
struct CaptureDisplayGeometry: Equatable, Sendable {
    let id: CGDirectDisplayID
    let bounds: CGRect
    let scale: CGFloat
}

enum CaptureGeometry {
    /// Chooses the real menu-bar row using our current AX controls as anchors.
    /// A retracted full-screen bar is above its display; the inactive desktop
    /// bar may still have a window at the display's top edge.
    static func menuBarRow(display: CGRect, candidates: [CGRect], anchors: [CGRect]) -> CGRect? {
        let matches = candidates.filter { candidate in
            !candidate.isEmpty && !candidate.isNull &&
                candidate.minX == display.minX && candidate.width == display.width &&
                anchors.contains { anchor in
                    !anchor.isEmpty && !anchor.isNull &&
                        anchor.minY >= candidate.minY && anchor.maxY <= candidate.maxY
                }
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// AX describes the button inside its host window. Match both centers and
    /// containment; names and a shared Control Center PID cannot identify it.
    static func matchesHostWindow(_ window: CGRect, item: CGRect) -> Bool {
        guard !window.isEmpty, !window.isNull, !item.isEmpty, !item.isNull else { return false }
        return abs(window.midX - item.midX) <= 2 && abs(window.midY - item.midY) <= 2 &&
            window.insetBy(dx: -2, dy: -2).contains(item)
    }

    /// Converts global Quartz bounds to pixels in a captured window image.
    /// Using the actual image size also accounts for rounding at fractional scales.
    static func pixelRect(for bounds: CGRect, windowFrame: CGRect, imageSize: CGSize) -> CGRect? {
        guard
            windowFrame.width > 0, windowFrame.height > 0,
            imageSize.width > 0, imageSize.height > 0,
            windowFrame.width.isFinite, windowFrame.height.isFinite,
            imageSize.width.isFinite, imageSize.height.isFinite
        else { return nil }

        let intersection = bounds.intersection(windowFrame)
        guard !intersection.isNull, !intersection.isEmpty else { return nil }
        let scaleX = imageSize.width / windowFrame.width
        let scaleY = imageSize.height / windowFrame.height
        return CGRect(
            x: (intersection.minX - windowFrame.minX) * scaleX,
            y: (intersection.minY - windowFrame.minY) * scaleY,
            width: intersection.width * scaleX,
            height: intersection.height * scaleY
        )
    }
}

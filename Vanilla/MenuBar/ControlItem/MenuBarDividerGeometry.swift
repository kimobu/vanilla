//
//  MenuBarDividerGeometry.swift
//  Ice
//

import CoreGraphics

/// Keeps a macOS 27 separator below the width at which the system discards it.
enum MenuBarDividerGeometry {
    /// Pass each display's usable trailing menu-bar width, including notch limits.
    static func maximumLength(availableWidths: [CGFloat]) -> CGFloat? {
        guard let narrowest = availableWidths.filter({ $0.isFinite && $0 > 2 }).min() else { return nil }
        // macOS 27's half-width cutoff is observed behavior, not an AppKit contract.
        // Leave room below it rather than depending on equality or pixel rounding.
        // https://github.com/junior-rj/menubar-hide#how-it-works
        return max(1, floor(narrowest / 2) - 64)
    }

    /// Enough individually bounded status items to span the widest menu bar.
    static func supplementalCount(availableWidths: [CGFloat]) -> Int {
        guard
            let length = maximumLength(availableWidths: availableWidths),
            let widest = availableWidths.filter({ $0.isFinite && $0 > 2 }).max()
        else { return 0 }
        return Int(min(64, max(0, ceil(widest / length) - 1)))
    }
}

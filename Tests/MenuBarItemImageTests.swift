//
//  MenuBarItemImageTests.swift
//  Ice
//

import AppKit
import Testing

@MainActor
struct MenuBarItemImageTests {
    private func image(pixels: Int, scale: CGFloat) throws -> MenuBarItemImage {
        let context = try #require(CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return MenuBarItemImage(cgImage: try #require(context.makeImage()), scale: scale)
    }

    @Test func partialRefreshRetainsEachImagesCaptureScale() throws {
        // A hidden 2x image survives while a visible item is recaptured at 1x.
        var images = [
            "hidden": try image(pixels: 48, scale: 2),
            "visible": try image(pixels: 48, scale: 2),
        ]
        images["visible"] = try image(pixels: 24, scale: 1)
        let expected = CGSize(width: 24, height: 24)
        #expect(images["hidden"]?.nsImage.size == expected)
        #expect(images["visible"]?.nsImage.size == expected)
        #expect(images["hidden"]?.cgImage.width == 48)
        #expect(images["visible"]?.cgImage.width == 24)

        // Capturing the hidden item on the new screen preserves its point size.
        images["hidden"] = try image(pixels: 24, scale: 1)
        #expect(images["hidden"]?.nsImage.size == expected)
    }
}

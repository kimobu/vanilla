//
//  MenuBarImageContrastTests.swift
//  Ice
//

import CoreGraphics
import Testing

struct MenuBarImageContrastTests {
    private func image(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat, inset: CGFloat = 0) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: 64,
            height: 32,
            bitsPerComponent: 8,
            bytesPerRow: 256,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let color = try #require(CGColor(colorSpace: space, components: [red, green, blue, alpha]))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32).insetBy(dx: inset, dy: inset))
        return try #require(context.makeImage())
    }

    @Test func whiteAndBlackIconsChooseOppositeBackgrounds() throws {
        #expect(MenuBarImageContrast.background(for: try image(red: 1, green: 1, blue: 1, alpha: 1)) == .dark)
        #expect(MenuBarImageContrast.background(for: try image(red: 0, green: 0, blue: 0, alpha: 1)) == .light)
    }

    @Test func sparseTranslucentWhiteDoesNotBecomeDarkWhenAveraged() throws {
        #expect(MenuBarImageContrast.background(for: try image(red: 1, green: 1, blue: 1, alpha: 0.1, inset: 15)) == .dark)
    }

    @Test func transparentImagesHaveNoPreferredBackground() throws {
        #expect(MenuBarImageContrast.background(for: try image(red: 1, green: 1, blue: 1, alpha: 0)) == nil)
    }

    @Test func saturatedColorsUseLuminanceInsteadOfAverageRGB() throws {
        #expect(MenuBarImageContrast.background(for: try image(red: 0, green: 0, blue: 1, alpha: 1)) == .light)
        #expect(MenuBarImageContrast.background(for: try image(red: 0, green: 1, blue: 0, alpha: 1)) == .dark)
    }
}

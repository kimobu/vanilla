//
//  MenuBarImageBackgroundTests.swift
//  Ice
//

import CoreGraphics
import Testing

struct MenuBarImageBackgroundTests {
    private func image(background: Bool = true, glyph: [CGFloat]) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: 24,
            height: 24,
            bitsPerComponent: 8,
            bytesPerRow: 96,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        if background {
            for y in 0..<24 {
                let value = CGFloat(64 + y * 3) / 255
                context.setFillColor(red: value, green: value, blue: value, alpha: 1)
                context.fill(CGRect(x: 0, y: y, width: 24, height: 1))
            }
        }
        context.setFillColor(red: glyph[0], green: glyph[1], blue: glyph[2], alpha: glyph[3])
        context.fill(CGRect(x: 8, y: 8, width: 8, height: 8))
        return try #require(context.makeImage())
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let data = try #require(image.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        let offset = y * image.bytesPerRow + x * 4
        return Array(UnsafeBufferPointer(start: bytes + offset, count: 4))
    }

    @Test func gradientDisappearsButWhiteGlyphRemains() throws {
        let result = try #require(MenuBarImageBackground.remove(from: image(glyph: [1, 1, 1, 1])))
        #expect(try pixel(result, x: 2, y: 12) == [0, 0, 0, 0])
        #expect(try pixel(result, x: 12, y: 12) == [255, 255, 255, 255])
        #expect(result.width == 24 && result.height == 24)
    }

    @Test func blackGlyphRetainsItsColor() throws {
        let result = try #require(MenuBarImageBackground.remove(from: image(glyph: [0, 0, 0, 1])))
        #expect(try pixel(result, x: 12, y: 12) == [0, 0, 0, 255])
    }

    @Test func coloredGlyphIsNotConvertedToMonochrome() throws {
        let result = try #require(MenuBarImageBackground.remove(from: image(glyph: [1, 0, 0, 1])))
        #expect(try pixel(result, x: 12, y: 12) == [255, 0, 0, 255])
    }

    @Test func antialiasingRetainsPartialCoverage() throws {
        let result = try #require(MenuBarImageBackground.remove(from: image(glyph: [1, 1, 1, 0.5])))
        let sample = try pixel(result, x: 12, y: 12)
        #expect((125...130).contains(Int(sample[3])))
        #expect(sample[0] == sample[3] && sample[1] == sample[3] && sample[2] == sample[3])
    }

    @Test func transparentWindowCapturePassesThroughUnchanged() throws {
        let original = try image(background: false, glyph: [0.3, 0.7, 1, 0.5])
        let result = try #require(MenuBarImageBackground.remove(from: original))
        #expect(result === original)
    }
}

//
//  MenuBarImageBackground.swift
//  Ice
//

import CoreGraphics
import Foundation

/// Separates menu-bar glyphs from a composited capture with empty rows above
/// and below the controls. Work runs on the capture actor, never while drawing.
enum MenuBarImageBackground {
    static func remove(from image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 2, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            // Window captures that already contain transparency need no matting.
            guard stride(from: 3, to: bytes.count, by: 4).allSatisfy({ bytes[$0] == 255 }) else {
                return image
            }
            let top = Array(bytes.prefix(width * 4))
            let bottom = Array(bytes.suffix(width * 4))
            // A diagonal wallpaper feature can cross between the two sample
            // rows. Nearby edge colors identify those pixels as backdrop too.
            let palettes = (0..<width).map { x in
                [top, bottom].flatMap { row in
                    (-4...4).map { step in
                        let edge = min(width - 1, max(0, x + step * max(1, height / 4))) * 4
                        return SIMD3(Double(row[edge]), Double(row[edge + 1]), Double(row[edge + 2])) / 255
                    }
                }
            }
            for y in 0..<height {
                let fraction = Double(y) / Double(height - 1)
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    var background = SIMD3<Double>()
                    var color = SIMD3<Double>()
                    var alpha = 0.0
                    for channel in 0..<3 {
                        let edge = x * 4 + channel
                        let base = (Double(top[edge]) * (1 - fraction) + Double(bottom[edge]) * fraction) / 255
                        let value = Double(bytes[offset + channel]) / 255
                        background[channel] = base
                        color[channel] = value
                        // Solve C = aF + (1-a)B with the smallest alpha that
                        // keeps every foreground channel in range. This retains
                        // colored glyphs and antialiased white/black strokes.
                        let difference = value - base
                        let range = difference >= 0 ? 1 - base : base
                        if range > 0 { alpha = max(alpha, abs(difference) / range) }
                    }
                    // Ignore capture quantization and small backdrop variation.
                    let difference = color - background
                    let contrast = max(abs(difference.x), abs(difference.y), abs(difference.z))
                    let palette = palettes[x]
                    var edgeContrast = contrast
                    for index in 1..<palette.count where index != 9 {
                        let start = palette[index - 1]
                        let direction = palette[index] - start
                        let delta = color - start
                        let length = (direction * direction).sum()
                        let position = length > 0 ? min(1, max(0, (delta * direction).sum() / length)) : 0
                        let residual = delta - direction * position
                        edgeContrast = min(edgeContrast, max(abs(residual.x), abs(residual.y), abs(residual.z)))
                    }
                    let coverage = min(1, max(0, (edgeContrast - 3.0 / 255) / (5.0 / 255)))
                    alpha = min(1, alpha) * coverage
                    for channel in 0..<3 {
                        let premultiplied = (color[channel] - background[channel]) * coverage + background[channel] * alpha
                        bytes[offset + channel] = UInt8((min(alpha, max(0, premultiplied)) * 255).rounded())
                    }
                    bytes[offset + 3] = UInt8((alpha * 255).rounded())
                }
            }
            return context.makeImage()
        }
    }
}

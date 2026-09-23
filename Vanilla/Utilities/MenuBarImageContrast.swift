//
//  MenuBarImageContrast.swift
//  Ice
//

import CoreGraphics
import Foundation

/// Chooses a preview background without changing the captured icon's colors.
enum MenuBarImageContrast {
    enum Background: Equatable, Sendable {
        case light, dark
    }

    static func background(for image: CGImage) -> Background? {
        let width = min(image.width, 64)
        let height = min(image.height, 32)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
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
            var luminance = 0.0
            var weight = 0.0
            for index in stride(from: 0, to: bytes.count, by: 4) {
                let alpha = Double(bytes[index + 3]) / 255
                guard alpha > 0 else { continue }
                // Undo premultiplication so thin white strokes remain white.
                let red = linear(Double(bytes[index]) / 255 / alpha)
                let green = linear(Double(bytes[index + 1]) / 255 / alpha)
                let blue = linear(Double(bytes[index + 2]) / 255 / alpha)
                luminance += (0.2126 * red + 0.7152 * green + 0.0722 * blue) * alpha
                weight += alpha
            }
            guard weight > 0 else { return nil }
            let average = luminance / weight
            // Compare black and white using relative luminance. This is a
            // preview heuristic, not a contrast guarantee for every pixel.
            // https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html
            return (average + 0.05) / 0.05 >= 1.05 / (average + 0.05) ? .dark : .light
        }
    }

    private static func linear(_ component: Double) -> Double {
        let value = min(max(component, 0), 1)
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}

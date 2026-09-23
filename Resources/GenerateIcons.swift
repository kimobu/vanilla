//
//  GenerateIcons.swift
//  Vanilla
//

// Run from the repository root: swift Resources/GenerateIcons.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Ice/Assets.xcassets")

func mark() -> NSBezierPath {
    let path = NSBezierPath()
    let points: [CGPoint] = [
        CGPoint(x: 222, y: 750), CGPoint(x: 355, y: 750),
        CGPoint(x: 512, y: 374), CGPoint(x: 669, y: 750),
        CGPoint(x: 802, y: 750), CGPoint(x: 560, y: 204),
        CGPoint(x: 464, y: 204),
    ]
    path.move(to: points[0])
    for point in points.dropFirst() { path.line(to: point) }
    path.close()
    return path
}

func png(size: Int, appIcon: Bool, outline: Bool = false) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    let transform = AffineTransform(scale: CGFloat(size) / 1024)
    (transform as NSAffineTransform).concat()

    if appIcon {
        // Keep the full-resolution artwork and its transparent outer margin.
        // Regenerating the asset catalog must not restore the original block V.
        let sourceURL = root.appendingPathComponent("Resources/AppIconSource.png")
        guard let source = NSImage(contentsOf: sourceURL), source.size.width == source.size.height else {
            throw CocoaError(.fileReadCorruptFile)
        }
        context.imageInterpolation = .high
        source.draw(in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    } else {
        // Template artwork uses the system menu bar color in either appearance.
        let path = mark()
        let transform = AffineTransform(translationByX: -180, byY: -160)
        path.transform(using: transform)
        path.transform(using: AffineTransform(scale: 1.55))
        NSColor.black.set()
        if outline {
            path.lineWidth = 65
            path.lineJoinStyle = .round
            path.stroke()
        } else {
            path.fill()
        }
    }
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 1 ? "" : "@2x"
        let url = assets.appendingPathComponent("AppIcon.appiconset/icon_\(size)x\(size)\(suffix).png")
        try png(size: size * scale, appIcon: true).write(to: url)
    }
}
try png(size: 1024, appIcon: true).write(to: root.appendingPathComponent("Resources/Icon.png"))

for (name, outline) in [("VanillaMarkFill", false), ("VanillaMarkStroke", true)] {
    let directory = assets.appendingPathComponent("ControlItemImages/\(name).imageset")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try png(size: 64, appIcon: false, outline: outline).write(to: directory.appendingPathComponent("\(name).png"))
    let contents = """
    {
      "images" : [
        { "filename" : "\(name).png", "idiom" : "universal", "scale" : "2x" }
      ],
      "info" : { "author" : "xcode", "version" : 1 },
      "properties" : { "template-rendering-intent" : "template" }
    }
    """
    try contents.write(to: directory.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

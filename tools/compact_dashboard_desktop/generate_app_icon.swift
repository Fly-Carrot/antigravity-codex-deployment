import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let fileManager = FileManager.default

let iconsetURL = outputDirectory.appendingPathComponent("Fabric.iconset", isDirectory: true)
try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let iconSpecs: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.18
    let tileRect = rect.insetBy(dx: inset, dy: inset)
    let tileRadius = size * 0.18

    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.12)
    shadow.shadowBlurRadius = size * 0.028
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.set()

    let tilePath = NSBezierPath(roundedRect: tileRect, xRadius: tileRadius, yRadius: tileRadius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.15, green: 0.47, blue: 0.91, alpha: 1.0),
        NSColor(calibratedRed: 0.12, green: 0.73, blue: 0.84, alpha: 1.0),
    ])!
    gradient.draw(in: tilePath, angle: -30)

    NSColor(calibratedWhite: 1.0, alpha: 0.14).setStroke()
    tilePath.lineWidth = max(0.8, size * 0.003)
    tilePath.stroke()

    let center = NSPoint(x: tileRect.midX, y: tileRect.midY)
    let rotation = NSAffineTransform()
    rotation.translateX(by: center.x, yBy: center.y)
    rotation.rotate(byDegrees: -14)
    rotation.translateX(by: -center.x, yBy: -center.y)

    NSGraphicsContext.saveGraphicsState()
    rotation.concat()

    let layerHeights = size * 0.058
    let corner = layerHeights / 2
    let widths: [CGFloat] = [size * 0.20, size * 0.16, size * 0.12]
    let spacing = size * 0.032
    let yPositions: [CGFloat] = [
        center.y + layerHeights + spacing,
        center.y - layerHeights / 2,
        center.y - layerHeights - spacing,
    ]

    for (index, width) in widths.enumerated() {
        let layerRect = NSRect(
            x: center.x - width / 2,
            y: yPositions[index],
            width: width,
            height: layerHeights
        )
        let layerPath = NSBezierPath(roundedRect: layerRect, xRadius: corner, yRadius: corner)
        NSColor(calibratedWhite: 1.0, alpha: 0.96).setFill()
        layerPath.fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "IconGen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to generate PNG data."])
    }
    try png.write(to: url)
}

for spec in iconSpecs {
    let image = drawIcon(size: spec.pixels)
    try writePNG(image, to: iconsetURL.appendingPathComponent(spec.name))
}

print(iconsetURL.path)

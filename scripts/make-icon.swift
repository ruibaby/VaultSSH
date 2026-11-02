import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("packaging/AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int) -> Data? {
    let canvas = CGFloat(size)
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high

    let rect = NSRect(x: 0, y: 0, width: canvas, height: canvas)
    let inset = canvas * 0.055
    let shape = NSBezierPath(
        roundedRect: rect.insetBy(dx: inset, dy: inset),
        xRadius: canvas * 0.225,
        yRadius: canvas * 0.225
    )
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.13, green: 0.17, blue: 0.30, alpha: 1),
        NSColor(calibratedRed: 0.035, green: 0.05, blue: 0.10, alpha: 1)
    ])!
    gradient.draw(in: shape, angle: -60)

    NSColor.white.withAlphaComponent(0.09).setStroke()
    shape.lineWidth = max(1, canvas * 0.006)
    shape.stroke()

    // A soft accent glow behind the key.
    let glowRect = NSRect(
        x: canvas * 0.25,
        y: canvas * 0.25,
        width: canvas * 0.5,
        height: canvas * 0.5
    )
    let glow = NSGradient(colors: [
        NSColor(calibratedRed: 0.35, green: 0.62, blue: 1.0, alpha: 0.26),
        NSColor(calibratedRed: 0.35, green: 0.62, blue: 1.0, alpha: 0.0)
    ])!
    glow.draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: .zero)

    if let symbol = NSImage(systemSymbolName: "key.horizontal.fill", accessibilityDescription: nil) {
        let configuration = NSImage.SymbolConfiguration(pointSize: canvas * 0.44, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white]))
        if let tinted = symbol.withSymbolConfiguration(configuration) {
            let symbolSize = tinted.size
            let origin = NSPoint(
                x: (canvas - symbolSize.width) / 2,
                y: (canvas - symbolSize.height) / 2
            )
            tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let representation = NSBitmapImageRep(data: tiff),
          let png = representation.representation(using: .png, properties: [:]) else {
        return nil
    }
    return png
}

let outputs: [(Int, [String])] = [
    (16, ["icon_16x16.png"]),
    (32, ["icon_16x16@2x.png", "icon_32x32.png"]),
    (64, ["icon_32x32@2x.png"]),
    (128, ["icon_128x128.png"]),
    (256, ["icon_128x128@2x.png", "icon_256x256.png"]),
    (512, ["icon_256x256@2x.png", "icon_512x512.png"]),
    (1024, ["icon_512x512@2x.png"])
]

for (size, names) in outputs {
    guard let data = render(size: size) else {
        FileHandle.standardError.write(Data("failed to render \(size)px\n".utf8))
        exit(1)
    }
    for name in names {
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
print(iconset.path)

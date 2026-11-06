import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = output.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rendered(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.04, dy: size * 0.04), xRadius: size * 0.22, yRadius: size * 0.22).fill()
    let title = "T" as NSString
    let font = NSFont.systemFont(ofSize: size * 0.58, weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(calibratedRed: 0.49, green: 0.86, blue: 0.67, alpha: 1),
    ]
    let bounds = title.size(withAttributes: attributes)
    title.draw(
        at: NSPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2 - size * 0.04),
        withAttributes: attributes
    )
    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return }
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
    try data.write(to: url)
}

let master = rendered(size: 1024)
let specs: [(String, Int)] = [
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
for (name, pixels) in specs {
    try writePNG(master, pixels: pixels, to: iconset.appendingPathComponent(name))
}
print(iconset.path)

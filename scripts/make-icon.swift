// Draws Lipi's app icon: a saffron-to-pink squircle with "लि" (the first letter of Lipi).
// Usage: swift scripts/make-icon.swift OUTPUT_DIR   (then iconutil -c icns OUTPUT_DIR/AppIcon.iconset)
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 186 * s, yRadius: 186 * s)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28 * s
    shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    shape.addClip()
    NSGradient(colors: [NSColor(red: 1.0, green: 0.60, blue: 0.18, alpha: 1),
                        NSColor(red: 0.97, green: 0.38, blue: 0.20, alpha: 1),
                        NSColor(red: 0.84, green: 0.16, blue: 0.45, alpha: 1)])!.draw(in: body, angle: -55)
    // Soft glass highlight on the top half.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.32), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)

    let font = NSFont(name: "KohinoorDevanagari-Semibold", size: 520 * s) ?? NSFont.systemFont(ofSize: 520 * s, weight: .bold)
    let glyph = NSAttributedString(string: "लि", attributes: [.font: font, .foregroundColor: NSColor.white])
    let g = glyph.size()
    glyph.draw(at: NSPoint(x: body.midX - g.width / 2, y: body.midY - g.height / 2 + 10 * s))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let data = draw(CGFloat(px)).representation(using: .png, properties: [:])!
    try! data.write(to: out.appendingPathComponent("icon_\(name).png"))
}
print(out.path)

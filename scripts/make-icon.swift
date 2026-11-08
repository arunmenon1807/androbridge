// Draws the AndroBridge app icon and writes an .iconset. Run by build-app.sh.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let s = size / 1024
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let bg = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.20, green: 0.45, blue: 0.98, alpha: 1),
                        NSColor(red: 0.10, green: 0.75, blue: 0.62, alpha: 1)])!.draw(in: bg, angle: -60)
    NSColor.white.setStroke()
    NSColor.white.setFill()
    // Laptop (left) and phone (right) joined by a bridge arc.
    let laptop = NSBezierPath(roundedRect: NSRect(x: 220 * s, y: 420 * s, width: 250 * s, height: 170 * s), xRadius: 18 * s, yRadius: 18 * s)
    laptop.lineWidth = 34 * s; laptop.stroke()
    NSBezierPath(roundedRect: NSRect(x: 190 * s, y: 385 * s, width: 310 * s, height: 30 * s), xRadius: 12 * s, yRadius: 12 * s).fill()
    let phone = NSBezierPath(roundedRect: NSRect(x: 610 * s, y: 360 * s, width: 170 * s, height: 290 * s), xRadius: 30 * s, yRadius: 30 * s)
    phone.lineWidth = 34 * s; phone.stroke()
    let arc = NSBezierPath()
    arc.move(to: NSPoint(x: 345 * s, y: 640 * s))
    arc.curve(to: NSPoint(x: 695 * s, y: 690 * s), controlPoint1: NSPoint(x: 400 * s, y: 820 * s), controlPoint2: NSPoint(x: 640 * s, y: 840 * s))
    arc.lineWidth = 30 * s; arc.lineCapStyle = .round; arc.stroke()
    img.unlockFocus()
    return img
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGFloat(px)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}

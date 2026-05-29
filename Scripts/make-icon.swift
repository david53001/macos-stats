// Renders the MacStats app icon (Sparkline mark on a graphite squircle) into an
// .iconset directory. Run: swift Scripts/make-icon.swift <output-iconset-dir>
// Drawn in code so it needs no design app — fits the SPM + Command-Line-Tools toolchain.
import AppKit
import Foundation

func makeIcon(pixels n: Int) -> Data {
    let px = CGFloat(n)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)

    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    // Squircle background (Apple icon-grid proportions: ~100/1024 inset, ~185/1024 radius).
    let inset = px * (100.0 / 1024.0)
    let side = px - 2 * inset
    let sq = NSRect(x: inset, y: inset, width: side, height: side)
    let radius = px * (185.0 / 1024.0)
    let squircle = NSBezierPath(roundedRect: sq, xRadius: radius, yRadius: radius)

    let topColor = NSColor(srgbRed: 0.27, green: 0.29, blue: 0.33, alpha: 1)   // graphite
    let botColor = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.145, alpha: 1)
    NSGradient(starting: topColor, ending: botColor)!.draw(in: squircle, angle: -90)

    // Sparkline (same 24x24 design space as the menu-bar glyph), centered in the squircle.
    let content = side * 0.64
    let ox = sq.minX + (side - content) / 2
    let oy = sq.minY + (side - content) / 2
    let s = content / 24.0
    // Bitmap context origin is bottom-left, so flip y to match the top-left design coords.
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * s, y: oy + (24 - y) * s) }
    let pts = [P(2, 16), P(6, 11), P(10, 14), P(14, 6), P(18, 10), P(22, 5)]

    let line = NSBezierPath()
    line.lineWidth = 2.6 * s
    line.lineCapStyle = .round
    line.lineJoinStyle = .round
    line.move(to: pts[0])
    for p in pts.dropFirst() { line.line(to: p) }
    NSColor.white.setStroke()
    line.stroke()

    let r = 2.0 * s
    let tip = pts.last!
    let dot = NSBezierPath(ovalIn: NSRect(x: tip.x - r, y: tip.y - r, width: 2 * r, height: 2 * r))
    NSColor.white.setFill()
    dot.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (name, n) in iconset {
    try makeIcon(pixels: n).write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}
print("Wrote \(iconset.count) PNGs to \(outDir)")

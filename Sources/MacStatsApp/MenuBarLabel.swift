import SwiftUI
import AppKit

/// The menu-bar item. A static "sparkline" glyph — no live value, so nothing updates up
/// top. Click it to open the popover, which is where data is actually collected.
///
/// The glyph is drawn as a *template* image (alpha-only), so the menu bar tints it black
/// in light mode / white in dark mode and keeps it crisp on retina — just like an SF
/// Symbol, but our own mark. Drawn in code (no asset catalog) to fit the SPM +
/// Command-Line-Tools-only toolchain.
struct MenuBarLabel: View {
    var body: some View {
        Image(nsImage: Self.sparkline)
    }

    /// Sparkline matching the approved mockup, defined in a 24×24 design space and
    /// rendered into an 18pt template image.
    static let sparkline: NSImage = {
        let design: CGFloat = 24
        let pointSize: CGFloat = 18
        let s = pointSize / design

        // `flipped: true` gives a top-left origin with y growing downward, matching the
        // mockup's SVG coordinates so the points below transcribe directly.
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { _ in
            let points = [
                NSPoint(x: 2,  y: 16),
                NSPoint(x: 6,  y: 11),
                NSPoint(x: 10, y: 14),
                NSPoint(x: 14, y: 6),
                NSPoint(x: 18, y: 10),
                NSPoint(x: 22, y: 5),
            ].map { NSPoint(x: $0.x * s, y: $0.y * s) }

            let line = NSBezierPath()
            line.lineWidth = 2.2 * s
            line.lineCapStyle = .round
            line.lineJoinStyle = .round
            line.move(to: points[0])
            for p in points.dropFirst() { line.line(to: p) }
            NSColor.black.setStroke()
            line.stroke()

            // Filled dot at the leading peak.
            let r = 1.5 * s
            let tip = points.last!
            let dot = NSBezierPath(ovalIn: NSRect(x: tip.x - r, y: tip.y - r, width: 2 * r, height: 2 * r))
            NSColor.black.setFill()
            dot.fill()

            return true
        }
        image.isTemplate = true
        return image
    }()
}

import CoreGraphics

/// The tour overlay's geometry, in the panel's coordinates (origin top-left, y down).
///
/// The cutout (the clear hole in the dim) is the target outset by the same amount on every
/// side, so it is centred on the target by construction; its radius is the target's plus that
/// amount, so card (8), cutout (11) and panel (16) are concentric. Every edge is rounded to the
/// device-pixel grid on its own (not origin + size), so the left and right margins can't differ
/// by more than one device pixel.
public enum TourLayout {
    /// Half the 6 pt gap between cards: the hole never reaches a neighbour.
    public static let cutoutInset: CGFloat = 3
    /// The accent ring, drawn inside the cutout's edge.
    public static let ringWidth: CGFloat = 2
    /// Callout to cutout. The cutout ends halfway across the 6 pt gap between cards, so the
    /// callout starts exactly at the neighbouring card's edge: no sliver of it shows in between.
    public static let calloutGap: CGFloat = 3
    /// How far the callout's far edge may stretch to reach an element's edge (`edges`).
    public static let calloutStretch: CGFloat = 40
    /// Callout and welcome card to the panel edge (the cards' inset).
    public static let panelMargin: CGFloat = 8
    /// Concentric with the panel's 16 pt corners at the 8 pt margin.
    public static let calloutRadius: CGFloat = 8

    public static func cutout(target: CGRect, targetRadius: CGFloat, panel: CGRect, scale: CGFloat,
                              inset: CGFloat = cutoutInset) -> (rect: CGRect, radius: CGFloat) {
        let minX = max(panel.minX, snap(target.minX - inset, scale))
        let minY = max(panel.minY, snap(target.minY - inset, scale))
        let maxX = min(panel.maxX, snap(target.maxX + inset, scale))
        let maxY = min(panel.maxY, snap(target.maxY + inset, scale))
        return (CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY)),
                targetRadius + inset)
    }

    /// The callout: the cards' width and inset, `calloutGap` below the cutout if it fits inside
    /// the panel's margin, else above, else on the side with more room (its height clamped to
    /// that room). Never overlaps the cutout. Its far edge then stretches (by up to
    /// `calloutStretch`) to the nearest of `edges`, the tops and bottoms of the panel's cards, so
    /// it never cuts across a line of a card's text.
    public static func callout(cutout: CGRect, height: CGFloat, panel: CGRect, scale: CGFloat,
                               edges: [CGFloat] = []) -> CGRect {
        let top = panel.minY + panelMargin, bottom = panel.maxY - panelMargin
        let below = cutout.maxY + calloutGap, above = cutout.minY - calloutGap
        var y: CGFloat, h: CGFloat
        if below + height <= bottom {
            (y, h) = (below, height)
        } else if above - height >= top {
            (y, h) = (above - height, height)
        } else if bottom - below >= above - top {
            (y, h) = (below, max(0, bottom - below))
        } else {
            h = max(0, above - top)
            y = above - h
        }
        if y >= cutout.maxY {
            if let edge = edges.filter({ $0 >= y + h && $0 - (y + h) <= calloutStretch && $0 <= bottom }).min() {
                h = edge - y
            }
        } else if let edge = edges.filter({ $0 <= y && y - $0 <= calloutStretch && $0 >= top }).max() {
            h += y - edge
            y = edge
        }
        return snapped(CGRect(x: panel.minX + panelMargin, y: y,
                              width: panel.width - 2 * panelMargin, height: h), scale)
    }

    /// The welcome card: the callout's width, centred on both axes.
    public static func welcome(height: CGFloat, panel: CGRect, scale: CGFloat) -> CGRect {
        snapped(CGRect(x: panel.minX + panelMargin, y: panel.midY - height / 2,
                       width: panel.width - 2 * panelMargin, height: height), scale)
    }

    private static func snap(_ v: CGFloat, _ scale: CGFloat) -> CGFloat {
        let s = max(scale, 1)
        return (v * s).rounded() / s
    }

    private static func snapped(_ r: CGRect, _ scale: CGFloat) -> CGRect {
        let minX = snap(r.minX, scale), minY = snap(r.minY, scale)
        return CGRect(x: minX, y: minY, width: snap(r.maxX, scale) - minX, height: snap(r.maxY, scale) - minY)
    }
}

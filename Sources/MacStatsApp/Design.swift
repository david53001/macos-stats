import SwiftUI

/// Shared geometry for the popover panel and its cards. Corners are concentric: a card's
/// radius is the panel's radius minus the inset between them, as in Apple's own layouts.
/// All rounded shapes use `.continuous` corners (Apple's squircle curve).
enum Design {
    static let panelWidth: CGFloat = 320
    static let panelCornerRadius: CGFloat = 16
    static let panelInset: CGFloat = 8
    static var cardCornerRadius: CGFloat { panelCornerRadius - panelInset }

    /// One fixed height for every screen (overview, breakdown, "Measuring…"), so the
    /// window never resizes while drilling in/out or as data arrives. Sized to fit the
    /// overview's content exactly; the breakdown's list scrolls inside the same height.
    static let panelHeight: CGFloat = 404

    /// Title row at the top of every screen (same height so titles line up across the push).
    static let headerHeight: CGFloat = 30
    /// Gap between neighbouring cards.
    static let cardSpacing: CGFloat = 6
    /// Padding between a card's edge and its content.
    static let cardPadding: CGFloat = 12
    /// Card fill and hairline, as `Color.primary` opacities so they adapt to light/dark
    /// and let the blurred window background show through.
    static let cardFill: Double = 0.05
    static let cardHoverFill: Double = 0.085
    static let cardPressedFill: Double = 0.12
    static let cardHairline: Double = 0.08
}

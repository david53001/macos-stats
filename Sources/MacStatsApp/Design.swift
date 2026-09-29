import SwiftUI

/// Shared geometry for the popover panel and its cards. Corners are concentric: a card's
/// radius is the panel's radius minus the inset between them, as in Apple's own layouts.
/// All rounded shapes use `.continuous` corners (Apple's squircle curve).
enum Design {
    static let panelWidth: CGFloat = 320
    static let panelCornerRadius: CGFloat = 16
    static let panelInset: CGFloat = 8
    static var cardCornerRadius: CGFloat { panelCornerRadius - panelInset }
}

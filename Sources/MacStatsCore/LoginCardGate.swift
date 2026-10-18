import Foundation

/// The screen the panel shows.
public enum PanelScreen: Sendable, Equatable {
    case overview, breakdown, settings
}

/// The app-side rules around `LaunchAtLoginPromptSession`, decided once per panel open and close
/// (`LoginPrompt` in the app passes them on; docs/sparkle-updates/README.md §2):
///
/// - The card is **blocked** (no card in this open; it stays due) unless the panel opened on the
///   overview, where it covers the Memory and Network cards: over Settings or a breakdown, keys
///   like Esc would reach the screen under it. Every close returns the panel to the overview
///   (`AppModel`), so in practice an open only lands elsewhere if that ever regresses.
/// - It is also blocked while the guided tour, its welcome card or its "Take the Tour" chip has
///   the panel (`tourActive`, `offersTour`; read after the tour has decided for this open).
/// - An open the tour took part in (on screen at the open, or started during it) is **not a use**.
///   A chip-only open, or one that lands on another screen, is.
public struct LoginCardGate: Sendable, Equatable {
    /// The tour was on screen at some point in the current open.
    public private(set) var tourSeen = false

    public init() {}

    /// At an open. Returns true when the card must stay off for this open.
    public mutating func opened(on screen: PanelScreen, tourActive: Bool = false,
                                offersTour: Bool = false) -> Bool {
        tourSeen = tourActive
        return screen != .overview || tourActive || offersTour
    }

    /// The tour started during the current open (chip, `?`, Settings → Take the Tour).
    public mutating func tourStarted() {
        tourSeen = true
    }

    /// At a close. Returns whether the open counts as a use.
    public mutating func closed() -> Bool {
        defer { tourSeen = false }
        return !tourSeen
    }
}

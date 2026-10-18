import Foundation

/// When MacStats asks "Open MacStats at login?" (a card over the panel, `LoginPrompt.swift`).
///
/// Rules: count each panel open that stayed on screen for at least `minimumUseSeconds` (a real
/// look, not a click-and-close); once `usesBeforeAsking` uses are recorded, the *next* open shows
/// the question, from its first frame (the open/close cycle: `LaunchAtLoginPromptSession` below).
/// Ask at most once ever, never when launch at login is
/// already on, and never for users of 1.0.x, whose first launch turned it on by itself (that
/// build wrote `didRegisterLoginItem`): they either still have it, or turned it off on purpose.
/// A choice made with the Settings switch also counts as answered.
///
/// All state is in the standard defaults under the `Key` names (docs/sparkle-updates/README.md).
public struct LaunchAtLoginPrompt {
    public enum Key {
        /// Int: panel opens counted so far (stops at `usesBeforeAsking`).
        public static let uses = "launchAtLoginPromptUses"
        /// Bool: the question was shown, or the user chose in Settings. Never asked again.
        public static let asked = "launchAtLoginPromptAsked"
        /// Bool, read only: written by 1.0.x after its silent first-launch enable succeeded.
        public static let legacyAutoEnabled = "didRegisterLoginItem"
        /// Int: times the card was put away (panel closed or dim clicked) before it could be read.
        public static let quickDismissals = "launchAtLoginPromptQuickDismissals"
    }

    public static let usesBeforeAsking = 5
    public static let minimumUseSeconds: TimeInterval = 1
    /// The card put away unread this many times counts as asked: one quick dismissal is likely a
    /// glance, but someone who always clicks it away at once shouldn't get it on every open.
    public static let quickDismissalsBeforeAsked = 3

    /// The decision itself, free of storage.
    public static func shouldAsk(uses: Int, asked: Bool, legacyAutoEnabled: Bool, enabled: Bool) -> Bool {
        uses >= usesBeforeAsking && !asked && !legacyAutoEnabled && !enabled
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var uses: Int { defaults.integer(forKey: Key.uses) }
    public var asked: Bool { defaults.bool(forKey: Key.asked) }
    private var legacyAutoEnabled: Bool { defaults.bool(forKey: Key.legacyAutoEnabled) }

    /// Everything but the launch-at-login status, so callers can skip reading that (an XPC call
    /// to the system) until the question could actually be due.
    public var couldAsk: Bool {
        Self.shouldAsk(uses: uses, asked: asked, legacyAutoEnabled: legacyAutoEnabled, enabled: false)
    }

    public func shouldAsk(enabled: Bool) -> Bool {
        Self.shouldAsk(uses: uses, asked: asked, legacyAutoEnabled: legacyAutoEnabled, enabled: enabled)
    }

    /// Records a panel open that was on screen for `seconds`. Returns whether it counted: too
    /// short a look doesn't, and nothing more is counted once the threshold is reached or the
    /// question can no longer come (asked, or a 1.0.x user).
    @discardableResult
    public func recordUse(seconds: TimeInterval) -> Bool {
        guard seconds >= Self.minimumUseSeconds, !asked, !legacyAutoEnabled,
              uses < Self.usesBeforeAsking else { return false }
        defaults.set(uses + 1, forKey: Key.uses)
        return true
    }

    public func markAsked() {
        defaults.set(true, forKey: Key.asked)
    }

    public var quickDismissals: Int { defaults.integer(forKey: Key.quickDismissals) }

    /// The card was put away before it could be read. Leaves it due, until the
    /// `quickDismissalsBeforeAsked`th time, which counts as asked.
    public func recordQuickDismissal() {
        let count = quickDismissals + 1
        defaults.set(count, forKey: Key.quickDismissals)
        if count >= Self.quickDismissalsBeforeAsked { markAsked() }
    }
}

/// The panel's open/close cycle around `LaunchAtLoginPrompt`: counts uses, decides (while the
/// panel is closed) whether the next open shows the question, and when it counts as asked.
///
/// The question is used up only by an answer, or by being on screen for at least
/// `minimumUseSeconds` (closing the panel or dismissing the card after that). A glance (an
/// accidental click-and-close, or dismissing it at once) leaves it due for the next open, just
/// as a glance at the panel isn't a use, until the `quickDismissalsBeforeAsked`th glance, which
/// counts as asked. Times are passed in, so it is tested without a clock.
public struct LaunchAtLoginPromptSession {
    public let rules: LaunchAtLoginPrompt
    /// The card is part of the current open (panel on screen) or of the next one (closed).
    public private(set) var isShowing: Bool
    private var openedAt: Date?
    /// When the unanswered card came on screen; nil once answered or settled.
    private var cardShownAt: Date?

    /// `isEnabled` reads the system's launch-at-login status (an XPC call); it's only called
    /// once nothing else rules the question out.
    public init(rules: LaunchAtLoginPrompt = LaunchAtLoginPrompt(), isEnabled: () -> Bool) {
        self.rules = rules
        isShowing = rules.couldAsk && !isEnabled()
    }

    public var isPanelOnScreen: Bool { openedAt != nil }

    public mutating func panelShown(at now: Date) {
        guard openedAt == nil else { return }
        openedAt = now
        if isShowing { cardShownAt = now }
    }

    /// Either button. Asked for good; the card stays (showing the result) until dismissed.
    public mutating func answered() {
        rules.markAsked()
        cardShownAt = nil
    }

    /// The card is taken away during an open (a click outside it, Done, or after the result).
    public mutating func dismiss(at now: Date) {
        settleCard(at: now)
        isShowing = false
    }

    public mutating func panelHidden(at now: Date, isEnabled: () -> Bool) {
        guard let start = openedAt else { return }
        openedAt = nil
        settleCard(at: now)
        rules.recordUse(seconds: now.timeIntervalSince(start))
        isShowing = rules.couldAsk && !isEnabled()
    }

    /// An unanswered card that was on screen long enough to be read counts as asked; a quick
    /// dismissal is counted (`LaunchAtLoginPrompt.recordQuickDismissal`).
    private mutating func settleCard(at now: Date) {
        guard let shown = cardShownAt else { return }
        cardShownAt = nil
        if now.timeIntervalSince(shown) >= LaunchAtLoginPrompt.minimumUseSeconds {
            rules.markAsked()
        } else {
            rules.recordQuickDismissal()
        }
    }
}

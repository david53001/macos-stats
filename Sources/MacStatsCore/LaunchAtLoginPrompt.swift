import Foundation

/// When MacStats asks "Open MacStats at login?" (the card at the top of the panel, `LoginPrompt.swift`).
///
/// Rules: count each panel open that stayed on screen for at least `minimumUseSeconds` (a real
/// look, not a click-and-close); once `usesBeforeAsking` uses are recorded, the *next* open shows
/// the question, from its first frame. Ask at most once ever, never when launch at login is
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
    }

    public static let usesBeforeAsking = 5
    public static let minimumUseSeconds: TimeInterval = 1

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
}

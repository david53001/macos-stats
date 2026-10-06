import Foundation

/// The guided tour's pure model: the steps and their copy, the step machine, who sees what,
/// and the only defaults keys the tour writes. No SwiftUI; the app's `TourController` drives it
/// and the overlay only draws its state. Design: `docs/research/2026-10-06-tour-design.md`.

/// One stop of the tour, in order.
public enum TourStepID: String, CaseIterable, Sendable {
    case cpu, memory, network, battery, footer
}

/// One Explain step: which element it highlights (`anchor`) and what its callout says.
public struct TourStep: Equatable, Sendable {
    public let id: TourStepID
    /// The `.tourAnchor` id of the highlighted element, "overview.<id>".
    public let anchor: String
    public let title: String
    public let body: String
    /// Skipped (and not counted in "n of m") on a Mac without a battery.
    public let requiresBattery: Bool

    init(_ id: TourStepID, _ title: String, _ body: String, requiresBattery: Bool = false) {
        self.id = id
        anchor = "overview.\(id.rawValue)"
        self.title = title
        self.body = body
        self.requiresBattery = requiresBattery
    }
}

/// Every user-facing tour string, in one place so the lint test covers them. Copy rules: titles
/// of at most 4 words, bodies of at most 20 words in 1–2 sentences, typographic ’, Title Case
/// buttons, and no live numbers (the values change under the tour).
public enum TourCatalog {
    /// Bump to offer a changed tour again (`TourRules.shouldOfferTour`).
    public static let version = 1

    public static let steps: [TourStep] = [
        TourStep(.cpu, "How hard it’s working",
                 "The number is now, and the graph is the last minute. Click to see which apps use it."),
        TourStep(.memory, "Memory in use",
                 "The dot turns yellow or red when your Mac runs short. Click to see which apps use it."),
        TourStep(.network, "Network activity",
                 "↓ is download and ↑ is upload, right now. The graph shows downloads over the last minute."),
        TourStep(.battery, "Battery and time left",
                 "Charge and a steady estimate of time left. Click for battery health and which apps use power.",
                 requiresBattery: true),
        TourStep(.footer, "Settings and help",
                 "The gear holds Settings. Click ? any time to see this tour again."),
    ]

    public static let welcomeTitle = "Welcome to MacStats"
    public static let welcomeBody =
        "Your Mac’s CPU, memory, network and battery, live in your menu bar, under this icon."
    public static let alertsPermission =
        "MacStats will ask to send alerts when your Mac stays busy or runs low on memory."
    public static let finderPermission =
        "macOS will ask to let MacStats use Finder, so it can show and empty the Trash."
    public static let welcomeQuestion = "Want a quick tour?"
    public static let welcomeSubline = "You can skip it any time."

    public static let noThanks = "No Thanks"
    public static let showMeAround = "Show Me Around"
    public static let skipTour = "Skip Tour"
    public static let back = "Back"
    public static let next = "Next"
    public static let done = "Done"
    public static let takeTheTour = "Take the Tour"
    public static let buttons = [noThanks, showMeAround, skipTour, back, next, done, takeTheTour]

    /// Settings → Help (the button beside it says Take the Tour).
    public static let helpRow = "What each card shows"
}

/// What the app should do after a tour action.
public enum TourEffect: Equatable, Sendable {
    /// Show step `i` (an index into `TourCatalog.steps`).
    case show(Int)
    /// The tour (or the welcome) is over: mark this version seen.
    case finished
    /// The panel closed on step `i`: resume there on the next open.
    case paused(Int)
    case none
}

/// Where the tour is. `interruptions` counts panel closes during this run: the first pauses,
/// the second ends it (clicking elsewhere closes a menu-bar panel, so one is forgiven).
public struct TourState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case off, welcome, step(Int) }

    public private(set) var phase: Phase = .off
    public private(set) var interruptions = 0

    /// A fresh run (0), or a resumed one with the closes it already had.
    public init(interruptions: Int = 0) {
        self.interruptions = interruptions
    }

    public mutating func showWelcome() {
        phase = .welcome
    }

    /// Goes to the first presentable step at or after `index`; `.finished` if there is none.
    public mutating func start(at index: Int = 0, isPresent: (TourStep) -> Bool) -> TourEffect {
        guard let i = Self.presentable(isPresent).first(where: { $0 >= index }) else { return finish() }
        phase = .step(i)
        return .show(i)
    }

    /// The next presentable step, or `.finished` after the last.
    public mutating func next(isPresent: (TourStep) -> Bool) -> TourEffect {
        guard case .step(let current) = phase else { return .none }
        guard let i = Self.presentable(isPresent).first(where: { $0 > current }) else { return finish() }
        phase = .step(i)
        return .show(i)
    }

    /// The previous presentable step; nothing on the first.
    public mutating func back(isPresent: (TourStep) -> Bool) -> TourEffect {
        guard case .step(let current) = phase,
              let i = Self.presentable(isPresent).last(where: { $0 < current }) else { return .none }
        phase = .step(i)
        return .show(i)
    }

    /// Skip Tour or No Thanks.
    public mutating func skip() -> TourEffect {
        phase == .off ? .none : finish()
    }

    /// The panel closed. 1st close: a step pauses there (`.paused`), the welcome asks again
    /// next time (`.none`); 2nd close in the same run: `.finished` (Skip / No Thanks).
    public mutating func panelClosed() -> TourEffect {
        guard phase != .off else { return .none }
        interruptions += 1
        if interruptions >= 2 { return finish() }
        let effect: TourEffect
        if case .step(let i) = phase { effect = .paused(i) } else { effect = .none }
        phase = .off
        return effect
    }

    /// "n of m", counting only the steps that show on this Mac.
    public func progress(isPresent: (TourStep) -> Bool) -> (number: Int, total: Int)? {
        guard case .step(let current) = phase else { return nil }
        let shown = Self.presentable(isPresent)
        guard let n = shown.firstIndex(of: current) else { return nil }
        return (n + 1, shown.count)
    }

    private mutating func finish() -> TourEffect {
        phase = .off
        return .finished
    }

    private static func presentable(_ isPresent: (TourStep) -> Bool) -> [Int] {
        TourCatalog.steps.indices.filter { isPresent(TourCatalog.steps[$0]) }
    }
}

/// New or existing user, decided once at the first launch of a build with the tour.
public enum TourAudience: String, Sendable {
    case new, existing

    /// `existing` if the app's defaults domain holds any key the tour didn't write (an earlier
    /// version ran here), or the bundle id isn't MacStats's (a bare `swift build` binary).
    public static func classify(domainKeys: Set<String>, bundleID: String?) -> TourAudience {
        guard bundleID == "com.macstats.MacStats" else { return .existing }
        return domainKeys.isSubset(of: TourKey.all) ? .new : .existing
    }
}

/// Who sees the welcome, the offer chip and the breakdown hint.
public enum TourRules {
    /// The breakdown's "Right-click an app to quit it" hint shows until a row's menu has been
    /// opened once, on at most this many drill-ins (then the footnote it replaces comes back).
    public static let breakdownHintLimit = 10
    /// The existing-user "Take the Tour" chip shows on this many opens.
    public static let offerLimit = 3

    /// A new user who hasn't answered the welcome (`answered`: in this run, or a paused tour).
    public static func shouldShowWelcome(audience: TourAudience, seenVersion: Int?, answered: Bool) -> Bool {
        audience == .new && seenVersion == nil && !answered
    }

    /// An existing user who hasn't seen this version, dismissed the chip or seen it `offerLimit` times.
    public static func shouldOfferTour(audience: TourAudience, seenVersion: Int?, offerShows: Int,
                                       dismissed: Bool, version: Int = TourCatalog.version) -> Bool {
        audience == .existing && (seenVersion ?? 0) < version && offerShows < offerLimit && !dismissed
    }

    /// New users get the notification and Finder prompts only after the welcome explains them.
    public static func deferPermissionPrompts(audience: TourAudience, seenVersion: Int?,
                                              answered: Bool = false) -> Bool {
        audience == .new && seenVersion == nil && !answered
    }

    public static func showsBreakdownHint(shows: Int, menuUsed: Bool = false) -> Bool {
        !menuUsed && shows < breakdownHintLimit
    }
}

/// The only `UserDefaults` keys the tour writes (so `TourAudience.classify` can ignore them).
public enum TourKey {
    /// "new" | "existing".
    public static let audience = "tourAudience"
    /// Int: set by Done, Skip, No Thanks, or the 2nd close.
    public static let seenVersion = "tourSeenVersion"
    /// Int: the step to resume, while paused by a panel close.
    public static let resumeStep = "tourResumeStep"
    /// Int 0/1: panel closes during this run.
    public static let interruptions = "tourInterruptions"
    /// Int: opens on which the existing-user chip showed.
    public static let offerShows = "tourOfferShows"
    /// Bool: the chip's ✕ was clicked.
    public static let offerDismissed = "tourOfferDismissed"
    /// Int: drill-ins that showed the quit hint.
    public static let breakdownHintShows = "breakdownHintShows"
    /// Bool: a breakdown row's context menu has been opened (the quit hint is no longer needed).
    public static let breakdownMenuUsed = "breakdownMenuUsed"

    public static let all: Set<String> = [audience, seenVersion, resumeStep, interruptions,
                                          offerShows, offerDismissed, breakdownHintShows, breakdownMenuUsed]
}

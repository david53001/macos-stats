import SwiftUI
import MacStatsCore

/// Runs the welcome card, the guided tour, the existing-user "Take the Tour" chip and the
/// breakdown's quit hint, and persists them (`TourKey`; nothing else). The decisions are the pure
/// `TourState` / `TourRules` in MacStatsCore; this only reads and writes defaults around them.
///
/// Separate from `MetricsStore` and observed only by `RootView`, so a tour step re-renders just
/// the overlay and a card's tick never re-runs tour logic. No timers or observers: it acts only on
/// panel open/close and button presses, with a few defaults reads per open.
@MainActor
final class TourController: ObservableObject {
    @Published private(set) var state = TourState()
    /// The existing-user chip in the overview header.
    @Published private(set) var offersTour = false
    /// New user who hasn't answered the welcome: the notification and Finder prompts wait.
    private(set) var defersPermissionPrompts: Bool
    /// Fires once when the intro is over (No Thanks, or the tour's Done / Skip / 2nd close) while
    /// the prompts were deferred. Not at Show Me Around: the Finder prompt is a window of its own,
    /// which would close the panel mid-tour.
    var onIntroFinished: (() -> Void)?

    var isActive: Bool { state.phase != .off }

    private let defaults: UserDefaults
    private let hasBattery: () -> Bool

    /// Tests and probes pass their own suite; never the real MacStats domain.
    init(defaults: UserDefaults = .standard, hasBattery: @escaping () -> Bool) {
        self.defaults = defaults
        self.hasBattery = hasBattery
        defersPermissionPrompts = TourRules.deferPermissionPrompts(
            audience: Self.audience(defaults), seenVersion: defaults.object(forKey: TourKey.seenVersion) as? Int,
            answered: defaults.object(forKey: TourKey.resumeStep) != nil)
    }

    /// Decides new vs existing once, at the first launch of a build with the tour. Must run
    /// before `AppModel()`, which writes its own keys (and so would make everyone "existing").
    static func classifyAudienceIfNeeded(domainKeys: Set<String>, bundleID: String?,
                                         defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: TourKey.audience) == nil else { return }
        defaults.set(TourAudience.classify(domainKeys: domainKeys, bundleID: bundleID).rawValue,
                     forKey: TourKey.audience)
    }

    /// A new user who hasn't answered the welcome yet (at launch: open the panel for them).
    static func welcomePending(defaults: UserDefaults = .standard) -> Bool {
        TourRules.shouldShowWelcome(audience: audience(defaults),
                                    seenVersion: defaults.object(forKey: TourKey.seenVersion) as? Int,
                                    answered: defaults.object(forKey: TourKey.resumeStep) != nil)
    }

    private static func audience(_ defaults: UserDefaults) -> TourAudience {
        defaults.string(forKey: TourKey.audience).flatMap(TourAudience.init(rawValue:)) ?? .existing
    }

    // MARK: Panel lifecycle

    /// The panel opened: resume a paused tour, show the welcome, or offer the chip.
    func panelOpened() {
        guard !isActive else { return }
        let seen = defaults.object(forKey: TourKey.seenVersion) as? Int
        if let resume = defaults.object(forKey: TourKey.resumeStep) as? Int {
            state = TourState(interruptions: defaults.integer(forKey: TourKey.interruptions))
            defaults.removeObject(forKey: TourKey.resumeStep)
            apply(state.start(at: resume, isPresent: isPresent))
            return
        }
        let audience = Self.audience(defaults)
        if TourRules.shouldShowWelcome(audience: audience, seenVersion: seen, answered: !defersPermissionPrompts) {
            state = TourState(interruptions: defaults.integer(forKey: TourKey.interruptions))
            state.showWelcome()
            return
        }
        guard audience == .existing, (seen ?? 0) < TourCatalog.version else { offersTour = false; return }
        let shows = defaults.integer(forKey: TourKey.offerShows)
        offersTour = TourRules.shouldOfferTour(audience: audience, seenVersion: seen, offerShows: shows,
                                               dismissed: defaults.bool(forKey: TourKey.offerDismissed))
        if offersTour { defaults.set(shows + 1, forKey: TourKey.offerShows) }
    }

    /// The panel closed: the first close pauses (or asks again on the welcome), the second ends it.
    func panelClosed() {
        guard isActive else { return }
        let effect = state.panelClosed()
        switch effect {
        case .paused(let i):
            defaults.set(i, forKey: TourKey.resumeStep)
            defaults.set(state.interruptions, forKey: TourKey.interruptions)
        case .finished:
            finish()
        case .none, .show:
            defaults.set(state.interruptions, forKey: TourKey.interruptions)
        }
    }

    // MARK: Buttons

    /// Show Me Around, the chip, `?` or Settings → Take the Tour: a fresh run from step 1.
    func start() {
        offersTour = false
        defaults.removeObject(forKey: TourKey.resumeStep)
        defaults.removeObject(forKey: TourKey.interruptions)
        state = TourState()
        apply(state.start(isPresent: isPresent))
    }

    func next() { apply(state.next(isPresent: isPresent)) }
    func back() { apply(state.back(isPresent: isPresent)) }
    func skip() { apply(state.skip()) }
    /// The welcome's No Thanks.
    func noThanks() { apply(state.skip()) }

    func dismissOffer() {
        offersTour = false
        defaults.set(true, forKey: TourKey.offerDismissed)
    }

    /// A breakdown opened: whether its footnote should show the quit hint (first few times).
    func breakdownOpened() -> Bool {
        let shows = defaults.integer(forKey: TourKey.breakdownHintShows)
        guard TourRules.showsBreakdownHint(shows: shows) else { return false }
        defaults.set(shows + 1, forKey: TourKey.breakdownHintShows)
        return true
    }

    // MARK: Reading the state

    /// The step on screen, if any.
    var currentStep: (step: TourStep, index: Int)? {
        guard case .step(let i) = state.phase else { return nil }
        return (TourCatalog.steps[i], i)
    }

    var progress: (number: Int, total: Int)? { state.progress(isPresent: isPresent) }

    func isPresent(_ step: TourStep) -> Bool {
        !step.requiresBattery || hasBattery()
    }

    // MARK: Private

    private func apply(_ effect: TourEffect) {
        switch effect {
        case .show(let i):
            let step = TourCatalog.steps[i]
            if let p = progress {
                AccessibilityNotification.Announcement("\(step.title). \(step.body) Step \(p.number) of \(p.total).")
                    .post()
            }
        case .finished:
            finish()
        case .paused, .none:
            break
        }
    }

    /// Done, Skip, No Thanks or the 2nd close: this version is seen (which also ends the chip).
    private func finish() {
        defaults.set(TourCatalog.version, forKey: TourKey.seenVersion)
        for key in [TourKey.resumeStep, TourKey.interruptions, TourKey.offerShows] {
            defaults.removeObject(forKey: key)
        }
        offersTour = false
        answerIntro()
    }

    private func answerIntro() {
        guard defersPermissionPrompts else { return }
        defersPermissionPrompts = false
        onIntroFinished?()
    }
}

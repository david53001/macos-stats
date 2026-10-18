import Foundation
import Testing
@testable import MacStatsCore

/// The app-side rules per open (`LoginCardGate`) and how they drive the session: which screen
/// and which tour states may show the card, and which opens count as uses.
@Suite struct LoginCardGateTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 2_000_000)

    private func withDefaults(_ body: (LaunchAtLoginPrompt) -> Void) {
        let suite = "LoginCardGateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(LaunchAtLoginPrompt(defaults: defaults))
    }

    /// What `LoginPrompt` does at an open and a close, with the gate in front of the session.
    private struct Cycle {
        var gate = LoginCardGate()
        var session: LaunchAtLoginPromptSession

        mutating func open(at time: Date, on screen: PanelScreen = .overview,
                           tourActive: Bool = false, offersTour: Bool = false) {
            let blocked = gate.opened(on: screen, tourActive: tourActive, offersTour: offersTour)
            session.panelShown(at: time, blocked: blocked)
        }

        mutating func close(at time: Date) {
            session.panelHidden(at: time, countsAsUse: gate.closed(), isEnabled: { false })
        }
    }

    private func dueCycle(_ rules: LaunchAtLoginPrompt) -> Cycle {
        for _ in 1...LaunchAtLoginPrompt.usesBeforeAsking { rules.recordUse(seconds: 2) }
        let cycle = Cycle(session: LaunchAtLoginPromptSession(rules: rules, isEnabled: { false }))
        #expect(cycle.session.isShowing)
        return cycle
    }

    @Test func onlyTheOverviewWithNoTourShowsTheCard() {
        func blocked(_ screen: PanelScreen, tourActive: Bool = false, offersTour: Bool = false) -> Bool {
            var gate = LoginCardGate()
            return gate.opened(on: screen, tourActive: tourActive, offersTour: offersTour)
        }
        #expect(!blocked(.overview))
        #expect(blocked(.settings))
        #expect(blocked(.breakdown))
        #expect(blocked(.overview, tourActive: true))
        #expect(blocked(.overview, offersTour: true))
    }

    /// Round-3 review M1: an open that lands on Settings (or a breakdown) must not put the card
    /// over it, where Esc would go back under the card. It stays due for an overview open.
    @Test func anOpenOnSettingsKeepsTheCardDueForTheOverview() {
        for screen in [PanelScreen.settings, .breakdown] {
            withDefaults { rules in
                var cycle = dueCycle(rules)
                cycle.open(at: t0, on: screen)
                #expect(!cycle.session.isShowing)
                cycle.close(at: t0 + 10)
                #expect(!rules.asked)
                #expect(rules.quickDismissals == 0)
                #expect(cycle.session.isShowing)
                cycle.open(at: t0 + 20)
                #expect(cycle.session.isShowing)
            }
        }
    }

    @Test func chipOpenIsBlockedButIsAUse() {
        withDefaults { rules in
            var cycle = Cycle(session: LaunchAtLoginPromptSession(rules: rules, isEnabled: { false }))
            cycle.open(at: t0, offersTour: true)
            #expect(!cycle.session.isShowing)
            cycle.close(at: t0 + 2)
            #expect(rules.uses == 1)
        }
    }

    @Test func anOpenTheTourWasOnScreenForIsNotAUse() {
        withDefaults { rules in
            var cycle = Cycle(session: LaunchAtLoginPromptSession(rules: rules, isEnabled: { false }))
            cycle.open(at: t0, tourActive: true)     // welcome card or a resumed step
            cycle.close(at: t0 + 30)
            #expect(rules.uses == 0)
        }
    }

    @Test func aTourStartedDuringTheOpenMakesItNotAUse() {
        withDefaults { rules in
            var cycle = Cycle(session: LaunchAtLoginPromptSession(rules: rules, isEnabled: { false }))
            cycle.open(at: t0, offersTour: true)     // chip, then the user starts the tour
            cycle.gate.tourStarted()
            cycle.close(at: t0 + 30)
            #expect(rules.uses == 0)
            cycle.open(at: t0 + 40)                  // the flag doesn't leak into the next open
            cycle.close(at: t0 + 42)
            #expect(rules.uses == 1)
        }
    }

    @Test func aDueCardWaitsThroughTourOpensThenShows() {
        withDefaults { rules in
            var cycle = dueCycle(rules)
            cycle.open(at: t0, tourActive: true)
            #expect(!cycle.session.isShowing)
            cycle.close(at: t0 + 30)
            cycle.open(at: t0 + 40, offersTour: true)
            #expect(!cycle.session.isShowing)
            cycle.close(at: t0 + 45)
            #expect(!rules.asked)
            cycle.open(at: t0 + 50)
            #expect(cycle.session.isShowing)
            cycle.close(at: t0 + 52)                 // on screen ≥ 1 s: asked
            #expect(rules.asked)
            #expect(!cycle.session.isShowing)
        }
    }
}

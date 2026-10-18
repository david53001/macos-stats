import Foundation
import Testing
@testable import MacStatsCore

/// The "Open MacStats at login?" decision: threshold, already on, already asked, 1.0.x users.
@Suite struct LaunchAtLoginPromptTests {
    /// A fresh, private defaults domain per test (removed again at the end).
    private func withDefaults(_ body: (UserDefaults, LaunchAtLoginPrompt) -> Void) {
        let suite = "LaunchAtLoginPromptTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults, LaunchAtLoginPrompt(defaults: defaults))
    }

    @Test func asksOnlyFromTheFifthUse() {
        withDefaults { _, prompt in
            for use in 1...4 {
                #expect(prompt.recordUse(seconds: 3))
                #expect(prompt.uses == use)
                #expect(!prompt.shouldAsk(enabled: false))
            }
            #expect(prompt.recordUse(seconds: 3))
            #expect(prompt.uses == 5)
            #expect(prompt.couldAsk)
            #expect(prompt.shouldAsk(enabled: false))
        }
    }

    @Test func aGlanceIsNotAUse() {
        withDefaults { _, prompt in
            #expect(!prompt.recordUse(seconds: 0.4))
            #expect(prompt.uses == 0)
            #expect(prompt.recordUse(seconds: LaunchAtLoginPrompt.minimumUseSeconds))
            #expect(prompt.uses == 1)
        }
    }

    @Test func countingStopsAtTheThreshold() {
        withDefaults { _, prompt in
            for _ in 1...5 { prompt.recordUse(seconds: 2) }
            #expect(!prompt.recordUse(seconds: 2))
            #expect(prompt.uses == 5)
        }
    }

    @Test func neverAsksWhenAlreadyEnabled() {
        withDefaults { _, prompt in
            for _ in 1...5 { prompt.recordUse(seconds: 2) }
            #expect(!prompt.shouldAsk(enabled: true))
            #expect(!LaunchAtLoginPrompt.shouldAsk(uses: 9, asked: false, legacyAutoEnabled: false, enabled: true))
        }
    }

    @Test func asksAtMostOnce() {
        withDefaults { defaults, prompt in
            for _ in 1...5 { prompt.recordUse(seconds: 2) }
            #expect(prompt.shouldAsk(enabled: false))
            prompt.markAsked()
            #expect(defaults.bool(forKey: LaunchAtLoginPrompt.Key.asked))
            #expect(!prompt.shouldAsk(enabled: false))
            #expect(!prompt.couldAsk)
            #expect(!prompt.recordUse(seconds: 2))   // nothing more to count
        }
    }

    @Test func choosingInSettingsFirstMeansNoQuestion() {
        withDefaults { _, prompt in
            prompt.markAsked()   // what the Settings switch does
            for _ in 1...5 { prompt.recordUse(seconds: 2) }
            #expect(prompt.uses == 0)
            #expect(!prompt.shouldAsk(enabled: false))
        }
    }

    /// 1.0.x turned launch at login on by itself and set `didRegisterLoginItem`. Such a user is
    /// either still enabled (nothing to ask) or turned it off on purpose (respect that).
    @Test func legacyAutoEnabledUsersAreNeverAsked() {
        withDefaults { defaults, prompt in
            defaults.set(true, forKey: LaunchAtLoginPrompt.Key.legacyAutoEnabled)
            #expect(!prompt.recordUse(seconds: 2))
            defaults.set(7, forKey: LaunchAtLoginPrompt.Key.uses)
            #expect(!prompt.shouldAsk(enabled: false))
            #expect(!prompt.shouldAsk(enabled: true))
            #expect(!prompt.couldAsk)
        }
    }

    @Test func pureDecisionTable() {
        let n = LaunchAtLoginPrompt.usesBeforeAsking
        #expect(LaunchAtLoginPrompt.shouldAsk(uses: n, asked: false, legacyAutoEnabled: false, enabled: false))
        #expect(!LaunchAtLoginPrompt.shouldAsk(uses: n - 1, asked: false, legacyAutoEnabled: false, enabled: false))
        #expect(!LaunchAtLoginPrompt.shouldAsk(uses: n, asked: true, legacyAutoEnabled: false, enabled: false))
        #expect(!LaunchAtLoginPrompt.shouldAsk(uses: n, asked: false, legacyAutoEnabled: true, enabled: false))
        #expect(!LaunchAtLoginPrompt.shouldAsk(uses: n, asked: false, legacyAutoEnabled: false, enabled: true))
    }

    @Test func keysAreStable() {
        // Persisted in users' defaults: renaming one would re-ask or lose the count.
        #expect(LaunchAtLoginPrompt.Key.uses == "launchAtLoginPromptUses")
        #expect(LaunchAtLoginPrompt.Key.asked == "launchAtLoginPromptAsked")
        #expect(LaunchAtLoginPrompt.Key.legacyAutoEnabled == "didRegisterLoginItem")
    }
}

/// The open/close cycle around the rules (`LaunchAtLoginPromptSession`): when the card shows,
/// and what uses it up. A glance at it must not.
@Suite struct LaunchAtLoginPromptSessionTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func withDefaults(_ body: (UserDefaults, LaunchAtLoginPrompt) -> Void) {
        let suite = "LaunchAtLoginPromptSessionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults, LaunchAtLoginPrompt(defaults: defaults))
    }

    /// One open of `seconds`, starting `start` seconds after t0.
    private func open(_ session: inout LaunchAtLoginPromptSession, at start: TimeInterval,
                      for seconds: TimeInterval, enabled: Bool = false) {
        session.panelShown(at: t0 + start)
        session.panelHidden(at: t0 + start + seconds, isEnabled: { enabled })
    }

    /// A session whose next open shows the card (5 uses already counted).
    private func dueSession(_ rules: LaunchAtLoginPrompt) -> LaunchAtLoginPromptSession {
        for _ in 1...LaunchAtLoginPrompt.usesBeforeAsking { rules.recordUse(seconds: 2) }
        let session = LaunchAtLoginPromptSession(rules: rules, isEnabled: { false })
        #expect(session.isShowing)
        return session
    }

    @Test func fiveRealOpensThenTheNextOneShowsTheCard() {
        withDefaults { _, rules in
            var session = LaunchAtLoginPromptSession(rules: rules, isEnabled: { false })
            for i in 0..<4 {
                open(&session, at: Double(i) * 10, for: 2)
                #expect(!session.isShowing)
            }
            open(&session, at: 40, for: 0.3)   // a glance: not counted
            #expect(rules.uses == 4)
            #expect(!session.isShowing)
            open(&session, at: 50, for: 1)     // the 5th use: decided while closed
            #expect(rules.uses == 5)
            #expect(session.isShowing)
            #expect(!rules.asked)
        }
    }

    @Test func aGlanceAtTheCardLeavesItDue() {
        withDefaults { _, rules in
            var session = dueSession(rules)
            open(&session, at: 0, for: 0.2)
            #expect(!rules.asked)
            #expect(session.isShowing)   // shown again on the next open
        }
    }

    @Test func aRealLookAtTheCardUsesItUp() {
        withDefaults { _, rules in
            var session = dueSession(rules)
            open(&session, at: 0, for: LaunchAtLoginPrompt.minimumUseSeconds)
            #expect(rules.asked)
            #expect(!session.isShowing)
            open(&session, at: 10, for: 5)
            #expect(!session.isShowing)   // never again
        }
    }

    @Test func anAnswerUsesItUpAtOnce() {
        withDefaults { _, rules in
            var session = dueSession(rules)
            session.panelShown(at: t0)
            session.answered()
            #expect(rules.asked)
            #expect(session.isShowing)    // still up, showing the result
            session.dismiss(at: t0 + 0.4)
            #expect(!session.isShowing)
            session.panelHidden(at: t0 + 0.5, isEnabled: { false })
            #expect(!session.isShowing)
        }
    }

    @Test func dismissingAtOnceLeavesItDueButHidesItNow() {
        withDefaults { _, rules in
            var session = dueSession(rules)
            session.panelShown(at: t0)
            session.dismiss(at: t0 + 0.3)
            #expect(!session.isShowing)   // gone for the rest of this open
            #expect(!rules.asked)
            session.panelHidden(at: t0 + 5, isEnabled: { false })
            #expect(!rules.asked)         // the card itself was up 0.3 s
            #expect(session.isShowing)
        }
    }

    @Test func dismissingAfterReadingUsesItUp() {
        withDefaults { _, rules in
            var session = dueSession(rules)
            session.panelShown(at: t0)
            session.dismiss(at: t0 + 1.5)
            #expect(rules.asked)
            session.panelHidden(at: t0 + 3, isEnabled: { false })
            #expect(!session.isShowing)
        }
    }

    @Test func turnedOnElsewhereMeansNoCard() {
        withDefaults { _, rules in
            for _ in 1...4 { rules.recordUse(seconds: 2) }
            var session = LaunchAtLoginPromptSession(rules: rules, isEnabled: { false })
            open(&session, at: 0, for: 2, enabled: true)
            #expect(rules.uses == 5)
            #expect(!session.isShowing)
        }
    }

    @Test func repeatedOnScreenEventsDontRestartTheOpen() {
        withDefaults { _, rules in
            var session = LaunchAtLoginPromptSession(rules: rules, isEnabled: { false })
            session.panelShown(at: t0)
            session.panelShown(at: t0 + 1.8)          // occlusion fires more than once
            session.panelHidden(at: t0 + 2, isEnabled: { false })
            #expect(rules.uses == 1)                  // 2 s, not 0.2 s
            session.panelHidden(at: t0 + 3, isEnabled: { false })   // no open: ignored
            #expect(rules.uses == 1)
            #expect(!session.isPanelOnScreen)
        }
    }

    /// The status read is an XPC call: skipped until the rules alone say the question could come.
    @Test func readsTheSystemStatusOnlyWhenTheQuestionCouldCome() {
        withDefaults { _, rules in
            var reads = 0
            var session = LaunchAtLoginPromptSession(rules: rules, isEnabled: { reads += 1; return false })
            for i in 0..<4 {
                session.panelShown(at: t0 + Double(i) * 10)
                session.panelHidden(at: t0 + Double(i) * 10 + 2, isEnabled: { reads += 1; return false })
            }
            #expect(reads == 0)
            session.panelShown(at: t0 + 50)
            session.panelHidden(at: t0 + 52, isEnabled: { reads += 1; return false })
            #expect(reads == 1)
            #expect(session.isShowing)
        }
    }
}

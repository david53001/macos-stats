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

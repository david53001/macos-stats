#if PROBE
import AppKit
import ServiceManagement
import MacStatsCore

/// The integration branch's scenarios (README.md): `ProbeScenarios-screens.swift`'s M1 and Return
/// parts, after the guided-tour part (chip, tour, welcome: the card waits for an open of its own).
@MainActor
enum ProbeScenarios {
    static var m: AppModel { Probe.model }
    static var d: UserDefaults { .standard }

    static func install() {
        Probe.hooks["tour"] = { m.tour.isActive ? "Y" : "n" }
        Probe.hooks["chip"] = { m.tour.offersTour ? "Y" : "n" }
        if Probe.env["PROBE_SCENARIO"] != "welcome" {
            d.set(TourCatalog.version, forKey: TourKey.seenVersion)   // basic part: no tour, no chip
        }
    }

    static func extra(_ scenario: String) async {
        if scenario == "welcome" { return }
        await tourPart(scenario)
        d.set(TourCatalog.version, forKey: TourKey.seenVersion)       // no chip from here on
        d.set(true, forKey: TourKey.offerDismissed)
        await screens()
        await gatedEsc()
        await returnKey()
    }

    /// The second guard of M1: should the card ever be up over Settings again (forced here by
    /// switching screens under it), Esc must still mean No Thanks, not Settings' back button.
    static func gatedEsc() async {
        Probe.note("M1 guard: card up, Settings forced under it, Esc")
        Probe.toggle(); await Probe.wait(1.0); Probe.state("openG0")
        Probe.resetAsked()
        Probe.toggle(); await Probe.wait(0.8); Probe.state("closedG0")
        Probe.toggle(); await Probe.wait(1.2); Probe.state("openG1")
        m.showingSettings = true; await Probe.wait(0.6); Probe.state("G1-settings-under-card"); Probe.snap("G1-settings-under-card")
        Probe.escape(); await Probe.wait(0.6); Probe.state("G1-after-esc")   // card answered, still on Settings
        Probe.toggle(); await Probe.wait(0.8); Probe.state("closedG1")
    }

    static func tourPart(_ scenario: String) async {
        if scenario == "welcome" { return }
        Probe.note("tour part: uses=3, chip offered")
        d.set(3, forKey: "launchAtLoginPromptUses")
        Probe.resetAsked()
        for k in [TourKey.seenVersion, TourKey.offerShows, TourKey.offerDismissed, TourKey.resumeStep, TourKey.interruptions] {
            d.removeObject(forKey: k)
        }
        await Probe.openClose("T1-chip", hold: 1.5, snapName: "T1-chip")            // chip: blocked, but a use (4)
        Probe.toggle(); await Probe.wait(0.6)
        m.tour.start(); await Probe.wait(1.2)
        Probe.state("openT2-tour"); Probe.snap("T2-tour")
        Probe.toggle(); await Probe.wait(0.7); Probe.state("closedT2")              // tour paused; not a use
        Probe.toggle(); await Probe.wait(1.2); Probe.state("openT3-resumed")
        m.tour.skip(); await Probe.wait(0.6); Probe.state("T3-after-skip")          // no card mid-open
        Probe.toggle(); await Probe.wait(0.7); Probe.state("closedT3")              // still 4
        await Probe.openClose("T4", hold: 1.5)                                      // 5th use -> due
        Probe.toggle(); await Probe.wait(0.35); Probe.state("openT5"); Probe.snap("T5-card")
        Probe.click(160, 70); await Probe.wait(0.3); Probe.state("T5-after-dim")
        Probe.toggle(); await Probe.wait(0.7); Probe.state("closedT5")
        Probe.toggle(); await Probe.wait(1.5); Probe.state("openT6"); Probe.snap("T6-card")
        Probe.toggle(); await Probe.wait(0.7); Probe.state("closedT6")              // a look: asked
        // Settings with all four cards (General, Updates, Appearance, Help)
        Probe.toggle(); await Probe.wait(1.0)
        Probe.click(300, 388); await Probe.wait(0.8); Probe.snap("T7-settings"); Probe.state("openT7-settings")
        Probe.toggle(); await Probe.wait(0.7); Probe.state("closedT7")
    }

    /// Seeded as a new user (tourAudience=new) with 5 uses: welcome first, card only after it.
    static func welcome() async {
        Probe.state("launch")
        await Probe.openClose("W1-welcome", hold: 1.5, snapName: "W1-welcome")
        Probe.toggle(); await Probe.wait(1.2); Probe.state("openW2-welcome")
        m.tour.skip(); await Probe.wait(0.6); Probe.state("W2-after-nothanks")
        Probe.toggle(); await Probe.wait(0.7); Probe.state("closedW2")
        await Probe.openClose("W3", hold: 1.5)
        Probe.toggle(); await Probe.wait(1.2); Probe.state("openW4"); Probe.snap("W4-card")
        Probe.toggle(); await Probe.wait(0.7); Probe.state("closedW4")
        Probe.toggle(); await Probe.wait(1.0)
        Probe.click(300, 388); await Probe.wait(0.8); Probe.snap("W5-settings"); Probe.state("openW5-settings")
        Probe.toggle(); await Probe.wait(0.7); Probe.state("closedW5")
    }

    /// Opens (no card), goes to `screen` with `navigate`, makes the card due and closes there.
    /// Then: the reopen must be on the overview with the card, and Esc must mean No Thanks.
    static func closeOn(_ tag: String, navigate: () -> Void) async {
        d.set(true, forKey: "launchAtLoginPromptAsked")      // no card while navigating
        Probe.toggle(); await Probe.wait(1.0); Probe.state("open\(tag)1")
        navigate(); await Probe.wait(0.8); Probe.state("\(tag)1-navigated"); Probe.snap("\(tag)1-navigated")
        Probe.resetAsked()                                   // due again from this close
        Probe.toggle(); await Probe.wait(0.8); Probe.state("closed\(tag)1")
        Probe.toggle(); await Probe.wait(1.3); Probe.state("open\(tag)2"); Probe.snap("\(tag)2-reopened")
        Probe.escape(); await Probe.wait(0.6); Probe.state("\(tag)2-after-esc"); Probe.snap("\(tag)2-after-esc")
        Probe.toggle(); await Probe.wait(0.8); Probe.state("closed\(tag)2")
    }

    static func screens() async {
        Probe.note("M1: close from Settings, reopen with the card due, Esc")
        await closeOn("S") { Probe.click(300, 388) }         // the footer gear
        Probe.note("M1: close from the CPU breakdown, reopen with the card due, Esc")
        await closeOn("B") { Probe.click(160, 70) }          // the CPU card
    }

    /// One answered card: due, open, read (1.2 s), Return, look at the result, `then`.
    static func answer(_ tag: String, result: SMAppService.Status, then: () async -> Void) async {
        Probe.loginResult = result
        Probe.toggle(); await Probe.wait(1.2); Probe.state("open\(tag)")
        Probe.returnKey(); await Probe.wait(0.4); Probe.state("\(tag)-after-return"); Probe.snap("\(tag)-result")
        await then()
        // Due again for the next one: not asked, launch at login off (the stub), decided at the close.
        Probe.resetAsked()
        LaunchAtLogin.shared.setEnabled(false)
        Probe.resetAsked()
        Probe.toggle(); await Probe.wait(0.8); Probe.state("closed\(tag)")
    }

    static func returnKey() async {
        Probe.note("Return on the card (login-item service stubbed)")
        // From the screens part the card is asked; make it due for the first one.
        Probe.toggle(); await Probe.wait(1.0); Probe.state("openR0")
        Probe.resetAsked()
        Probe.toggle(); await Probe.wait(0.8); Probe.state("closedR0")
        await answer("R1", result: .enabled) {
            await Probe.wait(1.8); Probe.state("R1-later")   // the 1.6 s confirmation went by itself
        }
        await answer("R2", result: .requiresApproval) {
            Probe.returnKey(); await Probe.wait(0.6); Probe.state("R2-after-open-login-items")
        }
        await answer("R3", result: .notFound) {
            Probe.returnKey(); await Probe.wait(0.6); Probe.state("R3-after-done")
        }
    }
}

#endif

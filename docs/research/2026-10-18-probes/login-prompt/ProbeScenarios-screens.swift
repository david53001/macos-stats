#if PROBE
import AppKit
import ServiceManagement
import MacStatsCore

/// Scenarios after `Probe.run`'s basic part (README.md): the round-3 review's M1 case (close from
/// Settings or a breakdown, reopen with the card due, Esc) and Return on every card state, with
/// the login-item service stubbed (`Probe.loginResult`). Works on `feat/sparkle-updates` and, with
/// `ProbeScenarios-tour.swift`'s `install`, on the integration branch.
@MainActor
enum ProbeScenarios {
    static var m: AppModel { Probe.model }
    static var d: UserDefaults { .standard }

    static func install() {}
    static func welcome() async {}

    static func extra(_ scenario: String) async {
        await screens()
        await returnKey()
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

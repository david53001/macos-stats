#if PROBE
import AppKit
import ServiceManagement
import SwiftUI
import MacStatsCore

/// Live probe harness for the login card (docs/research/2026-10-18-probes/login-prompt/README.md).
/// Compiled only into the scratch copy `probe.sh` builds (`-DPROBE`), never into the app: drives the
/// real MenuBarExtra panel through its own status button, synthesizes clicks/keys into the panel
/// window, logs state + frame, snapshots (`cacheDisplay`, no Screen Recording permission needed).
@MainActor
enum Probe {
    static var model: AppModel!
    /// What the stubbed `LaunchAtLogin.setEnabled(true)` reports (probe.sh patches the scratch
    /// copy so the real `SMAppService` is never called): `.enabled`, `.requiresApproval`, or
    /// anything else for the error card.
    static var loginResult: SMAppService.Status = .enabled
    static let env = ProcessInfo.processInfo.environment
    static var out: String { env["PROBE_OUT"] ?? "/tmp" }
    static var log = ""
    static var hooks: [String: () -> String] = [:]

    static func start(model: AppModel) {
        self.model = model
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if env["PROBE_APPEARANCE"] == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
            if env["PROBE_APPEARANCE"] == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
            try? await Task.sleep(for: .seconds(0.5))
            await run(env["PROBE_SCENARIO"] ?? "basic")
            try? log.write(toFile: out + "/probe-\(env["PROBE_APPEARANCE"] ?? "x").log", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    // MARK: helpers

    static func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    static func statusButton() -> NSStatusBarButton? {
        func find(_ v: NSView) -> NSStatusBarButton? {
            if let b = v as? NSStatusBarButton { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        return NSApp.windows.lazy.compactMap { $0.contentView.flatMap(find) }.first
    }

    static func panel() -> NSWindow? {
        NSApp.windows.first { String(describing: type(of: $0)).contains("MenuBarExtra") }
    }

    /// Opens if closed, closes if open; waits (up to 3 s) until the window agrees.
    static func toggle() {
        let want = !(panel()?.isVisible ?? false)
        statusButton()?.performClick(nil)
        let until = Date().addingTimeInterval(3)
        while (panel()?.isVisible ?? false) != want, Date() < until {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if (panel()?.isVisible ?? false) != want { note("toggle: panel did not become \(want ? "visible" : "hidden")") }
        nudgeIfLocked()
    }

    /// With the screen locked (a probe run while the owner is away) macOS posts no occlusion change
    /// when the panel is shown or hidden, so the app's window observers would never hear of it. Post
    /// the notification macOS posts when unlocked, so the app's own observer code runs; whether
    /// macOS posts it on an unlocked screen is checked by an unlocked run.
    static func nudgeIfLocked() {
        guard let w = panel(),
              let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session["CGSSessionScreenIsLocked"] as? Bool == true else { return }
        if !notedLock { note("screen locked: posting the panel's occlusion notification after each toggle"); notedLock = true }
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: w)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    private static var notedLock = false

    static func d() -> UserDefaults { .standard }

    static func state(_ tag: String) {
        let p = panel()
        let f = p.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "nil"
        var line = String(format: "%@ | uses=%d asked=%@ quick=%d showing=%@ visible=%@ key=%@ frame=%@ breakdown=%@",
                          tag as NSString,
                          d().integer(forKey: "launchAtLoginPromptUses"),
                          d().bool(forKey: "launchAtLoginPromptAsked") ? "Y" : "n",
                          d().integer(forKey: "launchAtLoginPromptQuickDismissals"),
                          model.loginPrompt.isShowing ? "Y" : "n",
                          (p?.isVisible ?? false) ? "Y" : "n",
                          (p?.isKeyWindow ?? false) ? "Y" : "n",
                          f,
                          model.store.activeBreakdownMetric.map { "\($0)" } ?? "nil")
        line += " screen=\(model.panelScreen) answer=\(model.loginPrompt.answer == .accepted ? "accepted" : "none")"
        line += " login=\(LaunchAtLogin.shared.status.rawValue)"   // 0 off, 1 on, 2 needs approval, 3 not found
        for (k, h) in hooks.sorted(by: { $0.key < $1.key }) { line += " \(k)=\(h())" }
        log += line + "\n"
    }

    static func note(_ s: String) { log += "  # " + s + "\n" }

    static func snap(_ name: String) {
        guard let v = panel()?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: out + "/\(env["PROBE_APPEARANCE"] ?? "x")-\(name).png"))
    }

    /// x, y in points from the panel's top-left.
    static func click(_ x: CGFloat, _ y: CGFloat) {
        guard let w = panel(), let v = w.contentView else { return }
        let loc = NSPoint(x: x, y: v.bounds.height - y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0,
                                          clickCount: 1, pressure: 1) {
                w.sendEvent(e)
            }
        }
    }

    static func key(_ code: UInt16, _ chars: String) {
        guard let w = panel() else { return }
        if !w.isKeyWindow { w.makeKey() }   // the status-button click usually made it key already
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                w.sendEvent(e)
            }
        }
    }

    static func escape() { key(53, "\u{1b}") }
    static func returnKey() { key(36, "\r") }

    static func resetAsked() {
        d().set(false, forKey: "launchAtLoginPromptAsked")
        d().set(0, forKey: "launchAtLoginPromptQuickDismissals")
    }

    /// One open held for `hold` seconds, then closed.
    static func openClose(_ tag: String, hold: Double, snapName: String? = nil) async {
        toggle(); await wait(hold)
        state("open" + tag)
        if let snapName { snap(snapName) }
        toggle(); await wait(0.7)
        state("closed" + tag)
    }

    // MARK: scenarios

    static func run(_ scenario: String) async {
        ProbeScenarios.install()
        note("scenario \(scenario)")
        if scenario == "welcome" { await ProbeScenarios.welcome(); return }
        state("launch")
        // 1: the 5th real use; card decided while closed
        await openClose("1", hold: 1.5, snapName: "1-before")
        // 2: dim click over the CPU card at ~0.5 s (quick dismissal 1)
        toggle(); await wait(0.35)
        state("open2"); snap("2-card")
        click(160, 70); await wait(0.3)
        state("after-dim-click")
        toggle(); await wait(0.7); state("closed2")
        // 3: a 0.3 s glance (quick dismissal 2)
        await openClose("3", hold: 0.3)
        // 4: another glance: the 3rd quick dismissal counts as asked
        await openClose("4", hold: 0.3)
        // 5: control click with no card: the same click opens the CPU breakdown; then reset
        toggle(); await wait(1.2)
        state("open5")
        click(160, 70); await wait(0.5)
        state("after-ctl-click")
        resetAsked()
        toggle(); await wait(0.7); state("closed5")
        // 6: settled card, then Esc = No Thanks (panel stays open)
        toggle(); await wait(1.5)
        state("open6"); snap("6-card")
        key(53, "\u{1b}"); await wait(0.5)
        state("after-esc"); snap("6-after-esc")
        toggle(); await wait(0.7); state("closed6")
        // 7: reset again; 8: a 1.6 s look uses it up
        toggle(); await wait(1.2); state("open7"); resetAsked()
        toggle(); await wait(0.7); state("closed7")
        await openClose("8", hold: 1.6)
        await openClose("9", hold: 1.2)
        await ProbeScenarios.extra(scenario)
    }
}
#endif

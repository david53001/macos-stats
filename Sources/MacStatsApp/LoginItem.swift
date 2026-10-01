import Foundation
import ServiceManagement

/// Launch at login. The first launch registers the app via `SMAppService` — exactly once: a
/// UserDefaults flag records that we've done so, so if the user later turns it off (in our
/// Settings screen or in System Settings → General → Login Items), we never re-add it.
/// After that, the Settings toggle reads and changes `SMAppService.mainApp.status` directly;
/// the system's status is the only source of truth (no mirrored flag).
///
/// Only effective for the bundled, signed `MacStats.app` (the API keys off the app bundle and
/// its code signature); the bare `swift build` binary can't register and fails harmlessly.
enum LoginItem {
    private static let didRegisterKey = "didRegisterLoginItem"

    /// Register at login on first launch only. Safe to call on every launch.
    static func registerOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didRegisterKey) else { return }
        do {
            try SMAppService.mainApp.register()
            defaults.set(true, forKey: didRegisterKey)   // only record success, so an unbundled run can retry
        } catch {
            // A login-item failure must never crash or interrupt launch (e.g. the unbundled binary).
            NSLog("MacStats: launch-at-login registration failed: \(error.localizedDescription)")
        }
    }

    /// The system's current record for MacStats (`.enabled`, `.notRegistered`, `.requiresApproval`, …).
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// Turn launch at login on or off from Settings, then return the real status (so a failed
    /// call leaves the toggle showing what the system actually has). Any explicit choice also
    /// marks the one-time auto-enable as done, so `registerOnce()` never overrides the user.
    static func setEnabled(_ enabled: Bool) -> SMAppService.Status {
        UserDefaults.standard.set(true, forKey: didRegisterKey)
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("MacStats: launch-at-login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        return status
    }
}

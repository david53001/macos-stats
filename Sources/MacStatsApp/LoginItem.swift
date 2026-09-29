import Foundation
import ServiceManagement

/// Enrolls MacStats to launch at login — exactly once. The first launch registers the app
/// via `SMAppService`; a UserDefaults flag records that we've done so, so if the user later
/// removes MacStats from System Settings → General → Login Items, we never re-add it.
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
}

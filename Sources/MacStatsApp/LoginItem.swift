import Foundation
import ServiceManagement
import MacStatsCore

/// Launch at login, via `SMAppService.mainApp`. MacStats never turns it on by itself: the user
/// does, with the Settings switch or by answering the one-time "Open MacStats at login?" card
/// (`LoginPrompt.swift`, rules in `MacStatsCore/LaunchAtLoginPrompt.swift`). Up to 1.0.x the
/// first launch registered silently (flag `didRegisterLoginItem`); that is gone, and the flag is
/// now only read, to keep from asking those users.
///
/// The system's status is the only source of truth (no mirrored flag); both the switch and the
/// card observe this one object, so they always agree.
///
/// Only effective for the bundled, signed `MacStats.app` (the API keys off the app bundle and
/// its code signature); the bare `swift build` binary can't register and fails harmlessly.
@MainActor
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    /// The system's current record for MacStats (`.enabled`, `.notRegistered`, `.requiresApproval`, …).
    @Published private(set) var status: SMAppService.Status = SMAppService.mainApp.status

    private init() {}

    /// Re-reads the status (the user may have changed it in System Settings → Login Items).
    func refresh() {
        let current = SMAppService.mainApp.status
        if current != status { status = current }
    }

    /// Turns launch at login on or off, then publishes the real status, so a failed call leaves
    /// the switch showing what the system actually has. Any explicit choice also counts as the
    /// answer to the one-time question, so the card never asks someone who already chose.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> SMAppService.Status {
        LaunchAtLoginPrompt().markAsked()
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Never fatal (e.g. the unbundled binary); the status read below shows the outcome.
            NSLog("MacStats: launch-at-login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        refresh()
        return status
    }

    /// System Settings → General → Login Items, where macOS asks for approval when needed.
    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

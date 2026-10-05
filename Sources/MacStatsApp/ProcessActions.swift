import AppKit
import Darwin
import MacStatsCore

/// Quit actions for an app, addressed by its GUI app pid (the breakdown's group key), and for
/// a single process inside an expanded app row.
/// `terminate()` is a graceful request — the app runs its normal quit, including any
/// unsaved-work prompt (like ⌘Q). `forceTerminate()` kills it immediately.
enum ProcessActions {
    static func quit(appPID: Int32) {
        NSRunningApplication(processIdentifier: pid_t(appPID))?.terminate()
    }

    static func forceQuit(appPID: Int32) {
        NSRunningApplication(processIdentifier: pid_t(appPID))?.forceTerminate()
    }

    /// Asks one process to quit (SIGTERM), like `kill <pid>`. Only if `pid` still names the
    /// process the user saw (one of ours, same start time), so a reused pid is never hit.
    static func quit(pid: Int32, startTime: UInt64) {
        guard isSameProcess(pid, startTime) else { return }
        kill(pid, SIGTERM)
    }

    /// Confirms, then kills one process immediately (SIGKILL), with the same identity check.
    @MainActor
    static func confirmForceQuit(pid: Int32, startTime: UInt64, name: String) {
        guard confirm(name: name, detail: "The process will stop immediately. Anything it hasn\u{2019}t saved is lost.")
        else { return }
        guard isSameProcess(pid, startTime) else { return }
        kill(pid, SIGKILL)
    }

    private static func isSameProcess(_ pid: Int32, _ startTime: UInt64) -> Bool {
        guard let current = startTimeOfOwnProcess(pid) else { return false }
        return startTime == 0 || current == startTime
    }

    /// Confirms, then force quits. Uses AppKit `NSAlert`, not SwiftUI `.alert`, for the same
    /// reason as `AppModel.confirmAndEmptyTrash`: a SwiftUI alert inside the transient
    /// `MenuBarExtra(.window)` panel shifts focus and dismisses the panel before the action
    /// can run. `NSAlert` runs its own modal window, independent of the panel.
    @MainActor
    static func confirmForceQuit(appPID: Int32, name: String) {
        guard confirm(name: name, detail: "The app will quit immediately and you\u{2019}ll lose any unsaved changes.")
        else { return }
        forceQuit(appPID: appPID)
    }

    @MainActor
    private static func confirm(name: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Force quit \u{201C}\(name)\u{201D}?"
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Force Quit").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

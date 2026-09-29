import AppKit

/// Quit actions for an app, addressed by its GUI app pid (the breakdown's group key).
/// `terminate()` is a graceful request — the app runs its normal quit, including any
/// unsaved-work prompt (like ⌘Q). `forceTerminate()` kills it immediately.
enum ProcessActions {
    static func quit(appPID: Int32) {
        NSRunningApplication(processIdentifier: pid_t(appPID))?.terminate()
    }

    static func forceQuit(appPID: Int32) {
        NSRunningApplication(processIdentifier: pid_t(appPID))?.forceTerminate()
    }

    /// Confirms, then force quits. Uses AppKit `NSAlert`, not SwiftUI `.alert`, for the same
    /// reason as `AppModel.confirmAndEmptyTrash`: a SwiftUI alert inside the transient
    /// `MenuBarExtra(.window)` panel shifts focus and dismisses the panel before the action
    /// can run. `NSAlert` runs its own modal window, independent of the panel.
    @MainActor
    static func confirmForceQuit(appPID: Int32, name: String) {
        let alert = NSAlert()
        alert.messageText = "Force quit \u{201C}\(name)\u{201D}?"
        alert.informativeText = "The app will quit immediately and you\u{2019}ll lose any unsaved changes."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Force Quit").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        forceQuit(appPID: appPID)
    }
}

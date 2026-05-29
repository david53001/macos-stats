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
}

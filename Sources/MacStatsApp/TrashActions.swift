import AppKit

/// Empties the Trash by asking Finder (covers all volumes, like the real menu item).
/// There is no public FileManager API to empty the Trash, so we script Finder. MacStats shows no
/// Trash size: Finder can't size some folders in the Trash at all (a size read came back unknown
/// on every open), and `~/.Trash` can't be read directly without Full Disk Access.
enum TrashActions {
    /// Why an Empty failed: a short user-facing message, and whether Finder access was refused
    /// (the user said Don't Allow; macOS won't ask again, so the alert offers the settings).
    struct Failure {
        let message: String
        let notPermitted: Bool
    }

    /// Returns nil on success. The first call makes macOS ask to let MacStats use Finder.
    static func emptyTrash() -> Failure? {
        let script = NSAppleScript(source: "tell application \"Finder\" to empty the trash")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        guard let error else { return nil }
        let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        if code == -1743 {
            return Failure(message: "MacStats needs permission to control Finder. Allow it in "
                               + "System Settings → Privacy & Security → Automation, then try again.",
                           notPermitted: true)
        }
        return Failure(message: "Couldn\u{2019}t empty the Trash (error \(code)).", notPermitted: false)
    }

    /// System Settings → Privacy & Security → Automation, where Finder access can be turned on.
    static func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

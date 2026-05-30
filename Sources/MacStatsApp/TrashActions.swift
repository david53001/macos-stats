import Foundation

/// Empties the Trash by asking Finder (covers all volumes, like the real menu item).
/// There is no public FileManager API to empty the Trash, so we script Finder.
enum TrashActions {
    /// Returns nil on success, or a short user-facing message on failure.
    static func emptyTrash() -> String? {
        let script = NSAppleScript(source: "tell application \"Finder\" to empty the trash")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        guard let error else { return nil }
        let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        if code == -1743 {
            return "MacStats needs permission to control Finder. Enable it in "
                 + "System Settings → Privacy & Security → Automation, then try again."
        }
        return "Couldn't empty the Trash (error \(code))."
    }

    /// Total logical size (bytes) of everything in the Trash, read via Finder. A direct
    /// filesystem scan of `~/.Trash` fails ("Operation not permitted") without Full Disk
    /// Access — it's a TCC-protected location — so we ask Finder, which is exempt (same as
    /// `emptyTrash`). Returns nil when Finder can't be reached or permission is refused, i.e.
    /// the size is genuinely unknown (distinct from an empty Trash, which returns 0).
    static func trashSize() -> UInt64? {
        let script = NSAppleScript(source: """
            tell application "Finder"
                set total to 0
                repeat with anItem in (get items of trash)
                    try
                        set total to total + (size of anItem)
                    end try
                end repeat
                return total
            end tell
            """)
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if error != nil { return nil }
        guard let value = result?.doubleValue, value.isFinite, value >= 0 else { return nil }
        return UInt64(value)
    }
}

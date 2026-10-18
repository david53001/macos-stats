import AppKit

/// One read of the Trash size: the size, Finder access refused (the user said Don't Allow; macOS
/// won't ask again), or unknown for another reason (Finder not reachable).
enum TrashReading: Equatable {
    case bytes(UInt64)
    case notPermitted
    case unavailable
}

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
        return "Couldn\u{2019}t empty the Trash (error \(code))."
    }

    /// Total logical size (bytes) of everything in the Trash, read via Finder. A direct
    /// filesystem scan of `~/.Trash` fails ("Operation not permitted") without Full Disk
    /// Access — it's a TCC-protected location — so we ask Finder, which is exempt (same as
    /// `emptyTrash`). An empty Trash reads `.bytes(0)`. Finder answers `missing value` for a
    /// folder whose size it hasn't worked out yet; that used to count as 0 (silently low), so it
    /// is retried for up to ~2 s and the read is `.unavailable` if it still isn't known.
    static func trashSize() -> TrashReading {
        let script = NSAppleScript(source: """
            tell application "Finder"
                set total to 0
                repeat with anItem in (get items of trash)
                    try
                        set itemSize to size of anItem
                        repeat 20 times
                            if itemSize is not missing value then exit repeat
                            delay 0.1
                            set itemSize to size of anItem
                        end repeat
                        if itemSize is missing value then return -1
                        set total to total + itemSize
                    end try
                end repeat
                return total
            end tell
            """)
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if let error {
            return (error[NSAppleScript.errorNumber] as? Int) == -1743 ? .notPermitted : .unavailable
        }
        guard let value = result?.doubleValue, value.isFinite, value >= 0 else { return .unavailable }
        return .bytes(UInt64(value))
    }

    /// System Settings → Privacy & Security → Automation, where Finder access can be turned on.
    static func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

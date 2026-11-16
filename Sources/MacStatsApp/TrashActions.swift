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
    /// `emptyTrash`). An empty Trash reads `.bytes(0)`.
    ///
    /// All sizes come in one Apple Event (one per item used to cost ~1 ms each). Finder answers
    /// `missing value` for a folder whose size it hasn't worked out, and may never do so for one in
    /// the Trash (seen live: every read came back unknown after 2 s of polling). Such an item is
    /// summed from its files instead (up to 5 s), else polled for up to ~2 s; if it still isn't
    /// known the read is `.unavailable`, never silently low.
    static func trashSize() -> TrashReading {
        let script = NSAppleScript(source: """
            tell application "Finder"
                if (count of items of trash) is 0 then return 0
                try
                    set sizes to size of every item of trash
                on error
                    set sizes to {}
                    repeat with anItem in (get items of trash)
                        try
                            set end of sizes to (size of anItem)
                        on error
                            set end of sizes to 0
                        end try
                    end repeat
                end try
                if class of sizes is not list then set sizes to {sizes}
                set total to 0
                repeat with i from 1 to count of sizes
                    set itemSize to item i of sizes
                    if itemSize is missing value then
                        try
                            with timeout of 5 seconds
                                set fileSizes to size of every file of entire contents of item i of trash
                            end timeout
                            if class of fileSizes is not list then set fileSizes to {fileSizes}
                            set itemSize to 0
                            repeat with fileSize in fileSizes
                                if contents of fileSize is missing value then error "unsized"
                                set itemSize to itemSize + fileSize
                            end repeat
                        on error
                            set itemSize to missing value
                            try
                                repeat 20 times
                                    delay 0.1
                                    set itemSize to size of item i of trash
                                    if itemSize is not missing value then exit repeat
                                end repeat
                            end try
                        end try
                        if itemSize is missing value then return -1
                    end if
                    set total to total + itemSize
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

    /// When the home Trash folder last changed (an item added, removed or put back), or nil if it
    /// can't be read. Only the folder's own date, not its (TCC-protected) contents.
    static func homeTrashStamp() -> Date? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}

import Foundation

/// Flattens the ranked apps plus the expanded app's processes into one list, so the view's
/// `LazyVStack` builds only the rows on screen (an app can have hundreds of processes).
public enum BreakdownList {
    public static let initialChildren = 5
    public static let moreChildren = 25

    public struct Row: Identifiable, Sendable {
        public enum Kind: Sendable {
            case app(AppUsage)
            case process(ProcessUsage, AppUsage)
            /// "N more…": the expanded app's processes not shown yet. `enabled` false for an app kept
            /// as an "Ended" placeholder while frozen (nothing to show), until the unfreeze removes it.
            case more(Int, enabled: Bool)
        }
        public let id: String
        public let kind: Kind
        /// The app this row belongs to (its own row, one of its processes, or its "N more…").
        public let app: Int32
    }

    /// `ended`: an app kept as a placeholder while frozen keeps its "N more…" row, disabled, so the
    /// rows below don't move up under the pointer.
    public static func rows(_ apps: [AppUsage], expanded: Int32?, visible: Int,
                            ended: (Int32) -> Bool = { _ in false }) -> [Row] {
        var rows: [Row] = []
        rows.reserveCapacity(apps.count + visible + 1)
        for app in apps {
            rows.append(Row(id: "a\(app.appPID)", kind: .app(app), app: app.appPID))
            guard app.appPID == expanded, app.processes.count > 1 else { continue }
            for p in app.processes.prefix(visible) {
                rows.append(Row(id: "p\(p.pid)", kind: .process(p, app), app: app.appPID))
            }
            if app.processes.count > visible {
                rows.append(Row(id: "m\(app.appPID)",
                                kind: .more(app.processes.count - visible, enabled: !ended(app.appPID)),
                                app: app.appPID))
            }
        }
        return rows
    }
}

import Foundation

/// What the pointer is doing over a breakdown's list, as the view reports it once a scan.
public struct BreakdownPointer: Equatable, Sendable {
    public var inside: Bool
    /// Moved since the list appeared. The list appears where the clicked card was, so a pointer that
    /// hasn't moved since is resting from that click, not pointing at a row: it doesn't freeze the order.
    public var moved: Bool

    public init(inside: Bool, moved: Bool) {
        self.inside = inside
        self.moved = moved
    }
}

/// One breakdown as shown, plus what the next scan needs to keep it steady: the app and process
/// order, the held text values (which the ranking also reads), the rows kept as "Ended"
/// placeholders while frozen, and the freeze itself. A value: `MetricsStore` resets it by
/// replacing it.
///
/// Rules (`apply`): apps and each app's processes are ranked by the values their rows print
/// (`HeldReading`, which already needs a change to show on two scans), and re-rank only with a clear
/// lead (`stableRanking`), or when a row has printed more than the one above it for two scans
/// (`rank`), so the order agrees with the numbers on screen. The order is frozen while
/// the pointer is over the list (once it has moved there) or a context menu is open, and until the
/// first scan `breakdownUnfreezeDelay` after both end.
/// While frozen, a row whose app or process ended stays in place as a placeholder (`isEnded`), so
/// nothing below it moves; an ended app keeps its processes as placeholders too, so an expanded app
/// that quits doesn't collapse under the pointer. An app's "Finished processes" row stays (at 0) once it
/// has appeared. A process new to a listed app waits for the unfreeze, so an expanded app's block
/// never grows under the pointer. Values stay exact (bars follow them); the text reads `shownValue` (`HeldReading`).
public struct BreakdownDisplay {
    public let metric: BreakdownMetric
    /// The rows in display order, from the last `apply`.
    public private(set) var apps: [AppUsage] = []
    /// The CPU header (whole Mac over the rows' span), held like the card.
    public private(set) var shownTotalCPU: Double?
    /// What a full bar stands for (CPU %, W): a sticky 1-2-5 step above the top row, so bars carry
    /// information at light load and change length only when their own row does. nil for memory
    /// (its bars are a share of the Mac's RAM).
    public private(set) var barScale: Double?

    private var order: [Int32] = []
    private var rows: [Int32: AppRow] = [:]
    /// Apps printed higher than the app above them on the last published scan (`rank`).
    private var lagging: Set<Int32> = []

    private var pointerInside = false
    private var menuOpen = false
    /// A context menu was opened: the pointer is on a row now, even if it hasn't moved.
    private var engaged = false
    /// After the pointer leaves (or a menu closes), the first scan at or after this time unfreezes.
    private var unfreezeAt: TimeInterval?

    private struct AppRow {
        var text: HeldReading
        var ended: Bool
        var children: [Int32]
        var processes: [Int32: ProcessRow]
        /// This app's processes printed above their upper neighbour on the last scan (`rank`).
        var lagging: Set<Int32> = []
    }

    private struct ProcessRow {
        var text: HeldReading
        var ended: Bool
        /// So a placeholder keeps its start time and name.
        var startTime: UInt64
        var name: String?
    }

    /// `shownTotalCPU`: the CPU card's value as the breakdown opens, so the header goes on from
    /// the number just clicked and changes only when its own reading moves clearly away from it.
    public init(metric: BreakdownMetric, shownTotalCPU: Double? = nil) {
        self.metric = metric
        self.shownTotalCPU = metric == .cpu ? shownTotalCPU : nil
    }

    // MARK: Freeze

    /// The pointer entered (true) or left (false) the list, from hover events.
    public mutating func setPointerInside(_ inside: Bool, time: TimeInterval) {
        guard inside != pointerInside else { return }
        pointerInside = inside
        if !pointerInside, !menuOpen { unfreezeAt = time + breakdownUnfreezeDelay }
    }

    /// A row's context menu opened (true) or closed (false).
    public mutating func setMenuOpen(_ open: Bool, time: TimeInterval) {
        guard open != menuOpen else { return }
        menuOpen = open
        if open { engaged = true }
        if !pointerInside, !menuOpen { unfreezeAt = time + breakdownUnfreezeDelay }
    }

    /// Whether a scan at `time` keeps the order. `pointer` is the view's reading (nil = none: the
    /// hover events decide); a pointer that hasn't moved since the list appeared doesn't freeze it,
    /// unless it has opened a row's menu (a right-click without moving is pointing at that row).
    public mutating func isFrozen(at time: TimeInterval, pointer: BreakdownPointer?) -> Bool {
        if let at = unfreezeAt, time >= at { unfreezeAt = nil }
        let pointing = pointer.map { $0.inside && ($0.moved || engaged) } ?? pointerInside
        return pointing || menuOpen || unfreezeAt != nil
    }

    // MARK: Scans

    /// Folds in one scan (rows as `BreakdownScanner` returns them). Returns whether the app order changed.
    @discardableResult
    public mutating func apply(_ scan: [AppUsage], totalCPU: Double?, frozen: Bool) -> Bool {
        let previous = rows
        let previousOrder = order

        var byApp = Dictionary(scan.map { ($0.appPID, $0) }, uniquingKeysWith: { a, _ in a })
        var endedApps: Set<Int32> = []
        if frozen {
            for key in previousOrder where byApp[key] == nil {
                byApp[key] = AppUsage(appPID: key, processes: [], cpuPercent: 0, memoryBytes: 0)
                endedApps.insert(key)
            }
        }
        let rule = RankHysteresis.for(metric)
        let texts = byApp.mapValues { held(previous[$0.appPID]?.text, $0.value(for: metric)) }
        let newOrder = rank(previousOrder, texts.mapValues(\.shown), rule: rule, frozen: frozen,
                            lagging: &lagging, groupsLast: metric == .memory)

        var nextRows: [Int32: AppRow] = [:]
        nextRows.reserveCapacity(newOrder.count)
        var ordered: [AppUsage] = []
        ordered.reserveCapacity(newOrder.count)
        for key in newOrder {
            guard let app = byApp[key] else { continue }
            let old = previous[key]
            let appEnded = endedApps.contains(key)
            // Memory has nothing to say about exited processes (they hold no memory).
            var children = metric == .memory
                ? app.processes.filter { $0.pid != BreakdownGroup.exitedProcesses } : app.processes
            // While frozen, a process new to a listed app waits for the unfreeze: added to an
            // expanded app's rows (or as its "N more…" row) it would push every row below down.
            if frozen, let old {
                let known = Set(old.children)
                children.removeAll { !known.contains($0.pid) }
            }
            var endedKids: Set<Int32> = []
            let present = Set(children.map(\.pid))
            for pid in old?.children ?? [] where !present.contains(pid) {
                let placeholder = ProcessUsage(pid: pid, appPID: key, cpuPercent: 0, memoryBytes: 0,
                                               startTime: old?.processes[pid]?.startTime ?? 0,
                                               name: old?.processes[pid]?.name)
                if pid == BreakdownGroup.exitedProcesses, !appEnded {
                    children.append(placeholder)   // stays, at 0
                } else if frozen {
                    children.append(placeholder)
                    endedKids.insert(pid)
                }
            }
            let byPID = Dictionary(children.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            let childTexts = byPID.mapValues { held(old?.processes[$0.pid]?.text, $0.value(for: metric)) }
            var kidsLagging = old?.lagging ?? []
            let kids = rank(old?.children ?? [], childTexts.mapValues(\.shown), rule: rule, frozen: frozen,
                            lagging: &kidsLagging, groupsLast: false)
            let processes = kids.compactMap { byPID[$0] }

            var processRows: [Int32: ProcessRow] = [:]
            processRows.reserveCapacity(processes.count)
            for p in processes {
                processRows[p.pid] = ProcessRow(text: childTexts[p.pid] ?? HeldReading(0, step: 1),
                                                ended: endedKids.contains(p.pid), startTime: p.startTime,
                                                name: p.name)
            }
            nextRows[key] = AppRow(text: texts[key] ?? HeldReading(0, step: 1), ended: appEnded,
                                   children: kids, processes: processRows, lagging: kidsLagging)
            ordered.append(AppUsage(appPID: app.appPID, processes: processes, cpuPercent: app.cpuPercent,
                                    memoryBytes: app.memoryBytes, watts: app.watts))
        }
        let changed = newOrder != order
        order = newOrder
        rows = nextRows
        apps = ordered

        if metric == .cpu, let totalCPU {
            shownTotalCPU = heldValue(shown: shownTotalCPU, value: totalCPU, step: 1, band: 0.75)
        }
        if metric != .memory {
            let peak = scan.map { $0.value(for: metric) }.max() ?? 0
            barScale = stickyUpperBound(previous: barScale, peak: peak, minimum: metric == .cpu ? 1 : 0.5)
        }
        return changed
    }

    /// The held value to print for an app row, or for one of its process rows (`pid`). nil before
    /// the row's first real reading.
    public func shownValue(app: Int32, pid: Int32? = nil) -> Double? {
        guard let pid else { return rows[app]?.text.shown }
        return rows[app]?.processes[pid]?.text.shown
    }

    /// True for a row kept in place while frozen although its app (`pid` nil) or process ended.
    public func isEnded(app: Int32, pid: Int32? = nil) -> Bool {
        guard let pid else { return rows[app]?.ended ?? false }
        return rows[app]?.processes[pid]?.ended ?? false
    }

    /// `stableRanking`, plus an inversion timeout: a row printed higher than the row above it on
    /// two published scans in a row (a lead within the margins) passes it on the second, so the list
    /// never shows "3.0 %" above "3.3 %" for longer than one scan. `lagging` holds the rows that were
    /// printed above their upper neighbour on the last published scan.
    private func rank(_ previous: [Int32], _ values: [Int32: Double], rule: RankHysteresis, frozen: Bool,
                      lagging: inout Set<Int32>, groupsLast: Bool) -> [Int32] {
        let order = stableRanking(previous: previous, now: values, rule: rule, frozen: frozen,
                                  groupsLast: groupsLast, promoted: lagging)
        guard !frozen else { return order }
        lagging = []
        for (above, key) in zip(order, order.dropFirst())
        where (values[key] ?? 0) > (values[above] ?? 0) && (!groupsLast || (above < 0) == (key < 0)) {
            lagging.insert(key)
        }
        return order
    }

    /// Row text: within max(0.75 × the printed step, min(10 % (memory 3 %) of the value, 2 pp / 0.2 W)),
    /// confirmed over two scans (`HeldReading`).
    private func held(_ text: HeldReading?, _ value: Double) -> HeldReading {
        let step = breakdownValueStep(metric, value)
        guard var text else { return HeldReading(value, step: step) }
        text.update(value, step: step, band: 0.75, relBand: metric == .memory ? 0.03 : 0.10,
                    cap: metric == .cpu ? 2 : metric == .energy ? 0.2 : .infinity)
        return text
    }
}


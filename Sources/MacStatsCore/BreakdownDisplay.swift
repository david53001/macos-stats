import Foundation

/// What the pointer is doing over a breakdown's list, as the view reports it once a scan.
public struct BreakdownPointer: Equatable, Sendable {
    public var inside: Bool
    /// Moved since the list appeared (or scrolled or clicked in it). The list appears where the clicked
    /// card was, so a pointer that hasn't moved since is resting from that click, not pointing at a
    /// row: it doesn't freeze the order.
    public var moved: Bool
    /// The app whose rows (its own row, its process rows or its "N more…" row) are under the pointer;
    /// nil when unknown (between rows, or after a scroll until the next hover).
    public var app: Int32?

    public init(inside: Bool, moved: Bool, app: Int32? = nil) {
        self.inside = inside
        self.moved = moved
        self.app = app
    }
}

/// How much of a breakdown a scan keeps in place.
public enum BreakdownFreeze: Equatable, Sendable {
    case none
    /// Every row keeps its place.
    case all
    /// The app rows down to and including this one keep their places; the apps below it still re-rank
    /// among themselves (none can climb past it). Nothing under the pointer moves, and a busy app below
    /// it isn't stuck under smaller ones. Process rows, placeholders and newcomers are as in `.all`.
    case through(Int32)
}

/// One breakdown as shown, plus what the next scan needs to keep it steady: the app and process
/// order, the held text values (which the ranking also reads), the rows kept as "Ended"
/// placeholders while frozen, and the freeze itself. A value: `MetricsStore` resets it by
/// replacing it. The rules, their constants and their tests: `docs/design/breakdown-stability.md`.
///
/// In short (`apply`): rows print held values (`HeldReading`); apps and each app's processes are ranked
/// by those printed values with hysteresis (`stableRanking`, `RankHysteresis`), an inversion timeout and a
/// reorder dwell (`ListRanking`). While the pointer is over the list (or a menu is open) the order freezes
/// (`freeze`): ended rows stay as placeholders and an app gains no new process rows until the unfreeze.
/// Values stay exact (bars follow them).
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

    /// The app rows' order and ranking memory.
    private var appList = ListRanking()
    private var rows: [Int32: AppRow] = [:]

    private var pointerInside = false
    private var menuOpen = false
    /// A context menu was opened in this breakdown: the pointer is on a row, even if it hasn't moved.
    private var engaged = false
    /// After the pointer leaves (or a menu closes), the first scan at or after this time unfreezes.
    private var unfreezeAt: TimeInterval?

    private struct AppRow {
        var text: HeldReading
        var ended: Bool
        /// Its process rows' order and ranking memory, and each one's held text.
        var kids: ListRanking
        var processes: [Int32: ProcessRow]
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

    /// What a scan at `time` keeps in place. `pointer` is the view's reading (nil = none: the hover
    /// events decide). A pointer that hasn't moved since the list appeared doesn't freeze it, unless it
    /// has opened a row's menu (a right-click without moving is pointing at that row). A pointer on a
    /// known app's rows freezes only down to that app; a menu, the unfreeze delay or an unknown row
    /// freeze everything.
    public mutating func freeze(at time: TimeInterval, pointer: BreakdownPointer?) -> BreakdownFreeze {
        if let at = unfreezeAt, time >= at { unfreezeAt = nil }
        if menuOpen || unfreezeAt != nil { return .all }
        guard let pointer else { return pointerInside ? .all : .none }
        guard pointer.inside, pointer.moved || engaged else { return .none }
        if let app = pointer.app, appList.order.contains(app) { return .through(app) }
        return .all
    }

    // MARK: Scans

    /// Folds in one scan (rows as `BreakdownScanner` returns them), taken at `time` (nil: no reorder
    /// dwell). Returns whether the app order changed.
    @discardableResult
    public mutating func apply(_ scan: [AppUsage], totalCPU: Double?, freeze: BreakdownFreeze,
                               time: TimeInterval? = nil) -> Bool {
        let frozen = freeze != .none
        var byApp = Dictionary(scan.map { ($0.appPID, $0) }, uniquingKeysWith: { a, _ in a })
        // While frozen, an app that ended stays in place (with its processes) as a placeholder.
        var endedApps: Set<Int32> = []
        if frozen {
            for key in appList.order where byApp[key] == nil {
                byApp[key] = AppUsage(appPID: key, processes: [], cpuPercent: 0, memoryBytes: 0)
                endedApps.insert(key)
            }
        }
        let texts = byApp.mapValues { held(rows[$0.appPID]?.text, $0.value(for: metric)) }
        let fixed: Int
        switch freeze {
        case .none: fixed = 0
        case .all: fixed = .max
        case .through(let app): fixed = appList.order.firstIndex(of: app).map { $0 + 1 } ?? .max
        }
        let oldOrder = appList.order
        appList.rank(texts.mapValues(\.shown), rule: .for(metric), fixed: fixed, time: time,
                     dwell: breakdownReorderDwell, groupsLast: metric == .memory)

        var nextRows: [Int32: AppRow] = [:]
        nextRows.reserveCapacity(appList.order.count)
        var ordered: [AppUsage] = []
        ordered.reserveCapacity(appList.order.count)
        for key in appList.order {
            guard let app = byApp[key] else { continue }
            let ended = endedApps.contains(key)
            let (kids, processRows, processes) = self.processRows(of: app, old: rows[key], appEnded: ended,
                                                                  frozen: frozen, time: time)
            nextRows[key] = AppRow(text: texts[key] ?? HeldReading(0, step: 1), ended: ended,
                                   kids: kids, processes: processRows)
            ordered.append(AppUsage(appPID: app.appPID, processes: processes, cpuPercent: app.cpuPercent,
                                    memoryBytes: app.memoryBytes, watts: app.watts))
        }
        rows = nextRows
        apps = ordered

        if metric == .cpu, let totalCPU {
            shownTotalCPU = heldValue(shown: shownTotalCPU, value: totalCPU, step: 1, band: RowHold.cpu.band)
        }
        if metric != .memory {
            let peak = scan.map { $0.value(for: metric) }.max() ?? 0
            barScale = stickyUpperBound(previous: barScale, peak: peak, minimum: metric == .cpu ? 1 : 0.5)
        }
        return appList.order != oldOrder
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

    /// One app's process rows, in order, and what the next scan needs (`AppRow.kids`, `.processes`).
    /// Known processes rank like the apps but with a longer dwell (`breakdownProcessReorderDwell`), and
    /// rows under `RankHysteresis.promotionFloor` pass a neighbour only by the margins: tiny values
    /// crossing are noise. A process new to the app joins below the known ones for one scan (most are
    /// short-lived). While frozen: no newcomers, and ended processes stay as placeholders.
    /// "Finished processes" (work of processes that are gone) is always last, like a group row, and
    /// shows only while it has something to show (or is frozen).
    private func processRows(of app: AppUsage, old: AppRow?, appEnded: Bool, frozen: Bool,
                             time: TimeInterval?) -> (ListRanking, [Int32: ProcessRow], [ProcessUsage]) {
        let exited = BreakdownGroup.exitedProcesses
        let known = Set(old?.kids.order ?? [])
        // Memory has nothing to say about exited processes (they hold no memory).
        var children = metric == .memory ? app.processes.filter { $0.pid != exited } : app.processes
        if frozen, old != nil { children.removeAll { !known.contains($0.pid) } }
        var endedKids: Set<Int32> = []
        if frozen {
            let present = Set(children.map(\.pid))
            for pid in old?.kids.order ?? [] where !present.contains(pid) {
                children.append(ProcessUsage(pid: pid, appPID: app.appPID, cpuPercent: 0, memoryBytes: 0,
                                             startTime: old?.processes[pid]?.startTime ?? 0,
                                             name: old?.processes[pid]?.name))
                // "Finished processes" keeps printing its (falling) value unless its app ended.
                if pid != exited || appEnded { endedKids.insert(pid) }
            }
        }
        var byPID = Dictionary(children.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var texts = byPID.mapValues { held(old?.processes[$0.pid]?.text, $0.value(for: metric)) }
        if !frozen, texts[exited]?.shown == 0 {
            texts[exited] = nil
            byPID[exited] = nil
        }

        let rule = RankHysteresis.for(metric)
        let settled = old == nil ? texts : texts.filter { known.contains($0.key) }
        var kids = old?.kids ?? ListRanking()
        kids.rank(settled.mapValues(\.shown), rule: rule, fixed: frozen ? .max : 0, time: time,
                  dwell: breakdownProcessReorderDwell, groupsLast: true) { pid in
            (settled[pid]?.shown ?? 0) >= rule.promotionFloor
        }
        kids.order += stableRanking(previous: [], now: texts.filter { settled[$0.key] == nil }.mapValues(\.shown),
                                    rule: rule, groupsLast: true)
        if let i = kids.order.firstIndex(of: exited), i != kids.order.count - 1 {
            kids.order.append(kids.order.remove(at: i))   // below a newcomer too
        }
        let processes = kids.order.compactMap { byPID[$0] }

        var processRows: [Int32: ProcessRow] = [:]
        processRows.reserveCapacity(processes.count)
        for p in processes {
            processRows[p.pid] = ProcessRow(text: texts[p.pid] ?? HeldReading(0, step: 1),
                                            ended: endedKids.contains(p.pid), startTime: p.startTime, name: p.name)
        }
        return (kids, processRows, processes)
    }

    /// A row's printed value: `HeldReading` with the metric's `RowHold`.
    private func held(_ text: HeldReading?, _ value: Double) -> HeldReading {
        let step = breakdownValueStep(metric, value)
        guard var text else { return HeldReading(value, step: step) }
        let hold = RowHold.for(metric)
        text.update(value, step: step, band: hold.band, relBand: hold.relBand, cap: hold.cap)
        return text
    }
}

/// One ranked list (the apps, or one app's processes) and its memory between scans.
struct ListRanking {
    /// The order shown after the last `rank`.
    var order: [Int32] = []
    /// Rows printed higher than the row above them on the last unfrozen scan: they pass it on the next
    /// allowed one, margins or not (the inversion timeout), so "3.0 %" doesn't stay above "3.3 %".
    private var lagging: Set<Int32> = []
    /// When the order last changed while unfrozen.
    private var reorderedAt: TimeInterval?

    /// Re-ranks `order` by `values` (`stableRanking`): the first `fixed` rows keep their places
    /// (`.max`: all, frozen). Apart from a big jump (`RankHysteresis.jump`), the list reorders at most
    /// once per `dwell`; a held-back row stays `lagging` for the next allowed scan. New rows take their
    /// sorted places either way. Only rows that pass `promotable` can become `lagging`.
    mutating func rank(_ values: [Int32: Double], rule: RankHysteresis, fixed: Int, time: TimeInterval?,
                       dwell: TimeInterval, groupsLast: Bool, promotable: (Int32) -> Bool = { _ in true }) {
        let previous = order
        order = stableRanking(previous: previous, now: values, rule: rule, fixed: fixed,
                              groupsLast: groupsLast, promoted: lagging)
        guard fixed != .max else { return }
        if let time, movesRows(previous, order) {
            if let at = reorderedAt, time - at < dwell {
                // A jump still moves, without restarting the dwell (else a spiky row starves the rest).
                order = stableRanking(previous: previous, now: values, rule: rule.jumpsOnly, fixed: fixed,
                                      groupsLast: groupsLast)
            } else {
                reorderedAt = time
            }
        }
        lagging = []
        for (above, key) in zip(order, order.dropFirst())
        where (values[key] ?? 0) > (values[above] ?? 0) && (!groupsLast || (above < 0) == (key < 0)) && promotable(key) {
            lagging.insert(key)
        }
    }

    /// Whether `order` moves any row of `previous` relative to the others (rows coming or going don't count).
    private func movesRows(_ previous: [Int32], _ order: [Int32]) -> Bool {
        let before = Set(previous), after = Set(order)
        return previous.filter { after.contains($0) } != order.filter { before.contains($0) }
    }
}

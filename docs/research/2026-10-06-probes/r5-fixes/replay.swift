// Replays recorded breakdown scan results (record.swift) through the REAL MetricsStore + BreakdownDisplay +
// BreakdownList of whatever sources this is compiled with, and prints round 5's measures:
//   - pointer away: top-8 order changes, inversions, the expanded app's visible process rows (order, set,
//     "Finished processes" placement), the flattened first 14 rows;
//   - the one-core burst: its app's row, Finished row and the header from 2 s before it starts to 14 s after it ends;
//   - pointer resting on the 2nd app's row (partial freeze) vs an unknown row (full freeze): rows at or above
//     the pointer that moved (must be 0) and scans where a row below printed > 2x the row above it.
// Usage: replay <rec.json> [variant ...]
import Foundation

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [String: Any]
let only = Set(args.dropFirst(2))

struct Scan { let t: Double; let measuring: Bool; let total: Double?; let apps: [AppUsage] }

func decode(_ arr: [[String: Any]]) -> [Scan] {
    arr.map { d in
        let apps = (d["apps"] as! [[String: Any]]).map { a -> AppUsage in
            let pid = Int32(a["a"] as! Int)
            let ps = (a["p"] as! [[Double]]).map {
                ProcessUsage(pid: Int32($0[0]), appPID: pid, cpuPercent: $0[1], memoryBytes: UInt64($0[2]),
                             watts: $0[3], startTime: UInt64($0[4]))
            }
            return AppUsage(appPID: pid, processes: ps, cpuPercent: a["c"] as! Double,
                            memoryBytes: UInt64(a["m"] as! Double), watts: a["w"] as! Double)
        }
        return Scan(t: d["t"] as! Double, measuring: d["measuring"] as! Bool, total: d["total"] as? Double, apps: apps)
    }
}

let burst = json["burst"] as? [String: Any] ?? [:]
let burstPID = Int32(burst["pid"] as? Int ?? -99)
let burstStart = burst["start"] as? Double ?? -1
let burstStop = burst["stop"] as? Double ?? burstStart + 16
let exited = BreakdownGroup.exitedProcesses

func perMin(_ n: Int, _ span: Double) -> Double { Double(n) / max(span / 60, 1e-9) }

@MainActor func away(_ name: String, _ scans: [Scan], metric: BreakdownMetric) {
    let store = MetricsStore()
    store.beginBreakdown(metric: metric)
    store.breakdownPointerProbe = { BreakdownPointer(inside: false, moved: false) }
    let base = 800_000_000.0
    var first: Double?, shownScans = 0
    var lastTop8: [Int32]?, lastFlat: [String]?, lastKids: [Int32]?, lastKidSet: Set<Int32>?
    var orderChanges = 0, invScans = 0, flatChanges = 0, kidOrder = 0, kidSet = 0, finishedTop = 0, finishedZero = 0
    var expanded: Int32?, burstApp: Int32?
    for s in scans {
        store.setBreakdown(s.apps, measuring: s.measuring, totalCPU: s.total, time: base + s.t)
        guard !store.breakdownMeasuring else { continue }
        shownScans += 1
        if first == nil { first = s.t }
        let rows = store.breakdown
        if burstApp == nil, s.t >= burstStart, let app = rows.first(where: { $0.processes.contains { $0.pid == burstPID } }) {
            burstApp = app.appPID
        }
        if metric != .memory, burstStart >= 0, s.t >= burstStart - 2, s.t <= burstStop + 14, let b = burstApp,
           let app = rows.first(where: { $0.appPID == b }) {
            let fin = app.processes.contains { $0.pid == exited }
                ? breakdownValueText(metric, store.shownValue(app: b, pid: exited) ?? -1) : "-"
            print(String(format: "    BURST %@%.1f  app row %@  finished %@  header %@",
                         s.t < burstStop ? "start+" : "stop+", s.t < burstStop ? s.t - burstStart : s.t - burstStop,
                         breakdownValueText(metric, store.shownValue(app: b) ?? -1), fin,
                         store.breakdownShownTotalCPU.map { String(format: "%.0f", $0) } ?? "-"))
        }
        if shownScans == 1 {
            expanded = rows.prefix(8).filter { $0.processes.count > 1 && $0.isApp }
                .max { $0.processes.count < $1.processes.count }?.appPID
        }
        if let e = expanded, (rows.first { $0.appPID == e }?.processes.count ?? 0) <= 1 { expanded = nil }
        let top8 = Array(rows.prefix(8).map(\.appPID))
        if let l = lastTop8, l != top8 { orderChanges += 1 }
        lastTop8 = top8
        let flat = Array(BreakdownList.rows(rows, expanded: expanded, visible: 5).prefix(14).map(\.id))
        if let l = lastFlat { flatChanges += zip(l, flat).filter { $0 != $1 }.count }
        lastFlat = flat
        let shown = rows.prefix(8).map { store.shownValue(app: $0.appPID) ?? $0.value(for: metric) }
        var inv = false
        for i in 1..<max(1, shown.count) where !(metric == .memory && (rows[i].appPID < 0) != (rows[i - 1].appPID < 0)) {
            if breakdownValueText(metric, shown[i]) != breakdownValueText(metric, shown[i - 1]), shown[i] > shown[i - 1] { inv = true }
        }
        if inv { invScans += 1 }
        if let e = expanded, let app = rows.first(where: { $0.appPID == e }) {
            let kids = Array(app.processes.prefix(5).map(\.pid))
            if let l = lastKids, l != kids { kidOrder += 1 }
            if let l = lastKidSet, l != Set(kids) { kidSet += 1 }
            lastKids = kids; lastKidSet = Set(kids)
            if kids.first == exited || kids.dropFirst().first == exited { finishedTop += 1 }
            if kids.contains(exited), breakdownValueText(metric, store.shownValue(app: e, pid: exited) ?? 0)
                == breakdownValueText(metric, 0) { finishedZero += 1 }
        }
    }
    let span = (scans.last?.t ?? 0) - (first ?? 0)
    print(String(format: "[%@] pointer away, %d scans: top-8 order chg/min %.1f, inversion scans %d/%d, flat(14) slot chg/min %.1f",
                 name, shownScans, perMin(orderChanges, span), invScans, shownScans, perMin(flatChanges, span)))
    if expanded != nil {
        print(String(format: "    expanded app %d: visible top-5 process order chg/min %.1f, set chg/min %.1f, Finished in top 2: %d scans, Finished printing 0: %d scans",
                     expanded!, perMin(kidOrder, span), perMin(kidSet, span), finishedTop, finishedZero))
    }
}

/// The pointer rests on the 2nd app row from `from` s on (moved, so frozen). `knowsRow` true = the row
/// is known (partial freeze down to it); false = unknown (full freeze).
@MainActor func resting(_ name: String, _ scans: [Scan], metric: BreakdownMetric, knowsRow: Bool, from: Double = 30) {
    let store = MetricsStore()
    store.beginBreakdown(metric: metric)
    var hovered: Int32?
    var inside = false
    store.breakdownPointerProbe = { BreakdownPointer(inside: inside, moved: inside, app: knowsRow ? hovered : nil) }
    let base = 800_000_000.0
    var frozenScans = 0, moved = 0, stuck = 0, belowChanges = 0
    var lastPrefix: [Int32]?, lastBelow: [Int32]?
    for s in scans {
        if !inside, s.t >= from, store.breakdown.count > 2 { inside = true; hovered = store.breakdown[1].appPID }
        store.setBreakdown(s.apps, measuring: s.measuring, totalCPU: s.total, time: base + s.t)
        guard inside, !store.breakdownMeasuring, let h = hovered else { continue }
        let ids = store.breakdown.map(\.appPID)
        guard let at = ids.firstIndex(of: h) else { continue }
        frozenScans += 1
        let prefix = Array(ids.prefix(at + 1)), below = Array(ids.dropFirst(at + 1).prefix(8))
        if let l = lastPrefix, l != prefix { moved += 1 }
        if let l = lastBelow, l != below { belowChanges += 1 }
        lastPrefix = prefix; lastBelow = below
        let shown = store.breakdown.prefix(10).map { store.shownValue(app: $0.appPID) ?? $0.value(for: metric) }
        var big = false
        for i in 1..<max(1, shown.count) where shown[i] > 2 * shown[i - 1]
            && shown[i] - shown[i - 1] > 4 * breakdownValueStep(metric, shown[i]) { big = true }
        if big { stuck += 1 }
    }
    print(String(format: "[%@] pointer resting on the 2nd app from t=%.0f, row %@: %d frozen scans, rows at/above the pointer moved %d, order below changed %d, scans with a row > 2x the one above %d",
                 name, from, knowsRow ? "known (partial freeze)" : "unknown (full freeze)", frozenScans, moved,
                 belowChanges, stuck))
}

MainActor.assumeIsolated {
    for (name, metric) in [("cpuB8", BreakdownMetric.cpu), ("cpuB8slow", .cpu), ("energyB16", .energy), ("memB", .memory)] {
        guard only.isEmpty || only.contains(name), let arr = json[name] as? [[String: Any]] else { continue }
        let scans = decode(arr)
        away(name, scans, metric: metric)
        resting(name, scans, metric: metric, knowsRow: true)
        resting(name, scans, metric: metric, knowsRow: false)
    }
}

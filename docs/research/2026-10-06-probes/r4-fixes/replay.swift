// Replays recorded breakdown scan results (rec/main.swift) through the REAL MetricsStore +
// BreakdownDisplay of whatever sources this is compiled with, and prints both round-3 reviewers'
// steadiness measures. Usage: replay <rec.json> [variant ...]
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

struct Track {
    var last: String?, prev: String?, changes = 0, flips = 0
    mutating func see(_ s: String) {
        if let l = last, l != s { changes += 1; if s == prev { flips += 1 }; prev = l }
        last = s
    }
}

func flatten(_ apps: [AppUsage], expanded: Int32?, visible: Int = 5) -> [String] {
    var rows: [String] = []
    for app in apps {
        rows.append("a\(app.appPID)")
        guard app.appPID == expanded, app.processes.count > 1 else { continue }
        for p in app.processes.prefix(visible) { rows.append("p\(p.pid)") }
        if app.processes.count > visible { rows.append("m\(app.appPID)") }
    }
    return rows
}

let burstPID = Int32((json["burst"] as? [String: Any])?["pid"] as? Int ?? -99)
let burstStart = (json["burst"] as? [String: Any])?["start"] as? Double ?? -1

@MainActor func run(_ name: String, _ scans: [Scan], metric: BreakdownMetric, still: Bool) {
    let store = MetricsStore()
    store.beginBreakdown(metric: metric)
    store.breakdownPointerProbe = { BreakdownPointer(inside: still, moved: !still) }
    let base = 800_000_000.0
    var shownScans = 0
    var firstShownT: Double?
    var lastTop8: [Int32]?, lastFlat: [String]?
    var orderChanges = 0, slotChanges = 0, flatSlotChanges = 0, firstResort: Int?, invScans = 0, missorts = 0
    var texts: [Int32: Track] = [:]
    var expanded: Int32?, lastExpIndex: Int?, expMoves = 0, childOrder = 0, lastKids: [Int32]?
    var childTexts: [Int32: Track] = [:]
    var errSteps: [Double] = []
    var topRowChanges: [Double] = []
    var collapses = 0
    for s in scans {
        store.setBreakdown(s.apps, measuring: s.measuring, totalCPU: s.total, time: base + s.t)
        guard !store.breakdownMeasuring else { continue }
        shownScans += 1
        if firstShownT == nil { firstShownT = s.t }
        let rows = store.breakdown
        let ids = rows.map(\.appPID)
        if !still, metric != .memory, burstStart >= 0, s.t >= burstStart - 2, s.t <= burstStart + 20,
           let app = rows.first(where: { $0.processes.contains { $0.pid == burstPID } }) {
            let v = store.shownValue(app: app.appPID, pid: burstPID) ?? -1
            print(String(format: "    BURST t+%.1f row %@ header %@", s.t - burstStart, breakdownValueText(metric, v),
                         store.breakdownShownTotalCPU.map { String(format: "%.0f", $0) } ?? "-"))
        }
        if shownScans == 1, !still {
            expanded = rows.prefix(8).filter { $0.processes.count > 1 && $0.isApp }
                .max { $0.processes.count < $1.processes.count }?.appPID
        }
        if let e = expanded, (rows.first { $0.appPID == e }?.processes.count ?? 0) <= 1 { expanded = nil; collapses += 1 }
        let top8 = Array(ids.prefix(8))
        let flat = Array(flatten(rows, expanded: expanded).prefix(14))
        if let l = lastTop8 {
            let slots = zip(l, top8).filter { $0 != $1 }.count + abs(l.count - top8.count)
            if l != top8 { orderChanges += 1; if still, l.first != top8.first { topRowChanges.append(s.t) } }
            slotChanges += slots
            if firstResort == nil { firstResort = slots }
        }
        if let lf = lastFlat { flatSlotChanges += zip(lf, flat).filter { $0 != $1 }.count }
        lastTop8 = top8; lastFlat = flat
        let shown = rows.prefix(8).map { store.shownValue(app: $0.appPID) ?? $0.value(for: metric) }
        var inv = false
        for i in 1..<max(1, shown.count) {
            if metric == .memory, (rows[i].appPID < 0) != (rows[i - 1].appPID < 0) { continue }
            if breakdownValueText(metric, shown[i]) != breakdownValueText(metric, shown[i - 1]), shown[i] > shown[i - 1] { inv = true }
            let a = shown[i - 1], b = shown[i]
            if b > a * 1.25, b - a > 2 * breakdownValueStep(metric, b) { missorts += 1 }
        }
        if inv { invScans += 1 }
        for (i, app) in rows.prefix(8).enumerated() {
            texts[app.appPID, default: Track()].see(breakdownValueText(metric, shown[i]))
            let exact = app.value(for: metric)
            errSteps.append(abs(shown[i] - exact) / breakdownValueStep(metric, exact))
        }
        if let e = expanded, let idx = ids.firstIndex(of: e), let app = rows.first(where: { $0.appPID == e }) {
            if let li = lastExpIndex, li != idx { expMoves += 1 }
            lastExpIndex = idx
            let kids = Array(app.processes.prefix(5).map(\.pid))
            if let lk = lastKids, lk != kids { childOrder += 1
                if ProcessInfo.processInfo.environment["DBG"] != nil, childOrder <= 6 {
                    print("      t=\(s.t) app \(e) kids \(lk) -> \(kids) vals " + app.processes.prefix(6).map { "\($0.pid):" + breakdownValueText(metric, store.shownValue(app: e, pid: $0.pid) ?? -1) }.joined(separator: " "))
                }
            }
            lastKids = kids
            for p in app.processes.prefix(5) {
                childTexts[p.pid, default: Track()].see(breakdownValueText(metric, store.shownValue(app: e, pid: p.pid) ?? 0))
            }
        }
    }
    let span = (scans.last?.t ?? 0) - (firstShownT ?? 0)
    let m = max(span, 1) / 60
    let tc = texts.values.reduce(0) { $0 + $1.changes }, tf = texts.values.reduce(0) { $0 + $1.flips }
    let cc = childTexts.values.reduce(0) { $0 + $1.changes }
    let e = errSteps.sorted()
    let rowsTracked = max(1, texts.values.filter { $0.last != nil }.count)
    print(String(format: "[%@%@] first shown t=%.1f, %d scans | first re-sort slots %d | top-8 order chg/min %.1f, slot chg/min %.1f, flat(14) slot chg/min %.1f",
                 name, still ? " still" : "", firstShownT ?? -1, shownScans, firstResort ?? -1,
                 Double(orderChanges) / m, Double(slotChanges) / m, Double(flatSlotChanges) / m))
    print(String(format: "    inversion scans %d/%d, missorted pairs %d | top-8 text chg/min %.1f (flip-backs %.1f), s between changes per row %.1f | err steps p95 %.2f max %.2f",
                 invScans, shownScans, missorts, Double(tc) / m, Double(tf) / m,
                 Double(rowsTracked) * span / Double(max(1, tc)), e.isEmpty ? 0 : e[Int(Double(e.count) * 0.95)], e.last ?? 0))
    if still {
        print("    top row changed at t = \(topRowChanges.map { String(format: "%.1f", $0) })")
    } else if expanded != nil || collapses > 0 {
        print(String(format: "    expanded app moves/min %.1f, child top-5 order chg/min %.1f, child text chg/min %.1f, collapses %d",
                     Double(expMoves) / m, Double(childOrder) / m, Double(cc) / m, collapses))
    }
}

/// Reviewer B's round-4 synthetic contention test: 10 apps with close means, bursty per-2 s readings
/// averaged over the last 4 scans (8 s), 20 simulated minutes through the real store, pointer away.
@MainActor func synthetic() {
    let means: [Double] = [6.0, 5.6, 5.2, 3.1, 2.9, 1.6, 1.5, 1.0, 0.6, 0.5]
    for cv in [0.6, 0.3] {
        var rng = SystemRandomNumberGenerator()
        func gauss() -> Double {
            let u1 = Double.random(in: 1e-9..<1, using: &rng), u2 = Double.random(in: 0..<1, using: &rng)
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
        let store = MetricsStore()
        store.beginBreakdown(metric: .cpu)
        store.breakdownPointerProbe = { BreakdownPointer(inside: false, moved: false) }
        var hist: [[Double]] = Array(repeating: [], count: means.count)
        var last: [Int32]?
        var changes = 0, inv = 0, scans = 0
        var pairRun: [String: Int] = [:], longest = 0
        let n = 600
        for i in 0..<n {
            var apps: [AppUsage] = []
            for (k, m) in means.enumerated() {
                hist[k].append(max(0, m * (1 + cv * gauss())))
                if hist[k].count > 4 { hist[k].removeFirst() }
                let v = hist[k].reduce(0, +) / Double(hist[k].count)
                let pid = Int32(k + 1)
                apps.append(AppUsage(appPID: pid, processes: [ProcessUsage(pid: pid, appPID: pid, cpuPercent: v, memoryBytes: 0)],
                                     cpuPercent: v, memoryBytes: 0))
            }
            apps.sort { $0.cpuPercent > $1.cpuPercent }
            store.setBreakdown(apps, measuring: false, totalCPU: 40, time: Double(2 * i))
            let rows = store.breakdown
            let top8 = Array(rows.prefix(8).map(\.appPID))
            if let last, last != top8 { changes += 1 }
            last = top8
            scans += 1
            let shown = rows.prefix(8).map { store.shownValue(app: $0.appPID) ?? $0.cpuPercent }
            var any = false
            var now: Set<String> = []
            for j in 1..<shown.count where breakdownValueText(.cpu, shown[j]) != breakdownValueText(.cpu, shown[j - 1]) && shown[j] > shown[j - 1] {
                any = true
                let key = "\(rows[j - 1].appPID)-\(rows[j].appPID)"
                now.insert(key)
                pairRun[key, default: 0] += 1
                longest = max(longest, pairRun[key]!)
            }
            for k in pairRun.keys where !now.contains(k) { pairRun[k] = 0 }
            if any { inv += 1 }
        }
        print(String(format: "synthetic CV %.1f: top-8 order changes/min %.1f, inversion scans %d/%d (%.0f%%), longest pair inversion %d scans",
                     cv, Double(changes) / (Double(n) * 2 / 60), inv, scans, 100 * Double(inv) / Double(scans), longest))
    }
}

/// The CPU card rule (MetricsStore.updateCards) with a configurable "big move".
func card(_ series: [[Double]], bigMove: Double, dwell: Double = cardDwellSeconds) {
    var shown: Double?, changedAt: Double?
    var tr = Track(), errs: [Double] = []
    for p in series {
        let (t, v) = (p[0], p[1])
        let next = heldValue(shown: shown, value: v, step: 1, band: 1.25)
        if shown == nil { shown = next }
        else if next != shown!, dwellAllows(since: changedAt, now: t, dwell: dwell, bigMove: abs(v - shown!) >= bigMove) {
            shown = next; changedAt = t
        }
        tr.see("\(Int(shown!))"); errs.append(abs(shown! - v))
    }
    let m = ((series.last?[0] ?? 0) - (series.first?[0] ?? 0)) / 60
    let e = errs.sorted()
    print(String(format: "card bigMove %.0f dwell %.1f: changes/min %.1f flip-backs/min %.1f | err p95 %.2f max %.2f",
                 bigMove, dwell, Double(tr.changes) / m, Double(tr.flips) / m, e[Int(Double(e.count) * 0.95)], e.last!))
}

MainActor.assumeIsolated {
    if only.contains("synthetic") { synthetic(); return }
    for (name, metric) in [("cpuB8", BreakdownMetric.cpu), ("cpuB8slow", .cpu), ("energyB16", .energy),
                           ("energyB16slow", .energy), ("memB", .memory)] {
        guard only.isEmpty || only.contains(name), let arr = json[name] as? [[String: Any]] else { continue }
        let scans = decode(arr)
        run(name, scans, metric: metric, still: false)
        if metric != .memory { run(name, scans, metric: metric, still: true) }
    }
    if only.isEmpty || only.contains("card"), let series = json["card"] as? [[Double]] {
        for b in [2.0, 3, 4, 5] { card(series, bigMove: b) }
        card(series, bigMove: 3, dwell: 3)
    }
}

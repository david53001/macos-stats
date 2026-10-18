import Foundation
struct R { let t: Double; let ac: Bool; let mV: Int; let mAh: Int; let maxMAh: Int; let passed: Int; let sysW: Double; let instMA: Int }
let text = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
var rows: [R] = []
for line in text.split(separator: "\n") {
    let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard f.count >= 9, let t = Double(f[0]), let mV = Int(f[3]), let mAh = Int(f[4]), let mx = Int(f[5]), let p = Int(f[6]) else { continue }
    rows.append(R(t: t, ac: f[1] == "1", mV: mV, mAh: mAh, maxMAh: mx, passed: p, sysW: Double(f[7]) ?? 0, instMA: Int(f[8]) ?? 0))
}
// Intervals: consecutive on-battery readings ≤180 s apart. watts from coulomb counter.
struct I { let t: Double; let dt: Double; let w: Double; let wh: Double; let sysW: Double; let session: Int }
var intervals: [I] = []
var session = 0
var prev: R?
for r in rows {
    defer { prev = r }
    guard !r.ac else { prev = nil; session += 1; continue }
    guard let p = prev, !p.ac else { session += 1; continue }
    let dt = r.t - p.t
    guard dt > 0, dt <= 180 else { continue }   // sleep: rebase
    let dq = Double(r.passed - p.passed)          // mAh drained
    guard dq >= 0 else { continue }
    let w = dq / 1000 * Double(r.mV + p.mV) / 2000 * 3600 / dt
    intervals.append(I(t: r.t, dt: dt, w: w, wh: w * dt / 3600, sysW: r.sysW, session: session))
}
// Replay the estimator, at each interval end compute expected watts; score vs next 60 awake minutes.
var est = BatteryEstimator()
var lastSession = -1
struct P { let typ: Double; let sessW: Double; let i: Int; let exp: Double; let inst: Double; let mins: Int?; let instMins: Double; let remWh: Double; let sess: Int; let t: Double }
var preds: [P] = []
// map interval index to the reading for remainingWh
var readingAt: [Double: R] = [:]
for r in rows { readingAt[r.t] = r }
for (k, iv) in intervals.enumerated() {
    if iv.session != lastSession { est.endSession(); lastSession = iv.session }
    est.ingest(watts: iv.w, seconds: iv.dt)
    guard let r = readingAt[iv.t] else { continue }
    let tel = BatteryTelemetry(updateTime: Int(iv.t), voltageMV: r.mV, currentMAh: r.mAh)
    guard let wh = tel.remainingWh, let e = est.expectedWatts else { continue }
    let m = est.minutesLeft(remainingWh: wh, macOSMinutes: nil)
    preds.append(P(typ: est.typicalWatts ?? e, sessW: est.sessionAverageWatts ?? e, i: k, exp: e, inst: iv.sysW, mins: m, instMins: wh / max(0.3, iv.sysW) * 60, remWh: wh, sess: iv.session, t: iv.t))
}
func future(_ k: Int, _ horizon: Double) -> Double? {
    var e = 0.0, s = 0.0, j = k + 1
    while j < intervals.count, intervals[j].session == intervals[k].session, s < horizon { e += intervals[j].wh; s += intervals[j].dt; j += 1 }
    return s >= horizon * 0.95 ? e * 3600 / s : nil
}
func restOfSession(_ k: Int) -> (Double, Double)? {
    var e = 0.0, s = 0.0, j = k + 1
    while j < intervals.count, intervals[j].session == intervals[k].session { e += intervals[j].wh; s += intervals[j].dt; j += 1 }
    return s >= 1800 ? (e * 3600 / s, s) : nil
}
for horizon in [3600.0, 7200.0] {
    var errM = [Double](), errI = [Double](), errSess = [Double]()
    for p in preds { if let a = future(p.i, horizon), a > 0 {
        errM.append(log(p.exp / a)); errI.append(log(max(0.3, p.inst) / a))
    } }
    func stats(_ x: [Double]) -> String {
        let n = Double(x.count); let mae = x.map { abs($0) }.reduce(0,+)/n; let bias = x.reduce(0,+)/n
        let sorted = x.map { abs($0) }.sorted(); let p90 = sorted[Int(Double(sorted.count) * 0.9)]
        let within20 = Double(x.filter { abs($0) < log(1.2) }.count) / n
        return String(format: "n=%d mean|log|=%.0f%% bias=%+.0f%% p90=%.0f%% within±20%%=%.0f%%", x.count, mae*100, bias*100, p90*100, within20*100)
    }
    print("horizon \(Int(horizon/60)) min — MacStats expected W vs actual:", stats(errM))
    var eT = [Double](), eS = [Double]()
    for p in preds { if let a = future(p.i, horizon), a > 0 { eT.append(log(p.typ / a)); eS.append(log(p.sessW / a)) } }
    print("horizon \(Int(horizon/60)) min — typical-only:", stats(eT)); print("horizon \(Int(horizon/60)) min — session-mean:", stats(eS))
    print("horizon \(Int(horizon/60)) min — instantaneous SystemPower (macOS-like) vs actual:", stats(errI))
}
// rest of session
var e1 = [Double](), e2 = [Double]()
for p in preds { if let (a, _) = restOfSession(p.i) { e1.append(log(p.exp / a)); e2.append(log(max(0.3,p.inst)/a)) } }
let mae = { (x: [Double]) in x.map{abs($0)}.reduce(0,+)/Double(x.count) }
print(String(format: "rest of session (≥30 min left): MacStats mean|log|=%.0f%% bias %+.0f%%  instant mean|log|=%.0f%%  n=%d", mae(e1)*100, e1.reduce(0,+)/Double(e1.count)*100, mae(e2)*100, e1.count))
// stability: change in minutes shown per ~10 awake minutes
var moves = [Double]()
for (a, b) in zip(preds, preds.dropFirst(10)) where a.sess == b.sess { if let x = a.mins, let y = b.mins, x > 0 { moves.append(abs(Double(y - x)) / Double(x)) } }
moves.sort(); print(String(format: "time-left move per 10 readings: median %.0f%% mean %.0f%% p90 %.0f%%", moves[moves.count/2]*100, moves.reduce(0,+)/Double(moves.count)*100, moves[Int(Double(moves.count)*0.9)]*100))
// overall drain stats
let totW = intervals.reduce(0.0) { $0 + $1.wh } * 3600 / intervals.reduce(0.0) { $0 + $1.dt }
print(String(format: "awake on-battery: %.1f h, mean %.2f W, sessions %d, final typical %.2f W", intervals.reduce(0.0){$0+$1.dt}/3600, totW, Set(intervals.map{$0.session}).count, est.typicalWatts ?? 0))
// coulomb vs SystemPower sanity
let sysMean = intervals.reduce(0.0) { $0 + $1.sysW * $1.dt } / intervals.reduce(0.0) { $0 + $1.dt }
print(String(format: "SystemPower time-mean %.2f W vs coulomb %.2f W", sysMean, totW))
// sample of predictions per session start for the report
for s in Set(preds.map { $0.sess }).sorted() { let ps = preds.filter { $0.sess == s }; guard ps.count > 30 else { continue }
  let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
  let line = stride(from: 0, to: ps.count, by: max(1, ps.count/6)).map { j -> String in let p = ps[j]; let a = restOfSession(p.i).map { String(format: "%.1f", $0.0) } ?? "-"; return "\(f.string(from: Date(timeIntervalSince1970: p.t))) exp \(String(format: "%.1f", p.exp))W act(rest) \(a)W shown \(p.mins.map{"\($0/60)h\($0%60)m"} ?? "-")" }
  print("session \(s) (\(ps.count) rdgs):", line.joined(separator: " | ")) }

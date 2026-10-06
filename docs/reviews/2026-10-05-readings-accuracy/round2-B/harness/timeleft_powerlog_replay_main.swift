import Foundation
// Replays this Mac's powerlog on-battery history through BatteryEstimator (the app's time-left model)
// and compares its assumed draw with the drain that actually followed (from the gauge's charge counter).
struct Row { let t: Double; let level: Double; let rc: Double; let rm: Double; let v: Double; let ia: Double; let ec: Bool }
var rows: [Row] = []
for line in try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(separator: "\n") {
    let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard f.count >= 7, let t = Double(f[0]), let rc = Double(f[2]), let rm = Double(f[3]), let v = Double(f[4]), let ia = Double(f[5]) else { continue }
    rows.append(Row(t: t, level: Double(f[1]) ?? 0, rc: rc, rm: rm, v: v, ia: ia, ec: f[6] == "1"))
}
let horizon = Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "60")! * 60
var est = BatteryEstimator()
var prev: Row?
var onBattery = false
// awake on-battery timeline: (row index, cumulative awake seconds in session, session id)
var timeline: [(i: Int, awake: Double, sess: Int)] = []
var preds: [(i: Int, awake: Double, sess: Int, expW: Double?, minutes: Int?, instW: Double, sessMean: Double?)] = []
var sess = 0, awake = 0.0, lastPredAwake = -1e9
for (i, r) in rows.enumerated() {
    if r.ec { if onBattery { est.endSession() }; onBattery = false; prev = r; continue }
    if !onBattery { onBattery = true; sess += 1; awake = 0; lastPredAwake = -1e9; prev = r; timeline.append((i, 0, sess)); continue }
    let dt = r.t - prev!.t
    if dt > 0, dt <= maxGaugeInterval {
        let w = r.v * abs(r.ia) / 1e6
        est.ingest(watts: w, seconds: dt)
        awake += dt
    }
    timeline.append((i, awake, sess))
    if awake - lastPredAwake >= 600, awake >= 600 {
        let remWh = r.rc * ((r.v/1000) + 3.5 * ((r.v/1000)/4.45).rounded(.up)) / 2 / 1000
        preds.append((i, awake, sess, est.expectedWatts, est.minutesLeft(remainingWh: remWh, macOSMinutes: nil), r.v * abs(r.ia) / 1e6, est.sessionAverageWatts))
        lastPredAwake = awake
    }
    prev = r
}
// realized drain over the next `horizon` awake seconds of the same session (charge counter × voltage)
var errs: [Double] = [], errsInst: [Double] = [], errsMean: [Double] = []
print("time            sess awake(min) level  assumed(W)  realized next \(Int(horizon/60))min (W)  ratio   [inst ratio, session-mean ratio]")
for p in preds {
    guard let k = timeline.firstIndex(where: { $0.sess == p.sess && $0.awake >= p.awake + horizon }) else { continue }
    let a = rows[p.i], b = rows[timeline[k].i]
    // ratio rc/rm smooths the gauge's re-estimates of both numbers
    let fullMAh = (a.rm + b.rm) / 2
    let dmAh = (a.rc / a.rm - b.rc / b.rm) * fullMAh
    let realizedW = dmAh * ((a.v + b.v) / 2 / 1000) / 1000 / ((timeline[k].awake - p.awake) / 3600)
    guard realizedW > 0.3, let e = p.expW else { continue }
    errs.append(e / realizedW); errsInst.append(p.instW / realizedW); if let m = p.sessMean { errsMean.append(m / realizedW) }
    let df = DateFormatter(); df.dateFormat = "MM-dd HH:mm"
    print(String(format: "%@  %2d  %6.0f   %5.1f   %6.2f        %6.2f             %5.2f   [%5.2f, %5.2f]", df.string(from: Date(timeIntervalSince1970: a.t)), p.sess, p.awake/60, a.level, e, realizedW, e/realizedW, p.instW/realizedW, (p.sessMean ?? 0)/realizedW))
}
func stats(_ x: [Double]) -> String {
    let s = x.sorted(); guard !s.isEmpty else { return "n=0" }
    let mape = x.map { abs($0 - 1) }.reduce(0, +) / Double(x.count)
    let bias = x.reduce(0, +) / Double(x.count) - 1
    return String(format: "n=%d  mean|err|=%.0f%%  bias=%+.0f%%  median ratio=%.2f  p10=%.2f p90=%.2f  within±20%%: %.0f%%", x.count, mape*100, bias*100, s[s.count/2], s[s.count/10], s[s.count*9/10], Double(x.filter { abs($0-1) <= 0.2 }.count) / Double(x.count) * 100)
}
print("MacStats estimator : " + stats(errs))
print("last-minute instant: " + stats(errsInst))
print("session mean       : " + stats(errsMean))

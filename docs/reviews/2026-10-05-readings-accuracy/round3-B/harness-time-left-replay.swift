import Foundation
// Replays the app's time-left pipeline over every on-battery stretch of the powerlog.
struct R { let t: Double; let level: Double; let mAh: Int; let full: Int; let mV: Int; let mA: Int; let ac: Int; let q: Int }
let lines = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(separator: "\n")
let rows: [R] = lines.compactMap { l in
  let f = l.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
  guard f.count >= 10, let q = Int(f[9]), let t = Double(f[0]), let lv = Double(f[1]), let m = Int(f[2]), let fu = Int(f[3]), let v = Int(f[4]), let a = Int(f[5]), let ac = Int(f[6]) else { return nil }
  return R(t: t, level: lv, mAh: m, full: fu, mV: v, mA: a, ac: ac, q: q)
}
// Sessions: consecutive on-battery rows (ac==0); a plug-in ends a session.
var sessions: [[R]] = []; var cur: [R] = []
for r in rows { if r.ac == 0 { cur.append(r) } else { if cur.count > 1 { sessions.append(cur) }; cur = [] } }
if cur.count > 1 { sessions.append(cur) }
let startTypical = Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "0")!
var est = BatteryEstimator(typicalWatts: startTypical > 0 ? startTypical : nil, typicalSeconds: startTypical > 0 ? 36000 : 0)
var allErr60: [Double] = [], allErr120: [Double] = [], allErrRest: [Double] = []
var shownSeries: [(Double, Int)] = []
var baseConst: [Double] = [], baseTrail: [Double] = [], baseOur: [Double] = []
for (si, s) in sessions.enumerated() {
  est.endSession()
  // awake intervals: dt<=180; drain watts from Δraw mAh × avg V
  var points: [(t: Double, shownMin: Int?, wh: Double, expW: Double?)] = []
  var awake: [(t0: Double, t1: Double, wh: Double)] = []
  for i in 0..<s.count {
    if i > 0 {
      let a = s[i-1], b = s[i]
      let dt = b.t - a.t
      let dmAh = Double(b.q - a.q) // coulomb counter, positive when draining
      let v = Double(a.mV + b.mV) / 2000
      let prevGap = i > 1 ? s[i-1].t - s[i-2].t : 0
      if dt >= 20 && dt <= maxGaugeInterval && prevGap <= maxGaugeInterval && dmAh >= 0 {
        let wh = dmAh * v / 1000
        awake.append((a.t, b.t, wh))
        let w = wh * 3600 / dt
        if w > 0 { est.ingest(watts: w, seconds: dt) }
      }
    }
    let tel = BatteryTelemetry(updateTime: Int(s[i].t), voltageMV: s[i].mV, currentMAh: s[i].mAh)
    let m = est.minutesLeft(remainingWh: tel.remainingWh!, macOSMinutes: nil)
    points.append((s[i].t, m, tel.remainingWh!, est.expectedWatts))
  }
  // actual drain over the next H seconds of awake time
  func futureW(from t: Double, horizon: Double) -> Double? {
    var sec = 0.0, wh = 0.0
    for a in awake where a.t0 >= t { sec += a.t1 - a.t0; wh += a.wh; if sec >= horizon { break } }
    return sec >= 0.95 * horizon ? wh * 3600 / sec : nil
  }
  func restW(from t: Double) -> (Double, Double)? {
    var sec = 0.0, wh = 0.0
    for a in awake where a.t0 >= t { sec += a.t1 - a.t0; wh += a.wh }
    return sec >= 1800 ? (wh * 3600 / sec, sec) : nil
  }
  var e60: [Double] = [], e120: [Double] = []
  for p in points {
    guard let m = p.shownMin else { continue }
    shownSeries.append((p.t, m))
    if let w = futureW(from: p.t, horizon: 3600) { let honest = p.wh / w * 60; e60.append(Double(m)/honest - 1) }
    if let w = futureW(from: p.t, horizon: 7200) { let honest = p.wh / w * 60; e120.append(Double(m)/honest - 1)
      baseOur.append(Double(m)/honest - 1)
      baseConst.append((p.wh / 4.375 * 60)/honest - 1)
      var sec = 0.0, wh = 0.0
      for a in awake.reversed() where a.t1 <= p.t { sec += a.t1 - a.t0; wh += a.wh; if sec >= 600 { break } }
      if sec > 0, wh > 0 { baseTrail.append((p.wh / (wh*3600/sec) * 60)/honest - 1) } }
    if let (w, _) = restW(from: p.t) { allErrRest.append(Double(m)/(p.wh / w * 60) - 1) }
  }
  allErr60 += e60; allErr120 += e120
  let dur = (s.last!.t - s.first!.t)/60
  let df = DateFormatter(); df.dateFormat = "MM-dd HH:mm"
  let mean = { (x: [Double]) -> String in x.isEmpty ? "-" : String(format: "%+.0f%%", x.reduce(0,+)/Double(x.count)*100) }
  let mae = { (x: [Double]) -> String in x.isEmpty ? "-" : String(format: "%.0f%%", x.map(abs).reduce(0,+)/Double(x.count)*100) }
  let shown = points.compactMap { $0.shownMin }
  print("S\(si) \(df.string(from: Date(timeIntervalSince1970: s.first!.t))) \(Int(dur))min \(Int(s.first!.level))→\(Int(s.last!.level))% n=\(s.count) shown first/last=\(shown.first.map(String.init) ?? "-")/\(shown.last.map(String.init) ?? "-") typical=\(String(format: "%.2f", est.typicalWatts ?? 0)) err60 bias \(mean(e60)) mae \(mae(e60)) | err120 bias \(mean(e120)) mae \(mae(e120))")
}
func stats(_ n: String, _ x: [Double]) {
  let s = x.sorted(); guard !s.isEmpty else { return }
  let p = { (q: Double) in s[Int(Double(s.count-1)*q)] * 100 }
  print(String(format: "%@: n=%d bias %+.1f%% mae %.1f%% p10 %+.0f%% p50 %+.0f%% p90 %+.0f%% share>+25%%: %.0f%% share<-25%%: %.0f%%", n, s.count, s.reduce(0,+)/Double(s.count)*100, s.map(abs).reduce(0,+)/Double(s.count)*100, p(0.1), p(0.5), p(0.9), Double(s.filter{$0 > 0.25}.count)/Double(s.count)*100, Double(s.filter{$0 < -0.25}.count)/Double(s.count)*100))
}
stats("vs next 60 min", allErr60); stats("vs next 120 min", allErr120); stats("vs rest of session (>=30min)", allErrRest)

stats("baseline ours (same set)", baseOur); stats("baseline constant 4.375W hindsight", baseConst); stats("baseline trailing 10-min", baseTrail)

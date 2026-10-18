import Foundation
// Replays powerlog charging sessions through ChargeCurrent + minutesToTarget (AppModel.refreshBattery .charging branch).
struct Row { let t: Double; let level: Int; let rc: Int; let rm: Int; let ia: Int; let ec: Bool; let ch: Bool }
var rows: [Row] = []
for line in try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(separator: "\n") {
    let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard f.count >= 8, let t = Double(f[0]), let lv = Double(f[1]), let rc = Int(f[2]), let rm = Int(f[3]), let ia = Int(f[5]) else { continue }
    rows.append(Row(t: t, level: Int(lv), rc: rc, rm: rm, ia: ia, ec: f[6] == "1", ch: f[7] == "1"))
}
var i = 0
var errsLimit: [Double] = [], errsFull: [Double] = []
let df = DateFormatter(); df.dateFormat = "MM-dd HH:mm"
while i < rows.count {
    guard rows[i].ch else { i += 1; continue }
    var j = i; while j + 1 < rows.count, rows[j + 1].ch { j += 1 }   // charging run i...j
    let stopRow = j + 1 < rows.count ? rows[j + 1] : nil
    let stopsAt = stopRow.map { $0.t }
    let endLevel = stopRow?.level ?? rows[j].level
    var cur = ChargeCurrent()
    var lastT: Double?
    print("session \(df.string(from: Date(timeIntervalSince1970: rows[i].t))) \(rows[i].level)% -> stops at \(endLevel)% (\(stopRow.map { $0.ec ? "held on AC" : "unplugged" } ?? "-")) after \(Int(((stopsAt ?? rows[j].t) - rows[i].t)/60)) min")
    for k in i...j {
        let r = rows[k]
        let dt = lastT.map { r.t - $0 } ?? 0
        cur.ingest(milliamps: r.ia, seconds: dt <= 180 ? dt : 0)
        lastT = r.t
        guard let mA = cur.milliamps, let stopsAt, stopRow?.ec == true, (k - i) % 5 == 0 else { continue }
        let actual = (stopsAt - r.t) / 60
        let toLimit = minutesToTarget(currentMAh: r.rc, maxMAh: r.rm, chargeMA: mA, targetPercent: endLevel + 0)
        let toFull = minutesToTarget(currentMAh: r.rc, maxMAh: r.rm, chargeMA: mA, targetPercent: 100)
        if let toLimit { errsLimit.append(Double(toLimit) - actual) }
        print(String(format: "   %@ %2d%%  I=%4.0f mA  actual stop in %5.1f min | to %d%% limit: %@ | to full (limit unknown): %@", df.string(from: Date(timeIntervalSince1970: r.t)), r.level, mA, actual, endLevel, toLimit.map { "\($0) min" } ?? "nil", toFull.map { "\($0) min" } ?? "nil"))
    }
    i = j + 1
}
let absErr = errsLimit.map { Swift.abs($0) }
print(String(format: "to-limit error: n=%d mean|err|=%.1f min, bias=%+.1f min, worst=%.0f min", absErr.count, absErr.reduce(0,+)/Double(max(1,absErr.count)), errsLimit.reduce(0,+)/Double(max(1,errsLimit.count)), errsLimit.map { Swift.abs($0) }.max() ?? 0))

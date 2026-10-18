import Foundation
struct R { let t: Double; let ac: Bool; let chg: Bool; let mAh: Int; let maxMAh: Int; let mA: Int; let lvl: Double }
let text = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
var rows: [R] = []
for line in text.split(separator: "\n") {
    let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard f.count >= 10, let t = Double(f[0]), let mAh = Int(f[4]), let mx = Int(f[5]), let lvl = Double(f[9]) else { continue }
    rows.append(R(t: t, ac: f[1] == "1", chg: f[2] == "1", mAh: mAh, maxMAh: mx, mA: Int(f[8]) ?? 0, lvl: lvl))
}
// charging sessions: maximal runs of ac&&chg; end must be followed by an AC not-charging reading at 80/85
var i = 0
var all: [(err: Double, rel: Double, mins: Double)] = []
let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
while i < rows.count {
    guard rows[i].ac && rows[i].chg else { i += 1; continue }
    var j = i; while j + 1 < rows.count, rows[j+1].ac, rows[j+1].chg { j += 1 }
    let end = j + 1 < rows.count ? rows[j+1] : rows[j]
    let stoppedHeld = end.ac && !end.chg && (end.lvl == 85 || end.lvl == 80)
    if stoppedHeld && rows[i].lvl < 80 {
        let target = Int(end.lvl)
        var cc = ChargeCurrent(); var prevT: Double?
        var line: [String] = []
        var errs: [Double] = []
        // replicate app: first reading seeds; subsequent ingest with gauge interval (≤180)
        for k in i...j {
            let r = rows[k]
            let step = prevT.map { r.t - $0 }.flatMap { $0 > 0 && $0 <= 180 ? $0 : nil } ?? 0
            cc.ingest(milliamps: r.mA, seconds: step); prevT = r.t
            guard let ma = cc.milliamps else { continue }
            let actual = (end.t - r.t) / 60
            let shownPct = Int(r.lvl)
            let limit = target >= shownPct ? target : nil   // app: limit kept only while ≥ percent
            guard let p = minutesToTarget(currentMAh: r.mAh, maxMAh: r.maxMAh, chargeMA: ma, targetPercent: limit ?? 100) else { continue }
            errs.append(Double(p) - actual)
            all.append((Double(p) - actual, (Double(p) - actual) / max(1, actual), actual))
            if line.count < 8, k % max(1, (j - i) / 6) == 0 { line.append("\(f.string(from: Date(timeIntervalSince1970: r.t))) \(shownPct)% pred \(p)m act \(Int(actual.rounded()))m") }
        }
        let mae = errs.map { abs($0) }.reduce(0, +) / Double(max(1, errs.count))
        let bias = errs.reduce(0, +) / Double(max(1, errs.count))
        print("charge \(f.string(from: Date(timeIntervalSince1970: rows[i].t))) \(Int(rows[i].lvl))%→\(target)% (\(Int((end.t - rows[i].t)/60)) min): n=\(errs.count) MAE \(String(format: "%.1f", mae)) min bias \(String(format: "%+.1f", bias)) worst \(String(format: "%+.0f", errs.max(by: { abs($0) < abs($1) }) ?? 0))")
        print("   ", line.joined(separator: " | "))
    }
    i = j + 1
}
let n = Double(all.count)
print(String(format: "ALL n=%.0f MAE %.1f min, bias %+.1f, mean |rel| %.0f%%", n, all.map { abs($0.err) }.reduce(0,+)/n, all.map { $0.err }.reduce(0,+)/n, all.map { abs($0.rel) }.reduce(0,+)/n*100))

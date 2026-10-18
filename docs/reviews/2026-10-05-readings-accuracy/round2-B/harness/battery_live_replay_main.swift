import Foundation
// Replays the gauge log through the app's battery pipeline (AppModel.refreshBattery, discharging branch).
let path = CommandLine.arguments[1]
let typicalW = Double(CommandLine.arguments[2])!
let typicalS = Double(CommandLine.arguments[3])!
var est = BatteryEstimator(typicalWatts: typicalW, typicalSeconds: typicalS)
var last: BatteryTelemetry?
func val(_ s: Substring, _ k: String) -> String? {
    for part in s.split(separator: " ") where part.hasPrefix(k + "=") { return String(part.dropFirst(k.count + 1)) }
    return nil
}
func signed(_ s: String?) -> Int? { s.flatMap { UInt64($0) }.map { Int(Int64(bitPattern: $0)) } }
var seen = Set<Int>()
var first: (t: BatteryTelemetry, wall: Int)?
var vaSamples: [(Double, Double)] = []  // (seconds, W)
for line in try! String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
    let head = line.split(separator: "|")[0]
    guard let ut = Int(val(head, "ut") ?? "") , !seen.contains(ut) else { continue }
    seen.insert(ut)
    let d: [String: Any] = [
        "UpdateTime": NSNumber(value: ut), "Voltage": NSNumber(value: Int(val(head, "V")!)!),
        "Amperage": NSNumber(value: UInt64(val(head, "A")!)!),
        "AppleRawCurrentCapacity": NSNumber(value: Int(val(head, "rawCur")!)!),
        "AppleRawMaxCapacity": NSNumber(value: Int(val(head, "rawMax")!)!),
        "NominalChargeCapacity": NSNumber(value: Int(val(head, "nominal")!)!),
        "DesignCapacity": NSNumber(value: 4563), "CycleCount": NSNumber(value: Int(val(head, "cycles")!)!),
        "Temperature": NSNumber(value: Int(val(head, "temp")!)!),
        "PowerTelemetryData": ["SystemLoad": NSNumber(value: Int(val(head, "SL")!)!),
                               "AccumulatedSystemLoad": NSNumber(value: UInt64(val(head, "ASL")!)!),
                               "SystemLoadAccumulatorCount": NSNumber(value: UInt64(val(head, "SLC")!)!)] as [String: Any]]
    let t = parseSmartBattery(d)!
    let macos = Int(val(head, "TimeRemaining")!)
    let iw = intervalWatts(from: last, to: t)
    if let l = last, let secs = gaugeInterval(from: l, to: t), let w = averageWatts(from: l, to: t) {
        est.ingest(watts: w, seconds: secs)
        let va = Double(t.voltageMV!) * Double(-t.amperageMA!) / 1e6
        vaSamples.append((secs, va))
    }
    if first == nil { first = (t, ut) }
    let left = est.minutesLeft(remainingWh: t.remainingWh!, macOSMinutes: macos)
    print(String(format: "ut=%d Power(last min)=%5.2f W  inst=%5.2f  VxA=%5.2f  short=%@ recent=%@ typical=%.2f expected=%@ sessAvg=%@  remWh=%.2f  MacStats left=%@  macOS=%d min  health=%d%% temp=%.0f",
                 ut, iw ?? -1, t.instantWatts ?? -1, Double(t.voltageMV!) * Double(-t.amperageMA!) / 1e6,
                 est.shortWatts.map { String(format: "%.2f", $0) } ?? "-", est.recentWatts.map { String(format: "%.2f", $0) } ?? "-",
                 est.typicalWatts ?? -1, est.expectedWatts.map { String(format: "%.2f", $0) } ?? "-",
                 est.sessionAverageWatts.map { String(format: "%.2f", $0) } ?? "-", t.remainingWh!,
                 left.map { "\($0/60)h\($0%60)m" } ?? "-", macos ?? -1, t.healthPercent ?? -1, t.temperatureC ?? -1))
    last = t
}
if let f = first?.t, let l = last {
    let secs = Double(l.updateTime - f.updateTime)
    let aslW = Double(l.accumulatedSystemLoad! - f.accumulatedSystemLoad!) / Double(l.systemLoadCount! - f.systemLoadCount!) / 1000
    let vaW = vaSamples.reduce(0) { $0 + $1.0 * $1.1 } / vaSamples.reduce(0) { $0 + $1.0 }
    let dWhRaw = (f.remainingWh! - l.remainingWh!)
    print(String(format: "WINDOW %.0f s: mean SystemLoad (gauge sums) = %.2f W; time-weighted V×A = %.2f W; Δ remainingWh = %.2f Wh -> %.2f W; raw mAh %d -> %d",
                 secs, aslW, vaW, dWhRaw, dWhRaw / secs * 3600, f.currentMAh!, l.currentMAh!))
    print(String(format: "time left at window drain (remWh %.2f): ASL %.0f min, VxA %.0f min", l.remainingWh!, l.remainingWh! / aslW * 60, l.remainingWh! / vaW * 60))
}

import Foundation
import IOKit
// Mirrors AppModel.refreshBattery's estimator feed (idle sampler: every 10 s) and logs
// ground-truth accumulators at each gauge update.
setvbuf(stdout, nil, _IOLBF, 0)
let minutes = Double(CommandLine.arguments.dropFirst().first ?? "12")!
let tw = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) : nil
let ts = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3])! : 0
var est = BatteryEstimator(typicalWatts: tw, typicalSeconds: ts)
let reader = SmartBatteryReader()
var last: BatteryTelemetry?
var first: BatteryTelemetry?
let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
func tel(_ k: String) -> [String: Any] { (IORegistryEntryCreateCFProperty(entry, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]) ?? [:] }
func num(_ v: Any?) -> Int64 { (v as? NSNumber).map { Int64(bitPattern: $0.uint64Value) } ?? 0 }
let start = Date()
while Date().timeIntervalSince(start) < minutes * 60 {
    guard var sample = readBattery() else { print("no battery"); break }
    if let t = reader.read(), t.updateTime != last?.updateTime {
        let secs = last.flatMap { gaugeInterval(from: $0, to: t) }
        let iw = intervalWatts(from: last, to: t)
        if sample.state == .discharging, let secs, let w = averageWatts(from: last, to: t) { est.ingest(watts: w, seconds: secs) }
        if first == nil { first = t }
        last = t
        let p = tel("PowerTelemetryData")
        let macOS = sample.timeToEmptyMinutes
        if let wh = t.remainingWh { sample.timeToEmptyMinutes = est.minutesLeft(remainingWh: wh, macOSMinutes: macOS) }
        let vxa = Double(t.voltageMV ?? 0) * Double(-(t.amperageMA ?? 0)) / 1e6
        print(String(format: "upd=%d pct=%d raw=%d V=%d mA=%d VxA=%.2fW sysLoad=%.2fW intervalW=%@ accLoad=%lld cnt=%lld accBatt=%lld battCnt=%lld remWh=%.2f short=%@ recent=%@ typ=%@ sess=%.0fs expected=%@ macStatsLeft=%@ macOSLeft=%@",
                     t.updateTime, sample.percent, t.currentMAh ?? -1, t.voltageMV ?? -1, t.amperageMA ?? 0, vxa, Double(t.systemLoadMW ?? 0) / 1000,
                     iw.map { String(format: "%.2f", $0) } ?? "nil",
                     num(p["AccumulatedSystemLoad"]), num(p["SystemLoadAccumulatorCount"]), num(p["AccumulatedBatteryPower"]), num(p["BatteryPowerAccumulatorCount"]),
                     t.remainingWh ?? -1,
                     est.shortWatts.map { String(format: "%.2f", $0) } ?? "nil", est.recentWatts.map { String(format: "%.2f", $0) } ?? "nil",
                     est.typicalWatts.map { String(format: "%.2f", $0) } ?? "nil", est.sessionSeconds,
                     est.expectedWatts.map { String(format: "%.2f", $0) } ?? "nil",
                     sample.timeToEmptyMinutes.map { "\($0)" } ?? "nil", macOS.map { "\($0)" } ?? "nil"))
    }
    Thread.sleep(forTimeInterval: 10)
}

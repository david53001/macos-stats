import Foundation
// Replicates AppModel.refreshBattery (MacStatsApp.swift:176-234) from a fresh launch with no
// persisted typical drain (the running app's state: its defaults hold no typical yet), polled every 10 s
// like the idle sampler. Optional arg 1: seed typical watts (with arg 2 seconds) to model a persisted prior.
let args = CommandLine.arguments
let seedW = args.count > 1 ? Double(args[1]) : nil
let seedS = args.count > 2 ? Double(args[2])! : 0
let duration = args.count > 3 ? Double(args[3])! : 540
var estimator = BatteryEstimator(typicalWatts: seedW, typicalSeconds: seedS)
let smart = SmartBatteryReader()
var lastTelemetry: BatteryTelemetry?
var lastState: BatteryState?
var peak = RecentMax(capacity: 10)
var peakMAh: Int?
let start = Date()
print("t_s state pct macOS_min remWh instW gaugeAvgW shortW recentW expectedW sessAvgW minutesLeft shown health cycles tempC")
while Date().timeIntervalSince(start) < duration {
    if var sample = readBattery() {
        let state = sample.state
        if state != lastState { lastTelemetry = nil; lastState = state; estimator.endSession() }
        var t = smart.read()
        var gaugeAvg: Double? = nil
        if let t, t.updateTime != lastTelemetry?.updateTime {
            peakMAh = t.nominalMAh.map { peak.add($0) }
            let seconds = lastTelemetry.flatMap { gaugeInterval(from: $0, to: t) }
            if state == .discharging, let seconds, let w = averageWatts(from: lastTelemetry, to: t) {
                estimator.ingest(watts: w, seconds: seconds); gaugeAvg = w
            }
            lastTelemetry = t
        }
        let macOS = sample.timeToEmptyMinutes
        if state == .discharging, let wh = t?.remainingWh {
            sample.timeToEmptyMinutes = estimator.minutesLeft(remainingWh: wh, macOSMinutes: sample.timeToEmptyMinutes)
        }
        if let p = peakMAh { t?.nominalMAh = p }
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "-" }
        let m = sample.timeToEmptyMinutes
        print("\(Int(Date().timeIntervalSince(start))) \(state) \(sample.percent) \(macOS.map(String.init) ?? "-") \(f(t?.remainingWh)) \(f(t?.instantWatts)) \(f(gaugeAvg)) \(f(estimator.shortWatts)) \(f(estimator.recentWatts)) \(f(estimator.expectedWatts)) \(f(estimator.sessionAverageWatts)) \(m.map(String.init) ?? "-") \(m.map { $0 >= 60 ? "\($0/60)h\($0%60)m" : "\($0)m" } ?? "-") \(t?.healthPercent.map(String.init) ?? "-") \(t?.cycleCount.map(String.init) ?? "-") \(f(t?.temperatureC))")
        fflush(stdout)
    }
    Thread.sleep(forTimeInterval: 10)
}

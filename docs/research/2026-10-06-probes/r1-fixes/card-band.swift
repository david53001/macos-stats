import Foundation
// Same CPU series (0.5 s ticks, 2 s trailing window), card text changes per minute for several holds.
setvbuf(stdout, nil, _IONBF, 0)
let secs = Double(CommandLine.arguments.dropFirst().first ?? "90") ?? 90
var snaps: [(t: Double, c: CPUTicks)] = []
var series: [Double] = []
let start = Date()
while Date().timeIntervalSince(start) < secs {
    let now = Date().timeIntervalSinceReferenceDate
    snaps.append((now, readCPUTicks()))
    let base = rateBaselineIndex(times: snaps.lazy.map { $0.t }, now: now, window: rateWindowSeconds)
    if base > 0 { snaps.removeFirst(base) }
    if snaps.count > 1 { series.append(cpuBusyPercent(previous: snaps[0].c, current: snaps.last!.c)) }
    Thread.sleep(forTimeInterval: 0.5)
}
let minutes = Double(series.count) * 0.5 / 60
func run(band: Double, minGapTicks: Int = 0) -> (changes: Double, flips: Int, maxErr: Double) {
    var shown: Double? = nil, changes = 0, flips = 0, maxErr = 0.0, last = -100
    var history: [Double] = []
    for (i, v) in series.enumerated() {
        var next = heldValue(shown: shown, value: v, step: 1, band: band)
        if let s = shown, next != s, i - last < minGapTicks { next = s }
        if let s = shown, next != s {
            changes += 1; last = i
            if history.count >= 2, history[history.count - 2] == next { flips += 1 }
        }
        if shown == nil || next != shown { history.append(next) }
        shown = next
        maxErr = max(maxErr, abs(next - v))
    }
    return (Double(changes) / minutes, flips, maxErr)
}
print(String(format: "ticks=%d mean=%.1f%%", series.count, series.reduce(0, +) / Double(series.count)))
for (b, g) in [(0.75, 0), (1.0, 0), (1.25, 0), (1.5, 0), (1.0, 2), (0.75, 2), (1.25, 2)] {
    let r = run(band: b, minGapTicks: g)
    print(String(format: "band=%.2f min_gap=%.1fs  changes/min=%.1f flipbacks=%d max_err=%.2fpp", b, Double(g) * 0.5, r.changes, r.flips, r.maxErr))
}

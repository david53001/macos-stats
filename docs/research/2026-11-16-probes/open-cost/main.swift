// Off-screen CPU probe for the open panel (README.md). Renders the REAL OverviewView and
// BreakdownView with a MetricsStore fed like AppModel feeds it (a `record` every overview /
// breakdown tick, a breakdown scan result every 2 s), in a window at desktop level + 1 that is
// ordered back and never activated, and prints this process's CPU (getrusage) per run.
import AppKit
import SwiftUI
import MacStatsCore

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
let overviewInterval = args.count > 1 ? Double(args[1]) ?? 1 : 1
let breakdownInterval = args.count > 2 ? Double(args[2]) ?? 2 : 2
let runSeconds = 15.0

@MainActor func settle(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
}

func cpuSeconds() -> Double {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
}

@MainActor func makeWindow<V: View>(_ view: V) -> NSWindow {
    let frame = NSRect(x: 0, y: 0, width: Design.panelWidth, height: Design.panelHeight)
    let host = NSHostingView(rootView: view.frame(width: Design.panelWidth, height: Design.panelHeight))
    host.frame = frame
    let fx = NSVisualEffectView(frame: frame)
    fx.material = .popover; fx.state = .active; fx.blendingMode = .behindWindow
    fx.addSubview(host)
    let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
    w.isReleasedWhenClosed = false
    w.contentView = fx
    w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
    w.setFrameOrigin(NSPoint(x: 40, y: 40))
    w.orderBack(nil)
    return w
}

var tickIndex = 0.0
@MainActor func record(_ store: MetricsStore) {
    tickIndex += 1
    let i = tickIndex
    let mem = MemorySample(usedBytes: UInt64(11_000_000_000 + 100_000_000 * sin(i / 3)), totalBytes: 17_179_869_184,
                           pressure: .normal, appBytes: 7_100_000_000, wiredBytes: 2_300_000_000,
                           compressedBytes: 1_800_000_000, compressedDataBytes: 5_200_000_000)
    store.record(cpuPercent: 20 + 10 * sin(i / 4), memory: mem,
                 network: NetworkSample(downBytesPerSec: 100_000 + 80_000 * sin(i / 2), upBytesPerSec: 9_000),
                 time: Date().timeIntervalSinceReferenceDate)
}

@MainActor func makeStore() -> MetricsStore {
    let s = MetricsStore()
    let now = Date().timeIntervalSinceReferenceDate
    for k in 0..<60 {
        let mem = MemorySample(usedBytes: 11_000_000_000, totalBytes: 17_179_869_184, pressure: .normal)
        s.record(cpuPercent: 20 + 8 * sin(Double(k) / 7), memory: mem,
                 network: NetworkSample(downBytesPerSec: 120_000 + 90_000 * sin(Double(k) / 5), upBytesPerSec: 14_000),
                 time: now - 60 + Double(k))
    }
    s.setBattery(BatterySample(percent: 64, state: .discharging, timeToEmptyMinutes: 245))
    s.setCPUTemperature(47)
    s.setTrashBytes(842_000_000)
    return s
}

@MainActor func fakeApps(_ wobble: Double) -> [AppUsage] {
    let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        .prefix(8).map { Int32($0.processIdentifier) }
    let base: [Double] = [9.8, 4.1, 2.4, 1.9, 1.2, 0.8, 0.5, 0.3]
    return running.enumerated().map { i, p in
        let cpu = base[i] * (1 + 0.3 * sin(wobble + Double(i)))
        return AppUsage(appPID: p, processes: [ProcessUsage(pid: p, appPID: p, cpuPercent: cpu, memoryBytes: 500_000_000)],
                        cpuPercent: cpu, memoryBytes: UInt64(2_400_000_000 / (i + 1)), watts: cpu / 8)
    }.sorted { $0.cpuPercent > $1.cpuPercent }
}

/// One run: `seconds` of ticks at `interval` (plus a scan every 2 s for the breakdown). Returns % of one core.
@MainActor func run(_ store: MetricsStore, interval: Double, scans: Bool) -> Double {
    let c0 = cpuSeconds(), t0 = Date()
    var nextTick = t0, nextScan = t0
    while Date().timeIntervalSince(t0) < runSeconds {
        let now = Date()
        if now >= nextTick { record(store); nextTick = now.addingTimeInterval(interval) }
        if scans, now >= nextScan {
            store.setBreakdown(fakeApps(tickIndex), measuring: false, totalCPU: 25)
            nextScan = now.addingTimeInterval(breakdownScanInterval)
        }
        let wake = scans ? min(nextTick, nextScan) : nextTick
        RunLoop.current.run(until: wake)   // one wait per event, no polling
    }
    return (cpuSeconds() - c0) / Date().timeIntervalSince(t0) * 100
}

@MainActor func probeMain() {
    let store = makeStore()
    print(String(format: "cadence overview=%.2fs breakdown=%.2fs, %.0f s per run", overviewInterval, breakdownInterval, runSeconds))

    let ov = makeWindow(OverviewView(store: store, onSelect: { _ in }, onEmptyTrash: {}, onSettings: {}))
    settle(1.5)
    print("overview window occlusion visible:", ov.occlusionState.contains(.visible))
    var overview: [Double] = []
    for _ in 0..<3 { overview.append(run(store, interval: overviewInterval, scans: false)) }
    ov.orderOut(nil); ov.close()

    store.beginBreakdown(metric: .cpu)
    store.setBreakdown(fakeApps(0), measuring: false, totalCPU: 25)
    let bd = makeWindow(BreakdownView(store: store, metric: .cpu, onBack: {}))
    settle(1.5)
    var breakdown: [Double] = []
    for _ in 0..<3 { breakdown.append(run(store, interval: breakdownInterval, scans: true)) }
    bd.orderOut(nil); bd.close()

    let idle = { () -> Double in
        let c0 = cpuSeconds(), t0 = Date(); settle(5)
        return (cpuSeconds() - c0) / Date().timeIntervalSince(t0) * 100
    }()
    func fmt(_ v: [Double]) -> String { v.map { String(format: "%.2f", $0) }.joined(separator: " ") }
    print("overview  process_cpu_pct runs:", fmt(overview), String(format: " mean %.2f", overview.reduce(0, +) / 3))
    print("breakdown process_cpu_pct runs:", fmt(breakdown), String(format: " mean %.2f", breakdown.reduce(0, +) / 3))
    print(String(format: "no window (floor) process_cpu_pct: %.2f", idle))
}

MainActor.assumeIsolated { probeMain() }

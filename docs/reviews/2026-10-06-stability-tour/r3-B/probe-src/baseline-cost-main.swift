import AppKit
import SwiftUI
import MacStatsCore
setvbuf(stdout, nil, _IONBF, 0)
@MainActor func settle(_ s: Double) { let e = Date().addingTimeInterval(s); while Date() < e { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) } }
@MainActor func makeStore() -> MetricsStore {
    let s = MetricsStore(); let now = Date().timeIntervalSinceReferenceDate
    for i in 0..<120 {
        let mem = MemorySample(usedBytes: 12_100_000_000, totalBytes: 17_179_869_184, pressure: .normal)
        s.record(cpuPercent: 18 + 9 * sin(Double(i) / 6) + Double(i % 4), memory: mem,
                 network: NetworkSample(downBytesPerSec: 240_000 + 160_000 * sin(Double(i) / 5), upBytesPerSec: 31_000), time: now - 60 + Double(i) * 0.5)
    }
    s.setBattery(BatterySample(percent: 72, state: .discharging, timeToEmptyMinutes: 312)); s.setCPUTemperature(46); s.setTrashBytes(1_310_000_000)
    return s
}
MainActor.assumeIsolated {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
    func cpuSeconds() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6 }
    let store = makeStore()
    let frame = NSRect(x: 0, y: 0, width: Design.panelWidth, height: Design.panelHeight)
    let host = NSHostingView(rootView: OverviewView(store: store, onSelect: { _ in }, onEmptyTrash: {}, onSettings: {})
        .frame(width: Design.panelWidth, height: Design.panelHeight).clipped().background(PanelBackdrop()))
    host.frame = frame
    let fx = NSVisualEffectView(frame: frame); fx.material = .popover; fx.state = .active; fx.blendingMode = .behindWindow
    fx.wantsLayer = true; fx.layer?.cornerRadius = 16; fx.layer?.cornerCurve = .continuous; fx.layer?.masksToBounds = true
    fx.addSubview(host)
    let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.isReleasedWhenClosed = false; w.contentView = fx
    w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1); w.setFrameOrigin(NSPoint(x: 60, y: 60)); w.orderBack(nil)
    settle(1)
    var i = 0.0; let c0 = cpuSeconds(), t0 = Date()
    while Date().timeIntervalSince(t0) < 20 {
        i += 1
        store.record(cpuPercent: 20 + 10 * sin(i / 4), memory: MemorySample(usedBytes: UInt64(11e9 + 2e8 * sin(i / 3)), totalBytes: 17_179_869_184, pressure: .normal),
                     network: NetworkSample(downBytesPerSec: 100_000 + 80_000 * sin(i / 2), upBytesPerSec: 9_000), time: Date().timeIntervalSinceReferenceDate)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
    print(String(format: "baseline 1ed61cf overview: %.2f %% of a core", (cpuSeconds() - c0) / Date().timeIntervalSince(t0) * 100))
    w.orderOut(nil); w.close()
}

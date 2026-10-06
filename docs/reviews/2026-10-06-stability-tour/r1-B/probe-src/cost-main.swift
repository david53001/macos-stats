import AppKit
import SwiftUI
import MacStatsCore
setvbuf(stdout, nil, _IONBF, 0)
func cpuSeconds() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u)
  return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6 }
MainActor.assumeIsolated {
  let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
  let store = MetricsStore()
  var snaps: [(Date, CPUTicks, NetCounters)] = []
  let total = ProcessInfo.processInfo.physicalMemory
  @MainActor func tick() { let now = Date(); snaps.append((now, readCPUTicks(), readNetCounters()))
    let b = rateBaselineIndex(times: snaps.lazy.map { $0.0.timeIntervalSinceReferenceDate }, now: now.timeIntervalSinceReferenceDate, window: rateWindowSeconds)
    if b > 0 { snaps.removeFirst(b) }
    guard snaps.count > 1 else { return }
    let cpu = cpuBusyPercent(previous: snaps[0].1, current: snaps.last!.1)
    let net = networkThroughput(previous: snaps[0].2, current: snaps.last!.2, secondsElapsed: now.timeIntervalSince(snaps[0].0))
    store.record(cpuPercent: cpu, memory: memorySample(raw: readVMRaw(), totalBytes: total, pressureLevel: readMemoryPressureLevel()), network: net, time: now.timeIntervalSinceReferenceDate) }
  for _ in 0..<130 { tick(); RunLoop.current.run(until: Date().addingTimeInterval(0.01)) } // warm a minute-like history quickly
  let frame = NSRect(x: 0, y: 0, width: 320, height: 404)
  let sn = "MacStatsReviewBCost"; let dd = UserDefaults(suiteName: sn)!; dd.set("existing", forKey: TourKey.audience)
  let tour = TourController(defaults: dd, hasBattery: { true })
  if CommandLine.arguments.count > 1 { tour.start() }
  let host = NSHostingView(rootView: OverviewView(store: store, onSelect: { _ in }, onEmptyTrash: {}, onSettings: {}).frame(width: 320, height: 404)
      .tourHost(tour, showing: true).clipped().background(PanelBackdrop()))
  host.frame = frame
  let fx = NSVisualEffectView(frame: frame); fx.material = .popover; fx.state = .active; fx.blendingMode = .behindWindow; fx.addSubview(host)
  let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
  w.isReleasedWhenClosed = false; w.contentView = fx
  w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1); w.setFrameOrigin(NSPoint(x: 60, y: 60)); w.orderBack(nil)
  RunLoop.current.run(until: Date().addingTimeInterval(1))
  let c0 = cpuSeconds(), t0 = Date()
  while Date().timeIntervalSince(t0) < 20 { tick(); RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
  print(String(format: "open_overview_cpu_pct=%.2f", (cpuSeconds() - c0) / Date().timeIntervalSince(t0) * 100))
  let c1 = cpuSeconds(), t1 = Date()
  w.orderOut(nil)
  while Date().timeIntervalSince(t1) < 10 { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
  print(String(format: "hidden_no_ticks_cpu_pct=%.2f", (cpuSeconds() - c1) / Date().timeIntervalSince(t1) * 100))
  w.close(); UserDefaults.standard.removePersistentDomain(forName: sn)
  try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(sn).plist"))
}

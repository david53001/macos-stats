import AppKit
import SwiftUI
import MacStatsCore

setvbuf(stdout, nil, _IONBF, 0)
nonisolated(unsafe) var probeExpanded: Int32? = nil

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "out"

@MainActor func runProbe() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()

    func pid(_ name: String) -> Int32? {
        NSWorkspace.shared.runningApplications.first { $0.localizedName == name }.map { Int32($0.processIdentifier) }
    }
    let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    let names = ["Code", "Safari", "Finder", "Terminal", "Google Chrome", "JVoice", "BetterScreenshot", "Notes", "Music"]
    var pids: [Int32] = names.compactMap(pid)
    for r in running where pids.count < 7 { let p = Int32(r.processIdentifier); if !pids.contains(p) { pids.append(p) } }
    print("pids", pids)
    let myPID = Int32(getpid())

    @MainActor func store(cpu: Double = 23, battery: BatterySample? = BatterySample(percent: 64, state: .discharging, timeToEmptyMinutes: 245)) -> MetricsStore {
        let s = MetricsStore()
        let now = Date().timeIntervalSinceReferenceDate
        for i in 0..<120 {
            let t = now - 60 + Double(i) * 0.5
            let c = cpu + 8 * sin(Double(i) / 7) + Double(i % 5)
            let mem = MemorySample(usedBytes: 11_200_000_000, totalBytes: 17_179_869_184, pressure: .normal,
                                   appBytes: 7_100_000_000, wiredBytes: 2_300_000_000, compressedBytes: 1_800_000_000,
                                   compressedDataBytes: 5_200_000_000)
            s.record(cpuPercent: c, memory: mem, network: NetworkSample(downBytesPerSec: 120_000 + 90_000 * sin(Double(i) / 5), upBytesPerSec: 14_000), time: t)
        }
        s.setBattery(battery)
        s.setBatteryTelemetry(BatteryTelemetry(updateTime: 0, cycleCount: 212, temperatureC: 31.4), powerWatts: 6.8, averageWatts: 7.4, averageSinceUnplug: true)
        s.setCPUTemperature(47)
        s.setTrashBytes(842_000_000)
        return s
    }

    func apps(_ metric: BreakdownMetric) -> [AppUsage] {
        var out: [AppUsage] = []
        let cpus: [Double] = [9.8, 2.1, 1.4, 0.9, 0.6, 0.4, 0.2]
        for (i, p) in pids.enumerated() {
            let c = cpus[min(i, cpus.count - 1)]
            let n = i == 0 ? 9 : (i == 1 ? 3 : 1)
            let procs = (0..<n).map { k in ProcessUsage(pid: k == 0 ? p : myPID, appPID: p, cpuPercent: c / Double(k + 1) / 2, memoryBytes: UInt64(900_000_000 / (k + 1)), watts: c / 10 / Double(k + 1)) }
            out.append(AppUsage(appPID: p, processes: procs, cpuPercent: c, memoryBytes: UInt64(2_400_000_000 / (i + 1)), watts: c / 8))
        }
        out.append(AppUsage(appPID: BreakdownGroup.otherProcesses, processes: [ProcessUsage(pid: myPID, appPID: BreakdownGroup.otherProcesses, cpuPercent: 0.7, memoryBytes: 300_000_000)], cpuPercent: 0.7, memoryBytes: 300_000_000, watts: 0.05))
        out.append(AppUsage(appPID: BreakdownGroup.system, processes: [ProcessUsage(pid: 0, appPID: BreakdownGroup.system, cpuPercent: 4.2, memoryBytes: 0)], cpuPercent: 4.2, memoryBytes: 0, watts: 0.3))
        return out.sorted { $0.value(for: metric) > $1.value(for: metric) }
    }

    @MainActor func capture<V: View>(_ name: String, dark: Bool, _ view: V) {
        let host = NSHostingView(rootView: view.frame(width: Design.panelWidth, height: Design.panelHeight))
        host.frame = NSRect(x: 0, y: 0, width: Design.panelWidth, height: Design.panelHeight)
        let fx = NSVisualEffectView(frame: host.frame)
        fx.material = .popover; fx.state = .active; fx.blendingMode = .behindWindow
        fx.wantsLayer = true; fx.layer?.cornerRadius = 16; fx.layer?.cornerCurve = .continuous; fx.layer?.masksToBounds = true
        fx.addSubview(host)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
        w.contentView = fx
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        w.setFrameOrigin(NSPoint(x: 40, y: 40))
        w.orderBack(nil)
        for _ in 0..<15 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let id = CGWindowID(w.windowNumber)
        let path = "\(outDir)/\(name)-\(dark ? "dark" : "light").png"
        if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) {
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("wrote", path, img.width, img.height)
        } else { print("capture failed", name) }
        w.orderOut(nil); w.close()
    }

    for dark in [true, false] {
        let s = store()
        capture("overview", dark: dark, OverviewView(store: s, onSelect: { _ in }, onEmptyTrash: {}, onSettings: {}))
        for m in [BreakdownMetric.cpu, .memory, .energy] {
            let b = store(); b.beginBreakdown(metric: m); b.setBreakdown(apps(m), measuring: false, totalCPU: 23)
            capture("breakdown-\(m)", dark: dark, BreakdownView(store: b, metric: m, onBack: {}))
        }
        probeExpanded = pids.first
        let e = store(); e.beginBreakdown(metric: .cpu); e.setBreakdown(apps(.cpu), measuring: false, totalCPU: 23)
        capture("breakdown-cpu-expanded", dark: dark, BreakdownView(store: e, metric: .cpu, onBack: {}))
        probeExpanded = nil
        let ms = store(); ms.beginBreakdown(metric: .cpu); ms.setBreakdown([], measuring: true)
        capture("breakdown-measuring", dark: dark, BreakdownView(store: ms, metric: .cpu, onBack: {}))
        capture("settings", dark: dark, SettingsView(onBack: {}))
        let ch = store(battery: BatterySample(percent: 72, state: .charging, timeToFullMinutes: 38))
        capture("overview-charging", dark: dark, OverviewView(store: ch, onSelect: { _ in }, onEmptyTrash: {}, onSettings: {}))
        let nb = store(battery: nil)
        capture("overview-nobattery", dark: dark, OverviewView(store: nb, onSelect: { _ in }, onEmptyTrash: {}, onSettings: {}))
    }
    print("done")
}
MainActor.assumeIsolated { runProbe() }

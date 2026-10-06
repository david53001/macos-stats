// Off-screen render probe for the guided tour (README.md). Renders the REAL overview, overlay,
// callout, welcome card, chip, Settings and breakdown views with a fake MetricsStore, in windows at
// desktop level + 1 ordered back (never activated), and measures that the spotlight is centred:
// for each step it compares a capture with the tour against one without it (same window, static
// data) along the target's centre row and column. Tour state lives in a throwaway UserDefaults
// suite that is deleted at the end; the MacStats defaults domain is never touched.
import AppKit
import SwiftUI
import MacStatsCore

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "out"
let mode = args.count > 2 ? args[2] : "render"

/// Anchor rects (panel points) as the overlay resolves them, written by `AnchorProbe`.
nonisolated(unsafe) var anchorRects: [String: CGRect] = [:]

/// Reads the same `TourAnchorKey` the overlay reads, on the same panel frame.
struct AnchorProbe: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(TourAnchorKey.self) { anchors in
            GeometryReader { proxy in
                let _ = { for (id, a) in anchors { anchorRects[id] = proxy[a.bounds] } }()
                Color.clear
            }
        }
    }
}

/// The overview as `RootView` composes it: fixed frame, `.tourHost`, clipped, the Opacity backdrop.
struct ProbePanel: View {
    @ObservedObject var store: MetricsStore
    @ObservedObject var tour: TourController
    let defaults: UserDefaults
    var noTour = false

    var body: some View {
        let overview = OverviewView(store: store, onSelect: { _ in }, onEmptyTrash: {}, onSettings: {},
                                    offersTour: tour.offersTour, onTour: {}, onDismissOffer: {})
            .frame(width: Design.panelWidth, height: Design.panelHeight)
        Group {
            if noTour { overview } else { overview.tourHost(tour, showing: true).modifier(AnchorProbe()) }
        }
        .clipped()
        .background(PanelBackdrop())
        .defaultAppStorage(defaults)
    }
}

@MainActor func makeStore(battery: BatterySample? = BatterySample(percent: 64, state: .discharging,
                                                                  timeToEmptyMinutes: 245)) -> MetricsStore {
    let s = MetricsStore()
    let now = Date().timeIntervalSinceReferenceDate
    for i in 0..<120 {
        let t = now - 60 + Double(i) * 0.5
        let mem = MemorySample(usedBytes: 11_200_000_000, totalBytes: 17_179_869_184, pressure: .normal,
                               appBytes: 7_100_000_000, wiredBytes: 2_300_000_000, compressedBytes: 1_800_000_000,
                               compressedDataBytes: 5_200_000_000)
        s.record(cpuPercent: 23 + 8 * sin(Double(i) / 7) + Double(i % 5), memory: mem,
                 network: NetworkSample(downBytesPerSec: 120_000 + 90_000 * sin(Double(i) / 5), upBytesPerSec: 14_000),
                 time: t)
    }
    s.setBattery(battery)
    s.setBatteryTelemetry(BatteryTelemetry(updateTime: 0, cycleCount: 212, temperatureC: 31.4), powerWatts: 6.8,
                          averageWatts: 7.4, averageSinceUnplug: true)
    s.setCPUTemperature(47)
    s.setTrashBytes(842_000_000)
    return s
}

@MainActor func fakeApps(_ metric: BreakdownMetric) -> [AppUsage] {
    let me = Int32(getpid())
    let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        .prefix(6).map { Int32($0.processIdentifier) }
    let cpus: [Double] = [9.8, 2.1, 1.4, 0.9, 0.6, 0.4]
    var out: [AppUsage] = running.enumerated().map { i, p in
        let n = i == 0 ? 9 : (i == 1 ? 3 : 1)
        let procs = (0..<n).map { k in
            ProcessUsage(pid: k == 0 ? p : me, appPID: p, cpuPercent: cpus[i] / Double(k + 1) / 2,
                         memoryBytes: UInt64(900_000_000 / (k + 1)), watts: cpus[i] / 10 / Double(k + 1))
        }
        return AppUsage(appPID: p, processes: procs, cpuPercent: cpus[i], memoryBytes: UInt64(2_400_000_000 / (i + 1)),
                        watts: cpus[i] / 8)
    }
    out.append(AppUsage(appPID: BreakdownGroup.system, processes: [ProcessUsage(pid: 0, appPID: BreakdownGroup.system,
                        cpuPercent: 4.2, memoryBytes: 0)], cpuPercent: 4.2, memoryBytes: 0, watts: 0.3))
    return out.sorted { $0.value(for: metric) > $1.value(for: metric) }
}

// MARK: Windows and captures

@MainActor func settle(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
}

@MainActor func makeWindow<V: View>(_ view: V) -> NSWindow {
    let frame = NSRect(x: 0, y: 0, width: Design.panelWidth, height: Design.panelHeight)
    let host = NSHostingView(rootView: view.frame(width: Design.panelWidth, height: Design.panelHeight))
    host.frame = frame
    let fx = NSVisualEffectView(frame: frame)
    fx.material = .popover; fx.state = .active; fx.blendingMode = .behindWindow
    fx.wantsLayer = true
    fx.layer?.cornerRadius = Design.panelCornerRadius; fx.layer?.cornerCurve = .continuous
    fx.layer?.masksToBounds = true
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

@MainActor func capture(_ w: NSWindow) -> CGImage? {
    if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber),
                                         [.boundsIgnoreFraming, .bestResolution]) { return img }
    guard let view = w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep.cgImage
}

func save(_ img: CGImage?, _ name: String) {
    guard let img else { print("capture failed", name); return }
    let path = "\(outDir)/\(name).png"
    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: path))
    print("wrote", name, img.width, "x", img.height)
}

@MainActor func shoot<V: View>(_ name: String, _ view: V, wait: Double = 0.8) {
    let w = makeWindow(view)
    settle(wait)
    save(capture(w), name)
    w.orderOut(nil); w.close()
}

// MARK: Pixel measurement

struct Pixels {
    let w: Int, h: Int
    var data: [UInt8]
    init(_ img: CGImage) {
        w = img.width; h = img.height
        data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * w + x) * 4   // row 0 = top (CGContext memory order)
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }
}

func dist(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
    max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
}

/// From the target's edge outward along one axis: `inner` = unchanged pixels (the clear gap
/// between card and ring), `outer` = inner + the accent-coloured run (the ring; its outer edge is
/// the cutout's edge). The accent is sampled on the left run.
func walk(_ base: Pixels, _ tour: Pixels, from start: (Int, Int), step: (Int, Int),
          accent: inout (Int, Int, Int)?) -> (inner: Int, outer: Int) {
    var (x, y) = start
    var inner = 0
    while x >= 0, y >= 0, x < base.w, y < base.h, dist(base.rgb(x, y), tour.rgb(x, y)) <= 8 {
        inner += 1; x += step.0; y += step.1
    }
    if accent == nil, x >= 0, y >= 0, x < base.w, y < base.h { accent = tour.rgb(x, y) }
    var ring = 0
    while x >= 0, y >= 0, x < base.w, y < base.h, let a = accent, dist(tour.rgb(x, y), a) <= 40 {
        ring += 1; x += step.0; y += step.1
    }
    return (inner, inner + ring)
}

nonisolated(unsafe) var report: [String] = []
nonisolated(unsafe) var failures = 0

func log(_ line: String) {
    print(line)
    report.append(line)
}

@MainActor func calloutHeight(_ step: TourStep, dark: Bool) -> CGFloat {
    let view = TourCallout(step: step, progress: (1, 5), onSkip: {}, onBack: {}, onNext: {})
        .frame(width: Design.panelWidth - 2 * TourLayout.panelMargin)
        .environment(\.colorScheme, dark ? .dark : .light)
    return NSHostingView(rootView: view).fittingSize.height
}

@MainActor func measure(_ name: String, base: CGImage, tour: CGImage, anchor id: String, step: TourStep, dark: Bool) {
    guard let target = anchorRects[id] else { log("step=\(name) anchor \(id) missing"); failures += 1; return }
    let b = Pixels(base), t = Pixels(tour)
    let s = CGFloat(b.w) / Design.panelWidth
    let midX = Int((target.midX * s).rounded(.down)), midY = Int((target.midY * s).rounded(.down))
    var accent: (Int, Int, Int)?
    let l = walk(b, t, from: (Int((target.minX * s).rounded()) - 1, midY), step: (-1, 0), accent: &accent)
    let r = walk(b, t, from: (Int((target.maxX * s).rounded()), midY), step: (1, 0), accent: &accent)
    let top = walk(b, t, from: (midX, Int((target.minY * s).rounded()) - 1), step: (0, -1), accent: &accent)
    let bot = walk(b, t, from: (midX, Int((target.maxY * s).rounded())), step: (0, 1), accent: &accent)
    let panel = CGRect(x: 0, y: 0, width: Design.panelWidth, height: Design.panelHeight)
    let cut = TourLayout.cutout(target: target, targetRadius: Design.cardCornerRadius, panel: panel, scale: s)
    let h = calloutHeight(step, dark: dark)
    let co = TourLayout.callout(cutout: cut.rect, height: h, panel: panel, scale: s)
    let placement = co.minY >= cut.rect.maxY ? "below" : "above"
    let want = Int((TourLayout.cutoutInset * s).rounded())
    let ok = abs(l.inner - r.inner) <= 1 && abs(top.inner - bot.inner) <= 1
        && abs(l.outer - r.outer) <= 1 && abs(top.outer - bot.outer) <= 1
        && [l.outer, r.outer, top.outer, bot.outer].allSatisfy { abs($0 - want) <= 1 }
        && !co.intersects(cut.rect)
    if !ok { failures += 1 }
    func f(_ r: CGRect) -> String { "(\(r.minX),\(r.minY),\(r.width),\(r.height))" }
    log("step=\(name) \(dark ? "dark" : "light") inner(px) L=\(l.inner) R=\(r.inner) T=\(top.inner) B=\(bot.inner) "
        + "outer(px) L=\(l.outer) R=\(r.outer) T=\(top.outer) B=\(bot.outer) target=\(f(target))pt "
        + "cutout=\(f(cut.rect))pt radius=\(cut.radius) callout=\(f(co))pt placement=\(placement) \(ok ? "OK" : "FAIL")")
}

// MARK: Text fit

@MainActor func fittingWidth<V: View>(_ v: V) -> CGFloat { NSHostingView(rootView: v.fixedSize()).fittingSize.width }

@MainActor func checkFit() {
    let one = NSHostingView(rootView: Text("A").font(.callout).frame(width: 280)).fittingSize.height
    let two = NSHostingView(rootView: Text("A\nA").font(.callout).frame(width: 280)).fittingSize.height
    for step in TourCatalog.steps {
        let h = NSHostingView(rootView: Text(step.body).font(.callout).frame(width: 280)
            .fixedSize(horizontal: false, vertical: true)).fittingSize.height
        let lines = h <= one + 0.5 ? 1 : h <= two + 0.5 ? 2 : 3
        if lines > 2 { failures += 1 }
        log("fit body=\(step.id.rawValue) lines=\(lines) \(lines <= 2 ? "OK" : "FAIL")")
    }
    // Footnotes share the footer row with "Quit MacStats" (HStack spacing 8, the cards' 12 pt inset).
    let quit = fittingWidth(Button("Quit MacStats") {}.buttonStyle(SubtleButtonStyle(cornerRadius: Design.cardCornerRadius)))
    let room = Design.panelWidth - 2 * Design.panelInset - quit - 8 - Design.cardPadding
    let cores = ProcessInfo.processInfo.activeProcessorCount
    for note in ["Share of the whole Mac (all \(cores) cores)", "Each app\u{2019}s memory, as in Activity Monitor",
                 "App power: CPU only, not screen or GPU", "Right-click an app to quit it"] {
        let w = fittingWidth(Text(note).font(.caption2))
        let scale = min(1, room / w)
        if scale < 0.8 { failures += 1 }
        log(String(format: "fit footnote=\"%@\" width=%.1f room=%.1f scale=%.2f %@", note, w, room, scale,
                   scale >= 0.8 ? "OK" : "FAIL"))
    }
}

// MARK: Runs

@MainActor func suite(_ name: String, audience: TourAudience) -> UserDefaults {
    let d = UserDefaults(suiteName: name)!
    d.set(audience.rawValue, forKey: TourKey.audience)
    return d
}

@MainActor func render() {
    let suites = (0..<6).map { "MacStatsTourProbe-\(UUID().uuidString)-\($0)" }
    defer { suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) } }
    checkFit()

    for dark in [false, true] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let look = dark ? "dark" : "light"

        // Steps 1–5: one window, a capture without the tour, then each step.
        let d = suite(suites[0], audience: .existing)
        let store = makeStore()
        let tour = TourController(defaults: d, hasBattery: { true })
        let w = makeWindow(ProbePanel(store: store, tour: tour, defaults: d))
        settle(0.8)
        guard let base = capture(w) else { print("capture failed"); return }
        save(base, "overview-\(look)")
        anchorRects = [:]
        tour.start()
        for (i, step) in TourCatalog.steps.enumerated() {
            settle(0.9)
            let img = capture(w)
            save(img, "step\(i + 1)-\(look)")
            if let img { measure(step.id.rawValue, base: base, tour: img, anchor: step.anchor, step: step, dark: dark) }
            tour.next()
        }
        w.orderOut(nil); w.close()

        // Step 1 at Opacity 0 and 1.
        for opacity in [0.0, 1.0] {
            let od = suite(suites[1], audience: .existing)
            od.set(opacity, forKey: UIOpacity.key)
            let ot = TourController(defaults: od, hasBattery: { true })
            ot.start()
            shoot("step1-opacity\(Int(opacity))-\(look)", ProbePanel(store: makeStore(), tour: ot, defaults: od))
            od.removeObject(forKey: UIOpacity.key)
        }

        // No battery: Battery is skipped, the footer reads "4 of 4".
        let nd = suite(suites[2], audience: .existing)
        let nstore = makeStore(battery: nil)
        let nt = TourController(defaults: nd, hasBattery: { false })
        let nw = makeWindow(ProbePanel(store: nstore, tour: nt, defaults: nd))
        settle(0.8)
        if let nbase = capture(nw) {
            anchorRects = [:]
            nt.start(); nt.next(); nt.next(); nt.next()
            settle(0.9)
            let img = capture(nw)
            save(img, "nobattery-step4-\(look)")
            let footer = TourCatalog.steps.last!
            if let img { measure("footer-nobattery", base: nbase, tour: img, anchor: footer.anchor, step: footer, dark: dark) }
            log("nobattery progress=\(nt.progress.map { "\($0.number) of \($0.total)" } ?? "nil")")
        }
        nw.orderOut(nil); nw.close()

        // A new user's first open: the welcome card.
        let wd = suite(suites[3], audience: .new)
        wd.removeObject(forKey: TourKey.seenVersion)
        let wt = TourController(defaults: wd, hasBattery: { true })
        wt.panelOpened()
        shoot("welcome-\(look)", ProbePanel(store: makeStore(), tour: wt, defaults: wd), wait: 1.0)

        // An existing user: the chip.
        let cd = suite(suites[4], audience: .existing)
        let ct = TourController(defaults: cd, hasBattery: { true })
        ct.panelOpened()
        log("chip offersTour=\(ct.offersTour) offerShows=\(cd.integer(forKey: TourKey.offerShows))")
        shoot("chip-\(look)", ProbePanel(store: makeStore(), tour: ct, defaults: cd))

        shoot("settings-help-\(look)", SettingsView(onBack: {})
            .frame(width: Design.panelWidth, height: Design.panelHeight).background(PanelBackdrop())
            .defaultAppStorage(cd))

        if !dark {
            let ts = makeStore()
            ts.setTrashBytes(nil)
            ts.setTrashNeedsPermission(true)
            shoot("trash-permission-\(look)", ProbePanel(store: ts, tour: wt, defaults: wd, noTour: true))
            for (metric, hint) in [(BreakdownMetric.cpu, true), (.memory, false)] {
                let bs = makeStore()
                bs.beginBreakdown(metric: metric)
                bs.setBreakdown(fakeApps(metric), measuring: false, totalCPU: 23)
                shoot(hint ? "breakdown-hint-cpu-\(look)" : "breakdown-\(metric)-\(look)",
                      BreakdownView(store: bs, metric: metric, quitHint: hint, onBack: {})
                        .background(PanelBackdrop()).defaultAppStorage(cd))
            }
        }
    }
    log("failures=\(failures)")
    try? (report.joined(separator: "\n") + "\n").write(toFile: "\(outDir)/insets.txt", atomically: true, encoding: .utf8)
}

/// MacStats's own CPU while the overview ticks at the open cadence (0.5 s `store.record`):
/// 20 s with the tour off, then 20 s on step 1 (or 20 s with `.tourHost` left out: `--no-tour`).
@MainActor func cost(noTour: Bool) {
    let name = "MacStatsTourProbe-\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: name) }
    let d = suite(name, audience: .existing)
    let store = makeStore()
    let tour = TourController(defaults: d, hasBattery: { true })
    let w = makeWindow(ProbePanel(store: store, tour: tour, defaults: d, noTour: noTour))
    settle(1)
    var i = 0.0
    func cpuSeconds() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }
    func run(_ label: String) {
        let c0 = cpuSeconds(), t0 = Date()
        while Date().timeIntervalSince(t0) < 20 {
            i += 1
            let mem = MemorySample(usedBytes: UInt64(11_000_000_000 + 100_000_000 * sin(i / 3)), totalBytes: 17_179_869_184,
                                   pressure: .normal)
            store.record(cpuPercent: 20 + 10 * sin(i / 4), memory: mem,
                         network: NetworkSample(downBytesPerSec: 100_000 + 80_000 * sin(i / 2), upBytesPerSec: 9_000),
                         time: Date().timeIntervalSinceReferenceDate)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))   // one wait per tick, no polling
        }
        let pct = (cpuSeconds() - c0) / Date().timeIntervalSince(t0) * 100
        print(String(format: "cost %@ process_cpu_pct=%.2f", label, pct))
    }
    if noTour {
        run("no-tour-host")
    } else {
        run("tour-off")
        tour.start()
        run("tour-on-step1")
    }
    w.orderOut(nil); w.close()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    switch mode {
    case "--cost": cost(noTour: false)
    case "--no-tour": cost(noTour: true)
    default: render()
    }
    print("done")
}

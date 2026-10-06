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
                                                                  timeToEmptyMinutes: 245),
                          used: UInt64 = 11_200_000_000, total: UInt64 = 17_179_869_184) -> MetricsStore {
    let s = MetricsStore()
    let now = Date().timeIntervalSinceReferenceDate
    for i in 0..<120 {
        let t = now - 60 + Double(i) * 0.5
        let mem = MemorySample(usedBytes: used, totalBytes: total, pressure: .normal,
                               appBytes: 7_100_000_000, wiredBytes: 2_300_000_000, compressedBytes: 1_800_000_000,
                               compressedDataBytes: 5_200_000_000)
        s.record(cpuPercent: 23 + 8 * sin(Double(i) / 7) + Double(i % 5), memory: mem,
                 network: NetworkSample(downBytesPerSec: 120_000 + 90_000 * sin(Double(i) / 5), upBytesPerSec: 14_000),
                 time: t)
    }
    s.setBattery(battery)
    s.setBatteryTelemetry(BatteryTelemetry(updateTime: 0, nominalMAh: 4_200, designMAh: 4_563, cycleCount: 212,
                                           temperatureC: 31.4), powerWatts: 6.8,
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
    // The dim's darkness in the 6 pt strip between callout and cutout ("near") vs. the same strip on
    // the cutout's other side ("far"), as tour/base luminance over the callout's middle columns. A
    // callout shadow falling into the gap makes near < far (review round 2: steps 4-5, light).
    func strip(_ y0: CGFloat, _ y1: CGFloat) -> Double? {
        let r0 = max(0, Int((y0 * s).rounded())), r1 = min(b.h, Int((y1 * s).rounded()))
        guard r1 > r0 else { return nil }
        var tb = 0.0, bb = 0.0
        for y in r0..<r1 {
            for x in Int((co.minX + 20) * s)..<Int((co.maxX - 20) * s) {
                func lum(_ c: (Int, Int, Int)) -> Double { 0.299 * Double(c.0) + 0.587 * Double(c.1) + 0.114 * Double(c.2) }
                tb += lum(t.rgb(x, y)); bb += lum(b.rgb(x, y))
            }
        }
        return bb > 0 ? tb / bb : nil
    }
    let gap = placement == "below" ? co.minY - cut.rect.maxY : cut.rect.minY - co.maxY
    let near = placement == "below" ? strip(cut.rect.maxY, co.minY) : strip(co.maxY, cut.rect.minY)
    let far = placement == "below" ? strip(cut.rect.minY - gap, cut.rect.minY)
                                   : strip(cut.rect.maxY, min(cut.rect.maxY + gap, Design.panelHeight))
    let shadow = near.flatMap { n in far.map { f in String(format: " strip near=%.3f far=%.3f", n, f) } } ?? ""
    func f(_ r: CGRect) -> String { "(\(r.minX),\(r.minY),\(r.width),\(r.height))" }
    log("step=\(name) \(dark ? "dark" : "light") inner(px) L=\(l.inner) R=\(r.inner) T=\(top.inner) B=\(bot.inner) "
        + "outer(px) L=\(l.outer) R=\(r.outer) T=\(top.outer) B=\(bot.outer) target=\(f(target))pt "
        + "cutout=\(f(cut.rect))pt radius=\(cut.radius) callout=\(f(co))pt placement=\(placement)\(shadow) \(ok ? "OK" : "FAIL")")
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
    _ = cores
    for note in ["Each app\u{2019}s share of the whole Mac", "Each app\u{2019}s memory, as in Activity Monitor",
                 "Processor power only, not the screen", "Right-click an app to quit it"] {
        let w = fittingWidth(Text(note).font(.caption2))
        let scale = min(1, room / w)
        if scale < 0.8 { failures += 1 }
        log(String(format: "fit footnote=\"%@\" width=%.1f room=%.1f scale=%.2f %@", note, w, room, scale,
                   scale >= 0.8 ? "OK" : "FAIL"))
    }
}

// MARK: Runs

/// Deletes a throwaway suite, including the plist cfprefsd leaves behind. cfprefsd writes the
/// (empty) plist asynchronously after the domain is removed, so flush, wait, then delete.
func dropSuite(_ name: String) {
    UserDefaults.standard.removePersistentDomain(forName: name)
    CFPreferencesAppSynchronize(name as CFString)
    Thread.sleep(forTimeInterval: 0.3)
    let plist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(name).plist")
    try? FileManager.default.removeItem(at: plist)
}

@MainActor func suite(_ name: String, audience: TourAudience) -> UserDefaults {
    // run.sh deletes the plists named here once the probe has exited: cfprefsd can write them
    // again at exit, after `dropSuite` already removed them.
    let list = (NSTemporaryDirectory() as NSString).appendingPathComponent("macstats-tour-probe-suites.txt")
    if let h = FileHandle(forWritingAtPath: list) ?? {
        FileManager.default.createFile(atPath: list, contents: nil); return FileHandle(forWritingAtPath: list) }() {
        h.seekToEndOfFile(); h.write(Data((name + "\n").utf8)); try? h.close()
    }
    let d = UserDefaults(suiteName: name)!
    d.set(audience.rawValue, forKey: TourKey.audience)
    return d
}

@MainActor func render() {
    let suites = (0..<6).map { "MacStatsTourProbe-\(UUID().uuidString)-\($0)" }
    defer { suites.forEach(dropSuite) }
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

        // A 128 GB Mac: the Memory value must fit its column ("103 / 128 GB").
        shoot("overview-128gb-\(look)", ProbePanel(store: makeStore(used: 110_000_000_000, total: 137_438_953_472),
                                                    tour: ct, defaults: cd, noTour: true))

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
    defer { dropSuite(name) }
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

// MARK: Breakdowns with real scans (--breakdowns)

final class Scan {
    let scanner = BreakdownScanner()
    func run(_ metric: BreakdownMetric) -> BreakdownScanner.Result {
        let anchors = attributionAnchors(NSWorkspace.shared.runningApplications.map { app in
            RunningAppInfo(pid: Int32(app.processIdentifier), hasBundleIdentifier: app.bundleIdentifier != nil,
                           isBackgroundOnly: app.activationPolicy == .prohibited,
                           isMacOSAgent: isMacOSAgent(path: (app.bundleURL ?? app.executableURL)?.path,
                                                      isRegularApp: app.activationPolicy == .regular))
        })
        let time = Date().timeIntervalSinceReferenceDate
        let absTime = mach_absolute_time()
        let ticks = readCPUTicks()
        let raw = readRawProcesses(includeEnergy: metric == .energy)
        return scanner.scan(raw, appPIDs: anchors.apps, fallbackAppPIDs: anchors.fallbacks,
                            metric: metric, time: time, absTime: absTime, cpuTicks: ticks)
    }
}

/// A synthetic click on the probe's own (off-screen) window: never the real pointer or menu bar.
@MainActor func click(_ w: NSWindow, at p: CGPoint) {
    guard let host = w.contentView?.subviews.first else { return }
    let loc = NSPoint(x: p.x, y: Design.panelHeight - p.y)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        let target = host.hitTest(host.superview!.convert(loc, from: nil)) ?? host
        if type == .leftMouseDown { target.mouseDown(with: e) } else { target.mouseUp(with: e) }
        settle(0.08)
    }
}

/// CPU, Memory and Battery breakdowns of this Mac's live processes (scan, "Measuring…", then two
/// 2 s scans, as the app does), light and dark, then with the app that has the most processes
/// among the top six expanded by a click on its row.
@MainActor func breakdowns() {
    let name = "MacStatsTourProbe-\(UUID().uuidString)"
    defer { dropSuite(name) }
    let d = suite(name, audience: .existing)
    d.set(true, forKey: TourKey.breakdownMenuUsed)   // the footnote, not the quit hint
    for dark in [false, true] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let look = dark ? "dark" : "light"
        for metric in [BreakdownMetric.cpu, .memory, .energy] {
            let store = makeStore()
            store.beginBreakdown(metric: metric)
            let scan = Scan()
            var r = scan.run(metric)
            store.setBreakdown(r.apps, measuring: r.measuring, totalCPU: r.totalCPUPercent)
            for _ in 0..<2 {
                settle(2)
                r = scan.run(metric)
                store.setBreakdown(r.apps, measuring: r.measuring, totalCPU: r.totalCPUPercent)
            }
            let w = makeWindow(BreakdownView(store: store, metric: metric, onBack: {})
                .background(PanelBackdrop()).defaultAppStorage(d))
            settle(1)
            save(capture(w), "r2-breakdown-\(metric)-\(look)")
            if let target = store.breakdown.prefix(6).filter({ $0.isApp }).max(by: { $0.processes.count < $1.processes.count }),
               target.processes.count > 1,
               let index = store.breakdown.firstIndex(where: { $0.appPID == target.appPID }) {
                var top: CGFloat = 36 + 6
                if metric == .memory { top += NSHostingView(rootView: MemoryPartsCard(store: store).frame(width: 304)).fittingSize.height + 6 }
                if metric == .energy { top += NSHostingView(rootView: BatteryDetailsCard(store: store).frame(width: 304)).fittingSize.height + 6 }
                click(w, at: CGPoint(x: 120, y: top + 4 + 36 * CGFloat(index) + 18))
                settle(0.8)
                log("breakdown \(metric) \(look) expanded \(NSRunningApplication(processIdentifier: target.appPID)?.localizedName ?? "?") "
                    + "(\(target.processes.count) processes) at row \(index)")
                save(capture(w), "r2-breakdown-\(metric)-expanded-\(look)")
            }
            w.orderOut(nil); w.close()
        }
    }
    try? (report.joined(separator: "\n") + "\n").write(toFile: "\(outDir)/breakdowns.txt", atomically: true, encoding: .utf8)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    switch mode {
    case "--cost": cost(noTour: false)
    case "--no-tour": cost(noTour: true)
    case "--breakdowns": breakdowns()
    default: render()
    }
    print("done")
}

// Reviewer B (round 6) independent probe. Modes:
//   render <outDir>          real views off-screen (desktop level + 1, ordered back), light + dark, and
//                            pixel-measured tour cutout insets (outDir/tour-insets.txt)
//   live <outDir> <seconds>  real MetricsStore + BreakdownScanner on this Mac's live processes, headless
//   cost <outDir>            CPU of the overview render with the tour off vs on (20 s each)
import AppKit
import SwiftUI
import MacStatsCore

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "render"
let outDir = args.count > 2 ? args[2] : "out"
let liveSeconds = args.count > 3 ? Double(args[3]) ?? 120 : 120
nonisolated(unsafe) var lines: [String] = []
func log(_ s: String) { print(s); lines.append(s) }
func flush(_ name: String) {
    try? (lines.joined(separator: "\n") + "\n").write(toFile: "\(outDir)/\(name)", atomically: true, encoding: .utf8)
    lines = []
}

// MARK: Real readings

final class Reader {
    struct Snap { let time: Date; let cpu: CPUTicks; let net: NetCounters }
    var snaps: [Snap] = []
    let total = ProcessInfo.processInfo.physicalMemory
    /// One app-cadence sample (AppModel.sample): returns (cpu, mem, net) once a baseline exists.
    func sample(_ now: Date = Date()) -> (Double, MemorySample, NetworkSample)? {
        snaps.append(Snap(time: now, cpu: readCPUTicks(), net: readNetCounters()))
        let b = rateBaselineIndex(times: snaps.lazy.map { $0.time.timeIntervalSinceReferenceDate },
                                  now: now.timeIntervalSinceReferenceDate, window: rateWindowSeconds)
        if b > 0 { snaps.removeFirst(b) }
        guard snaps.count > 1, let cur = snaps.last else { return nil }
        let base = snaps[0]
        return (cpuBusyPercent(previous: base.cpu, current: cur.cpu),
                memorySample(raw: readVMRaw(), totalBytes: total, pressureLevel: readMemoryPressureLevel()),
                networkThroughput(previous: base.net, current: cur.net, secondsElapsed: now.timeIntervalSince(base.time)))
    }
}

/// A copy of AppModel's BreakdownScanSession.scan (same anchors and order of reads).
final class Scan {
    let scanner = BreakdownScanner()
    var ms: [Double] = []
    func run(_ metric: BreakdownMetric) -> BreakdownScanner.Result {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let anchors = attributionAnchors(NSWorkspace.shared.runningApplications.map { app in
            let policy = app.activationPolicy
            return RunningAppInfo(pid: Int32(app.processIdentifier), hasBundleIdentifier: app.bundleIdentifier != nil,
                                  isBackgroundOnly: policy == .prohibited,
                                  isMacOSAgent: isMacOSAgent(path: (app.bundleURL ?? app.executableURL)?.path,
                                                             isRegularApp: policy == .regular))
        })
        let time = Date().timeIntervalSinceReferenceDate
        let absTime = mach_absolute_time()
        let ticks = readCPUTicks()
        let raw = readRawProcesses(includeEnergy: metric == .energy)
        let r = scanner.scan(raw, appPIDs: anchors.apps, fallbackAppPIDs: anchors.fallbacks,
                             metric: metric, time: time, absTime: absTime, cpuTicks: ticks)
        ms.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        return r
    }
}

@MainActor func settle(_ s: Double) {
    let end = Date().addingTimeInterval(s)
    while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
}

/// A store with ~60 s of real readings (taken fast, spread over the last minute) + real battery etc.
@MainActor func liveStore() -> MetricsStore {
    let s = MetricsStore()
    let r = Reader()
    var got: [(Double, MemorySample, NetworkSample)] = []
    _ = r.sample()
    for _ in 0..<40 { settle(0.1); if let v = r.sample() { got.append(v) } }
    let now = Date().timeIntervalSinceReferenceDate
    for (i, v) in got.enumerated() {
        s.record(cpuPercent: v.0, memory: v.1, network: v.2, time: now - 60 + 60 * Double(i) / Double(got.count))
    }
    s.setBattery(readBattery())
    let t = SmartBatteryReader().read()
    s.setBatteryTelemetry(t, powerWatts: 6.4, averageWatts: 7.1, averageSinceUnplug: true)
    s.setCPUTemperature(CPUTemperatureReader().read())
    s.setTrashBytes(842_000_000)
    return s
}

// MARK: Windows

@MainActor func makeWindow<V: View>(_ view: V, solid: Bool = false) -> NSWindow {
    let frame = NSRect(x: 0, y: 0, width: Design.panelWidth, height: Design.panelHeight)
    let host = NSHostingView(rootView: view.frame(width: Design.panelWidth, height: Design.panelHeight))
    host.frame = frame
    let container: NSView
    if solid {
        container = NSView(frame: frame)
        container.wantsLayer = true
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    } else {
        let fx = NSVisualEffectView(frame: frame)
        fx.material = .popover; fx.state = .active; fx.blendingMode = .behindWindow
        container = fx
    }
    container.wantsLayer = true
    container.layer?.cornerRadius = Design.panelCornerRadius
    container.layer?.cornerCurve = .continuous
    container.layer?.masksToBounds = true
    container.addSubview(host)
    let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
    w.isReleasedWhenClosed = false
    w.contentView = container
    w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
    w.setFrameOrigin(NSPoint(x: 60, y: 60))
    w.orderBack(nil)
    return w
}

@MainActor func capture(_ w: NSWindow) -> CGImage? {
    if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber),
                                         [.boundsIgnoreFraming, .bestResolution]) { return img }
    guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
    v.cacheDisplay(in: v.bounds, to: rep)
    return rep.cgImage
}

func save(_ img: CGImage?, _ name: String) {
    guard let img else { print("capture failed", name); return }
    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    print("wrote", name, img.width, "x", img.height)
}

@MainActor func click(_ w: NSWindow, at p: CGPoint, right: Bool = false) {
    guard let host = w.contentView?.subviews.first else { return }
    let loc = NSPoint(x: p.x, y: Design.panelHeight - p.y)
    let types: [NSEvent.EventType] = right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
    for type in types {
        let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let target = host.hitTest(host.superview!.convert(loc, from: nil)) ?? host
        switch type {
        case .leftMouseDown: target.mouseDown(with: e)
        case .leftMouseUp: target.mouseUp(with: e)
        default: break
        }
        settle(0.08)
    }
}

// MARK: Tour geometry read-out (the same preference the overlay reads)

nonisolated(unsafe) var anchorRects: [String: CGRect] = [:]
struct AnchorReadout: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(TourAnchorKey.self) { anchors in
            GeometryReader { proxy in
                let _ = { for (id, a) in anchors { anchorRects[id] = proxy[a.bounds] } }()
                Color.clear
            }
        }
    }
}

struct Panel: View {
    @ObservedObject var store: MetricsStore
    @ObservedObject var tour: TourController
    let defaults: UserDefaults
    var body: some View {
        OverviewView(store: store, onSelect: { _ in }, onEmptyTrash: {}, onSettings: {},
                     offersTour: tour.offersTour, onTour: {}, onDismissOffer: { tour.dismissOffer() })
            .frame(width: Design.panelWidth, height: Design.panelHeight)
            .tourHost(tour, showing: true)
            .modifier(AnchorReadout())
            .clipped()
            .background(PanelBackdrop())
            .defaultAppStorage(defaults)
    }
}

nonisolated(unsafe) var suites: [String] = []
func suite(_ audience: TourAudience) -> UserDefaults {
    let name = "R6BProbe-\(UUID().uuidString)"
    suites.append(name)
    let d = UserDefaults(suiteName: name)!
    d.set(audience.rawValue, forKey: TourKey.audience)
    return d
}
func dropSuites() {
    for name in suites {
        UserDefaults.standard.removePersistentDomain(forName: name)
        CFPreferencesAppSynchronize(name as CFString)
        try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/Library/Preferences/\(name).plist")
    }
}

// MARK: Pixels

struct Pixels {
    let w: Int, h: Int
    var d: [UInt8]
    init(_ img: CGImage) {
        w = img.width; h = img.height
        d = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &d, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * w + x) * 4
        return (Int(d[i]), Int(d[i + 1]), Int(d[i + 2]))
    }
    func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h }
}
func diff(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int { max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) }
func sat(_ a: (Int, Int, Int)) -> Int { max(a.0, a.1, a.2) - min(a.0, a.1, a.2) }

/// Independent measurement. From the target's centre, walk outward in the TOUR image until the first
/// ring pixel (differs from the base capture and is saturated): that run of ring pixels ends at the cutout
/// edge. Then from the ring's inner edge walk back inward in the BASE image until the first pixel that
/// differs from the panel background: the target's outer edge. Returns (gap target→cutout edge, ring px).
func side(_ b: Pixels, _ t: Pixels, bg: (Int, Int, Int), from c: (Int, Int), step: (Int, Int)) -> (gap: Int, ring: Int)? {
    var (x, y) = c
    while t.inside(x, y), !(diff(t.px(x, y), b.px(x, y)) > 12 && sat(t.px(x, y)) > 40) { x += step.0; y += step.1 }
    guard t.inside(x, y) else { return nil }
    let ringStart = (x, y)
    var ring = 0
    while t.inside(x, y), sat(t.px(x, y)) > 40, diff(t.px(x, y), b.px(x, y)) > 12 { ring += 1; x += step.0; y += step.1 }
    // cutout edge boundary is at (x,y) (first non-ring pixel). Walk inward from ringStart in base.
    var (ix, iy) = (ringStart.0 - step.0, ringStart.1 - step.1)
    var gap = 0
    while b.inside(ix, iy), diff(b.px(ix, iy), bg) <= 3 { gap += 1; ix -= step.0; iy -= step.1 }
    return (gap + ring, ring)
}

/// Along a corner's 45° diagonal: steps from the target's bbox corner to its curve (base) and from the
/// cutout's bbox corner to the ring (tour). Concentric corners give a diagonal gap equal to the edge gap.
func diagonal(_ b: Pixels, _ t: Pixels, bg: (Int, Int, Int), corner: (Int, Int), dir: (Int, Int), max: Int) -> Int? {
    var (x, y) = corner
    for k in 0..<max {
        if t.inside(x, y), sat(t.px(x, y)) > 40, diff(t.px(x, y), b.px(x, y)) > 12 { return k }
        x += dir.0; y += dir.1
    }
    return nil
}
func diagonalTarget(_ b: Pixels, bg: (Int, Int, Int), corner: (Int, Int), dir: (Int, Int), max: Int) -> Int? {
    var (x, y) = corner
    for k in 0..<max {
        if b.inside(x, y), diff(b.px(x, y), bg) > 3 { return k }
        x += dir.0; y += dir.1
    }
    return nil
}

@MainActor func measureTour(dark: Bool, store: MetricsStore) {
    NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let look = dark ? "dark" : "light"
    let d = suite(.existing)
    d.set(TourCatalog.version, forKey: TourKey.seenVersion)   // no chip
    let tour = TourController(defaults: d, hasBattery: { store.battery != nil })
    let w = makeWindow(Panel(store: store, tour: tour, defaults: d), solid: true)
    settle(0.8)
    guard let baseImg = capture(w) else { return }
    let base = Pixels(baseImg)
    let scale = Int(w.backingScaleFactor)
    let bg = base.px(2 * scale, base.h / 2)   // the panel margin left of the cards
    tour.start()
    for i in TourCatalog.steps.indices where tour.isPresent(TourCatalog.steps[i]) {
        settle(1.0)
        guard let cur = tour.currentStep, let img = capture(w) else { continue }
        let t = Pixels(img)
        save(img, "measure-step\(cur.index + 1)-\(look)")
        guard let r = anchorRects[cur.step.anchor] else { log("\(look) step \(cur.index + 1): no anchor"); continue }
        let cut = TourLayout.cutout(target: r, targetRadius: Design.cardCornerRadius, panel: CGRect(x: 0, y: 0, width: 320, height: 404),
                                    scale: CGFloat(scale))
        let geo = String(format: "geometry: target (%.2f,%.2f %.2fx%.2f) cutout (%.2f,%.2f %.2fx%.2f) r=%.0f  insets L%.2f R%.2f T%.2f B%.2f",
                         r.minX, r.minY, r.width, r.height, cut.rect.minX, cut.rect.minY, cut.rect.width, cut.rect.height, cut.radius,
                         r.minX - cut.rect.minX, cut.rect.maxX - r.maxX, r.minY - cut.rect.minY, cut.rect.maxY - r.maxY)
        // Pixel walks along the centre row/column, and two more rows/columns at 1/4 and 3/4.
        let cx = Int(r.midX * CGFloat(scale)), cy = Int(r.midY * CGFloat(scale))
        func pt(_ v: Int?) -> String { v.map { String(format: "%.1f", Double($0) / Double(scale)) } ?? "?" }
        var parts: [String] = []
        for (name, dy) in [("mid", 0), ("q1", -Int(r.height * CGFloat(scale) / 4)), ("q3", Int(r.height * CGFloat(scale) / 4))] {
            let l = side(base, t, bg: bg, from: (cx, cy + dy), step: (-1, 0))
            let rr = side(base, t, bg: bg, from: (cx, cy + dy), step: (1, 0))
            parts.append("\(name)-row L\(pt(l?.gap)) R\(pt(rr?.gap))")
        }
        for (name, dx) in [("mid", 0), ("q1", -Int(r.width * CGFloat(scale) / 4)), ("q3", Int(r.width * CGFloat(scale) / 4))] {
            let tp = side(base, t, bg: bg, from: (cx + dx, cy), step: (0, -1))
            let bt = side(base, t, bg: bg, from: (cx + dx, cy), step: (0, 1))
            parts.append("\(name)-col T\(pt(tp?.gap)) B\(pt(bt?.gap))")
        }
        let ringW = side(base, t, bg: bg, from: (cx, cy), step: (-1, 0))?.ring
        // Corners: diagonal gap (pt) between the target's curve and the cutout's.
        var corners: [String] = []
        let ins = Int(TourLayout.cutoutInset) * scale
        let tx0 = Int((r.minX * CGFloat(scale)).rounded()), tx1 = Int((r.maxX * CGFloat(scale)).rounded()) - 1
        let ty0 = Int((r.minY * CGFloat(scale)).rounded()), ty1 = Int((r.maxY * CGFloat(scale)).rounded()) - 1
        for (name, c, dir) in [("TL", (tx0, ty0), (1, 1)), ("TR", (tx1, ty0), (-1, 1)), ("BL", (tx0, ty1), (1, -1)), ("BR", (tx1, ty1), (-1, -1))] {
            let kc = diagonalTarget(base, bg: bg, corner: c, dir: dir, max: 40)
            let ko = diagonal(base, t, bg: bg, corner: (c.0 - dir.0 * ins, c.1 - dir.1 * ins), dir: dir, max: 60)
            if let kc, let ko {
                let gapPt = sqrt(2) * Double(ins + kc - ko) / Double(scale)
                corners.append(String(format: "%@ %.1f", name, gapPt))
            } else { corners.append("\(name) ?") }
        }
        log("\(look) step \(cur.index + 1) \(cur.step.id): \(geo)")
        log("   pixels (pt, target edge → cutout edge): " + parts.joined(separator: "  ") + "  ring \(pt(ringW))pt")
        log("   corner diagonal gap (pt; = edge gap when concentric): " + corners.joined(separator: "  "))
        tour.next()
    }
    w.orderOut(nil); w.close()
}

// MARK: Render

@MainActor func render() {
    let store = liveStore()
    let hasBattery = store.battery != nil
    log("battery present: \(hasBattery); scale \(NSScreen.main?.backingScaleFactor ?? 0)")
    for dark in [false, true] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let look = dark ? "dark" : "light"
        // Overview (no tour, no chip)
        do {
            let d = suite(.existing); d.set(TourCatalog.version, forKey: TourKey.seenVersion)
            let tour = TourController(defaults: d, hasBattery: { hasBattery })
            let w = makeWindow(Panel(store: store, tour: tour, defaults: d)); settle(0.8)
            save(capture(w), "overview-\(look)"); w.orderOut(nil); w.close()
        }
        // Chip (existing user)
        do {
            let d = suite(.existing)
            let tour = TourController(defaults: d, hasBattery: { hasBattery }); tour.panelOpened()
            let w = makeWindow(Panel(store: store, tour: tour, defaults: d)); settle(0.8)
            save(capture(w), "chip-\(look)"); w.orderOut(nil); w.close()
        }
        // Welcome (new user) + every step, blurred backdrop
        do {
            let d = suite(.new)
            let tour = TourController(defaults: d, hasBattery: { hasBattery }); tour.panelOpened()
            let w = makeWindow(Panel(store: store, tour: tour, defaults: d)); settle(1.0)
            save(capture(w), "welcome-\(look)")
            tour.start()
            var n = 1
            while tour.currentStep != nil {
                settle(1.0); save(capture(w), "tour\(n)-\(tour.currentStep!.step.id)-\(look)")
                n += 1; tour.next()
            }
            log("\(look): after the last Next, tour active = \(tour.isActive), seenVersion = \(d.object(forKey: TourKey.seenVersion) ?? "nil")")
            w.orderOut(nil); w.close()
        }
        // Settings
        do {
            let d = suite(.existing)
            let w = makeWindow(SettingsView(onTour: {}, onBack: {}).background(PanelBackdrop()).defaultAppStorage(d)); settle(0.8)
            save(capture(w), "settings-\(look)"); w.orderOut(nil); w.close()
        }
        // Breakdowns with live scans
        for metric in [BreakdownMetric.cpu, .memory, .energy] {
            let d = suite(.existing); d.set(true, forKey: TourKey.breakdownMenuUsed)
            store.beginBreakdown(metric: metric)
            let scan = Scan()
            var r = scan.run(metric)
            store.setBreakdown(r.apps, measuring: r.measuring, totalCPU: r.totalCPUPercent)
            let hint = metric == .cpu && !dark
            let w = makeWindow(BreakdownView(store: store, metric: metric, quitHint: hint, onBack: {})
                .background(PanelBackdrop()).defaultAppStorage(d))
            settle(0.5)
            if metric == .cpu { save(capture(w), "breakdown-cpu-measuring-\(look)") }
            for _ in 0..<3 { settle(2); r = scan.run(metric); store.setBreakdown(r.apps, measuring: r.measuring, totalCPU: r.totalCPUPercent) }
            settle(0.6)
            save(capture(w), "breakdown-\(metric)-\(look)")
            // Expand: the app with the most processes among the first five rows (click its row).
            if let target = store.breakdown.prefix(5).filter({ $0.isApp }).max(by: { $0.processes.count < $1.processes.count }),
               target.processes.count > 1, let index = store.breakdown.firstIndex(where: { $0.appPID == target.appPID }) {
                var top: CGFloat = Design.headerHeight + Design.cardSpacing
                if metric == .memory { top += NSHostingView(rootView: MemoryPartsCard(store: store).frame(width: 304)).fittingSize.height + 6 }
                if metric == .energy { top += NSHostingView(rootView: BatteryDetailsCard(store: store).frame(width: 304)).fittingSize.height + 6 }
                click(w, at: CGPoint(x: 120, y: top + 4 + 36 * CGFloat(index) + 18))
                settle(0.8)
                log("\(look) \(metric): expanded row \(index) \(NSRunningApplication(processIdentifier: target.appPID)?.localizedName ?? "?") (\(target.processes.count) processes)")
                save(capture(w), "breakdown-\(metric)-expanded-\(look)")
                // Two more scans with the pointer resting on the expanded app: nothing may move.
                store.breakdownPointerProbe = { BreakdownPointer(inside: true, moved: true, app: target.appPID) }
                let before = store.breakdown.map(\.appPID)
                let beforeKids = store.breakdown.first { $0.appPID == target.appPID }?.processes.map(\.pid) ?? []
                for _ in 0..<2 { settle(2); r = scan.run(metric); store.setBreakdown(r.apps, measuring: r.measuring, totalCPU: r.totalCPUPercent) }
                settle(0.5)
                let after = store.breakdown.map(\.appPID)
                let afterKids = store.breakdown.first { $0.appPID == target.appPID }?.processes.map(\.pid) ?? []
                let k = before.firstIndex(of: target.appPID) ?? 0
                log("   hovering it for 2 scans: rows down to it unchanged = \(Array(before.prefix(k + 1)) == Array(after.prefix(k + 1))), its processes unchanged = \(beforeKids == afterKids)")
                save(capture(w), "breakdown-\(metric)-expanded-hovered-\(look)")
            }
            w.orderOut(nil); w.close()
            store.clearBreakdown()
        }
    }
    // Pixel-measured tour centring (solid backdrop so card edges are measurable).
    for dark in [false, true] { measureTour(dark: dark, store: store) }
    flush("render.txt")
}

// MARK: Live flow (headless)

struct RowLog { var texts: [String] = [] }

@MainActor final class Scenario {
    let name: String
    let store = MetricsStore()
    var pointer: BreakdownPointer? = nil
    init(_ name: String, metric: BreakdownMetric) {
        self.name = name
        store.beginBreakdown(metric: metric)
        store.breakdownPointerProbe = { [unowned self] in self.pointer ?? BreakdownPointer(inside: false, moved: false) }
    }
}

@MainActor func live() {
    let start = Date()
    let base = start.timeIntervalSinceReferenceDate
    let reader = Reader()
    let card = MetricsStore()
    _ = reader.sample()
    let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
    // Card texts and lag.
    var cardTexts: [String: [String]] = ["cpu": [], "mem": [], "down": [], "up": []]
    var rawCPU: [String] = []
    var cpuErr: [Double] = []
    var cardSeries: [(Double, Double, Double)] = []   // t, exact, shown
    let metrics: [BreakdownMetric] = [.cpu, .memory, .energy]
    var scans: [BreakdownMetric: Scan] = [:]
    var scen: [BreakdownMetric: [Scenario]] = [:]
    for m in metrics {
        scans[m] = Scan()
        scen[m] = [Scenario("away", metric: m), Scenario("rest-row3", metric: m), Scenario("on-expanded", metric: m)]
    }
    var apply = [Double]()
    var nextTick = start, nextScan = start
    var burst: Process?
    let burstAt = 50.0, burstLen = 15.0
    var burstT0: Double?, burstT1: Double?
    // Per-scenario tracking.
    struct Track {
        var lastTop: [Int32]? = nil
        var orderChanges = 0, scans = 0
        var swapsBack = 0
        var history: [[Int32]] = []
        var texts: [Int32: [String]] = [:]
        var prefixBroken = 0
        var pinnedApp: Int32? = nil, pinnedPrefix: [Int32]? = nil, pinnedMissing = 0
        var expanded: Int32? = nil, expandedLost = 0, expandedCollapsed = 0
        var kidOrderChanges = 0, lastKids: [Int32]? = nil, kidSetChanges = 0
        var flat: [String]? = nil, flatChanges = 0
        var inversions = 0, invRows = 0, maxInvRun: [String: Int] = [:], invRun: [String: Int] = [:]
        var textChanges = 0, flips = 0
        var endedShown = 0
        var burstLog: [String] = []
    }
    var tracks: [String: Track] = [:]
    func key(_ m: BreakdownMetric, _ s: String) -> String { "\(m)/\(s)" }

    while Date().timeIntervalSince(start) < liveSeconds {
        let now = Date(), t = now.timeIntervalSince(start)
        if burst == nil, t >= burstAt {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
            p.standardOutput = FileHandle.nullDevice
            try? p.run(); burst = p; burstT0 = t
        }
        if let p = burst, p.isRunning, t >= burstAt + burstLen { p.terminate(); burstT1 = t }
        if now >= nextTick {
            if let v = reader.sample(now) {
                card.record(cpuPercent: v.0, memory: v.1, network: v.2, time: now.timeIntervalSinceReferenceDate)
                cardTexts["cpu"]!.append("\(Int(card.cardCPUPercent.rounded()))%")
                rawCPU.append("\(Int(v.0.rounded()))%")
                if let m = card.cardMemory { cardTexts["mem"]!.append(String(format: "%.1f", Double(m.usedBytes) / 1_073_741_824)) }
                if let n = card.cardNetwork {
                    cardTexts["down"]!.append(formattedRate(bytesPerSecond: n.downBytesPerSec))
                    cardTexts["up"]!.append(formattedRate(bytesPerSecond: n.upBytesPerSec))
                }
                cpuErr.append(abs(card.cardCPUPercent - v.0))
                cardSeries.append((t, v.0, card.cardCPUPercent))
            }
            nextTick = nextTick.addingTimeInterval(0.5)
        }
        if now >= nextScan {
            for m in metrics {
                let r = scans[m]!.run(m)
                for s in scen[m]! {
                    let k = key(m, s.name)
                    var tr = tracks[k] ?? Track()
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    s.store.setBreakdown(r.apps, measuring: r.measuring, totalCPU: r.totalCPUPercent, time: now.timeIntervalSinceReferenceDate)
                    apply.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e3)
                    guard !s.store.breakdownMeasuring else { tracks[k] = tr; continue }
                    let rows = s.store.breakdown
                    let ids = rows.map(\.appPID)
                    tr.scans += 1
                    // Choose the expanded app (most processes among first 5) and the pinned row (index 2) once.
                    if tr.expanded == nil, tr.scans >= 2 {
                        tr.expanded = rows.prefix(5).filter { $0.isApp && $0.processes.count > 1 }.max { $0.processes.count < $1.processes.count }?.appPID
                        if s.name == "rest-row3", rows.count > 3 {
                            tr.pinnedApp = ids[2]
                            s.pointer = BreakdownPointer(inside: true, moved: true, app: ids[2])
                            tr.pinnedPrefix = Array(ids.prefix(3))
                        }
                        if s.name == "on-expanded", let e = tr.expanded {
                            s.pointer = BreakdownPointer(inside: true, moved: true, app: e)
                            tr.pinnedApp = e
                            tr.pinnedPrefix = Array(ids.prefix((ids.firstIndex(of: e) ?? 0) + 1))
                        }
                    } else if let pin = tr.pinnedApp, let pre = tr.pinnedPrefix {
                        if !ids.contains(pin) { tr.pinnedMissing += 1 }
                        if Array(ids.prefix(pre.count)) != pre { tr.prefixBroken += 1 }
                    }
                    let top = Array(ids.prefix(8))
                    if let last = tr.lastTop, last != top {
                        tr.orderChanges += 1
                        if tr.history.count >= 2, tr.history.suffix(3).contains(top) { tr.swapsBack += 1 }
                    }
                    tr.lastTop = top
                    tr.history.append(top)
                    // Printed text per top-8 row.
                    for a in rows.prefix(8) {
                        let v = s.store.shownValue(app: a.appPID) ?? a.value(for: m)
                        let txt = s.store.isEnded(app: a.appPID) ? "Ended" : breakdownValueText(m, v)
                        var h = tr.texts[a.appPID] ?? []
                        if let l = h.last, l != txt {
                            tr.textChanges += 1
                            if h.count >= 2, h[h.count - 2] == txt { tr.flips += 1 }
                        }
                        h.append(txt); tr.texts[a.appPID] = h
                        if s.store.isEnded(app: a.appPID) { tr.endedShown += 1 }
                    }
                    // Visible inversions among the first 8 app rows (same class: apps vs groups not mixed for memory).
                    let printed = rows.prefix(8).map { s.store.shownValue(app: $0.appPID) ?? $0.value(for: m) }
                    var inv = 0
                    for i in 1..<max(1, printed.count) where printed[i] > printed[i - 1] && breakdownValueText(m, printed[i]) != breakdownValueText(m, printed[i - 1]) {
                        if m == .memory, (rows[i].appPID < 0) != (rows[i - 1].appPID < 0) { continue }
                        inv += 1
                        let pk = "\(rows[i - 1].appPID)>\(rows[i].appPID)"
                        tr.invRun[pk, default: 0] += 1
                        tr.maxInvRun[pk] = max(tr.maxInvRun[pk] ?? 0, tr.invRun[pk]!)
                    }
                    if inv == 0 { tr.invRun = [:] }
                    if inv > 0 { tr.inversions += 1; tr.invRows += inv }
                    // Expanded app.
                    if let e = tr.expanded {
                        if let app = rows.first(where: { $0.appPID == e }) {
                            if app.processes.count <= 1 { tr.expandedCollapsed += 1 }
                            let kids = Array(app.processes.prefix(5).map(\.pid))
                            if let lk = tr.lastKids, lk != kids {
                                if Set(lk) == Set(kids) { tr.kidOrderChanges += 1 } else { tr.kidSetChanges += 1 }
                            }
                            tr.lastKids = kids
                        } else { tr.expandedLost += 1 }
                    }
                    let flat = Array(BreakdownList.rows(rows, expanded: tr.expanded, visible: 5).prefix(9).map(\.id))
                    if let f = tr.flat, f != flat { tr.flatChanges += 1 }
                    tr.flat = flat
                    // Burst row (CPU, away).
                    if m == .cpu, s.name == "away", let p = burst, let b0 = burstT0, t >= b0 - 4, t <= b0 + burstLen + 20 {
                        if let i = rows.firstIndex(where: { $0.processes.contains { $0.pid == p.processIdentifier } }) {
                            let v = s.store.shownValue(app: rows[i].appPID) ?? 0
                            tr.burstLog.append(String(format: "t=%5.1f burst app row #%d %@  header %@  card %d%%", t, i + 1,
                                                      breakdownValueText(.cpu, v),
                                                      s.store.breakdownShownTotalCPU.map { "\(Int($0.rounded()))%" } ?? "-",
                                                      Int(card.cardCPUPercent.rounded())))
                        } else {
                            let fin = rows.compactMap { a -> String? in
                                guard let f = a.processes.first(where: { $0.pid == BreakdownGroup.exitedProcesses }) else { return nil }
                                return "\(a.appPID):\(breakdownValueText(.cpu, s.store.shownValue(app: a.appPID, pid: f.pid) ?? f.cpuPercent))"
                            }
                            tr.burstLog.append(String(format: "t=%5.1f burst process not listed; finished rows %@; header %@ card %d%%", t,
                                                      fin.joined(separator: ","),
                                                      s.store.breakdownShownTotalCPU.map { "\(Int($0.rounded()))%" } ?? "-",
                                                      Int(card.cardCPUPercent.rounded())))
                        }
                    }
                    tracks[k] = tr
                }
            }
            nextScan = nextScan.addingTimeInterval(breakdownScanInterval)
        }
        RunLoop.current.run(until: min(nextTick, nextScan))
    }
    burst?.terminate()

    let mins = liveSeconds / 60
    func changes(_ a: [String]) -> (Int, Int) {
        var c = 0, f = 0
        for i in 1..<max(1, a.count) where a[i] != a[i - 1] {
            c += 1
            if i >= 2, a[i] == a[i - 2] { f += 1 }
        }
        return (c, f)
    }
    log(String(format: "LIVE %.0f s on %d cores; burst: yes from t=%.1f to t=%.1f", liveSeconds, Int(cores), burstT0 ?? -1, burstT1 ?? -1))
    for k in ["cpu", "mem", "down", "up"] {
        let (c, f) = changes(cardTexts[k]!)
        log(String(format: "card %-4@ printed changes %3d (%.1f/min), A-B-A flips %d, samples %d", k, c, Double(c) / mins, f, cardTexts[k]!.count))
    }
    let (rc, rf) = changes(rawCPU)
    log(String(format: "card cpu WITHOUT hold (raw 2 s reading rounded): changes %d (%.1f/min), flips %d", rc, Double(rc) / mins, rf))
    let se = cpuErr.sorted()
    log(String(format: "card cpu |shown-exact| pp: median %.2f p95 %.2f max %.2f", se[se.count / 2], se[Int(Double(se.count) * 0.95)], se.last ?? 0))
    if let b0 = burstT0 {
        let pre = cardSeries.filter { $0.0 >= b0 - 3 && $0.0 < b0 }.map(\.2)
        let level = (pre.reduce(0, +) / Double(max(1, pre.count))) + 100 / cores * 0.7
        let up = cardSeries.first { $0.0 >= b0 && $0.2 >= level }
        let b1 = burstT1 ?? (b0 + burstLen)
        let down = cardSeries.first { $0.0 >= b1 && $0.2 < level }
        log(String(format: "card: burst t=%.1f..%.1f; card first >= %.0f%% at t=%@, back below at t=%@", b0, b1, level,
                   up.map { String(format: "%.1f", $0.0) } ?? "never", down.map { String(format: "%.1f", $0.0) } ?? "never"))
        for s in cardSeries where s.0 >= b0 - 2 && s.0 <= b0 + burstLen + 5 && Int(s.0 * 2) % 2 == 0 {
            log(String(format: "   t=%5.1f exact %5.1f shown %3.0f", s.0, s.1, s.2))
        }
    }
    for m in metrics {
        for name in ["away", "rest-row3", "on-expanded"] {
            guard let tr = tracks[key(m, name)] else { continue }
            let sm = Double(tr.scans) * breakdownScanInterval / 60
            log("--- \(m) / pointer \(name): scans \(tr.scans)")
            log(String(format: "  top-8 order changes %d (%.1f/min), changes undone within 2 scans %d", tr.orderChanges, Double(tr.orderChanges) / sm, tr.swapsBack))
            log(String(format: "  top-8 printed value changes %d (%.1f/min, %.2f/row/min), A-B-A flips %d", tr.textChanges, Double(tr.textChanges) / sm, Double(tr.textChanges) / sm / 8, tr.flips))
            log("  scans with a visibly unsorted pair in top 8: \(tr.inversions) (pairs \(tr.invRows)); longest a pair stayed inverted: \(tr.maxInvRun.values.max() ?? 0) scans")
            log("  expanded app \(tr.expanded.map { "\($0) (\(NSRunningApplication(processIdentifier: $0)?.localizedName ?? "?"))" } ?? "none"): missing \(tr.expandedLost) scans, <=1 process (view collapses) \(tr.expandedCollapsed); first-5 process order changes \(tr.kidOrderChanges), set changes \(tr.kidSetChanges)")
            log("  first 9 visible rows (with expanded app) changed \(tr.flatChanges) times; 'Ended' placeholders shown \(tr.endedShown)")
            if let pin = tr.pinnedApp {
                log("  POINTER on app \(pin) (\(NSRunningApplication(processIdentifier: pin)?.localizedName ?? "?")): scans where rows down to it moved \(tr.prefixBroken), scans where it was missing \(tr.pinnedMissing)")
            }
            for l in tr.burstLog { log("  " + l) }
        }
    }
    let sa = apply.sorted(), ss = scans.values.flatMap(\.ms).sorted()
    log(String(format: "cost: MetricsStore.setBreakdown median %.0f µs p95 %.0f µs; scan median %.1f ms p95 %.1f ms", sa[sa.count / 2], sa[Int(Double(sa.count) * 0.95)], ss[ss.count / 2], ss[Int(Double(ss.count) * 0.95)]))
    flush("live.txt")
}

// MARK: Cost (tour off vs on)

@MainActor func cost() {
    let store = liveStore()
    let reader = Reader(); _ = reader.sample()
    func cpuSeconds() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }
    for on in [false, true, false, true] {
        let d = suite(.existing); d.set(TourCatalog.version, forKey: TourKey.seenVersion)
        let tour = TourController(defaults: d, hasBattery: { store.battery != nil })
        let w = makeWindow(Panel(store: store, tour: tour, defaults: d))
        if on { tour.start() }
        settle(1)
        let c0 = cpuSeconds(), t0 = Date()
        while Date().timeIntervalSince(t0) < 15 {
            if let v = reader.sample() { store.record(cpuPercent: v.0, memory: v.1, network: v.2) }
            settle(0.5)
        }
        let used = cpuSeconds() - c0
        log(String(format: "overview live 15 s, tour %@: %.2f %% of one core", on ? "ON (step 1)" : "off", used / 15 * 100))
        w.orderOut(nil); w.close()
    }
    flush("cost.txt")
}

// A background accessory process with only ordered-back windows gets App Napped: run-loop waits
// stretched to minutes. Opt out for the probe's lifetime.
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
                                                     reason: "review probe")
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    switch mode {
    case "live": live()
    case "cost": cost()
    case "measure":
        let store = liveStore()
        for dark in [false, true] { measureTour(dark: dark, store: store) }
        flush("measure.txt")
    default: render()
    }
    dropSuites()
    print("done")
}

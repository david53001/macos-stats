// Review round 3 fixes: reviewer B's round-3 probe (docs/reviews/2026-10-06-stability-tour/r3-B/probe-src),
// unchanged apart from the second scan's delay (one scan interval since round 3; FIRST_RESCAN for older
// checkouts). Reviewer B (round 3) probe. Renders the REAL MacStats views off-screen (desktop level + 1, ordered
// back, never activated) and runs the real MetricsStore + BreakdownScanner headlessly.
// Modes: render <outDir> | stability <seconds> | cost
import AppKit
import SwiftUI
import Darwin
import MacStatsCore

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "render"
let outDir = args.count > 2 ? args[2] : "out"

// MARK: - Shared helpers

nonisolated(unsafe) var anchorRects: [String: CGRect] = [:]

struct AnchorReader: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(TourAnchorKey.self) { anchors in
            GeometryReader { proxy in
                let _ = { for (id, a) in anchors { anchorRects[id] = proxy[a.bounds] } }()
                Color.clear
            }
        }
    }
}

/// RootView's composition of the overview, minus AppModel.
struct Panel: View {
    @ObservedObject var store: MetricsStore
    @ObservedObject var tour: TourController
    let defaults: UserDefaults
    var host = true
    var body: some View {
        let o = OverviewView(store: store, onSelect: { _ in }, onEmptyTrash: {}, onSettings: {},
                             offersTour: tour.offersTour, onTour: { tour.start() }, onDismissOffer: { tour.dismissOffer() })
            .frame(width: Design.panelWidth, height: Design.panelHeight)
        Group { if host { o.tourHost(tour, showing: true).modifier(AnchorReader()) } else { o } }
            .clipped().background(PanelBackdrop()).defaultAppStorage(defaults)
    }
}

@MainActor func makeStore(battery: BatterySample? = BatterySample(percent: 72, state: .discharging, timeToEmptyMinutes: 312)) -> MetricsStore {
    let s = MetricsStore()
    let now = Date().timeIntervalSinceReferenceDate
    for i in 0..<120 {
        let t = now - 60 + Double(i) * 0.5
        let mem = MemorySample(usedBytes: 12_100_000_000, totalBytes: 17_179_869_184, pressure: .normal,
                               appBytes: 7_600_000_000, wiredBytes: 2_500_000_000, compressedBytes: 2_000_000_000,
                               compressedDataBytes: 5_600_000_000)
        s.record(cpuPercent: 18 + 9 * sin(Double(i) / 6) + Double(i % 4), memory: mem,
                 network: NetworkSample(downBytesPerSec: 240_000 + 160_000 * sin(Double(i) / 5), upBytesPerSec: 31_000),
                 time: t)
    }
    s.setBattery(battery)
    s.setBatteryTelemetry(BatteryTelemetry(updateTime: 0, nominalMAh: 4_300, designMAh: 4_563, cycleCount: 187,
                                           temperatureC: 30.6), powerWatts: 5.9, averageWatts: 6.6, averageSinceUnplug: true)
    s.setCPUTemperature(46)
    s.setTrashBytes(1_310_000_000)
    return s
}

@MainActor func settle(_ s: Double) {
    let end = Date().addingTimeInterval(s)
    while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
}

@MainActor func makeWindow<V: View>(_ view: V) -> NSWindow {
    let frame = NSRect(x: 0, y: 0, width: Design.panelWidth, height: Design.panelHeight)
    let host = NSHostingView(rootView: view.frame(width: Design.panelWidth, height: Design.panelHeight))
    host.frame = frame
    let fx = NSVisualEffectView(frame: frame)
    fx.material = .popover; fx.state = .active; fx.blendingMode = .behindWindow
    fx.wantsLayer = true
    fx.layer?.cornerRadius = Design.panelCornerRadius; fx.layer?.cornerCurve = .continuous; fx.layer?.masksToBounds = true
    fx.addSubview(host)
    let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.isReleasedWhenClosed = false
    w.contentView = fx
    w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
    w.setFrameOrigin(NSPoint(x: 60, y: 60))
    w.orderBack(nil)
    return w
}

@MainActor func capture(_ w: NSWindow) -> CGImage? {
    if let i = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber),
                                       [.boundsIgnoreFraming, .bestResolution]) { return i }
    guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
    v.cacheDisplay(in: v.bounds, to: rep); return rep.cgImage
}

func save(_ img: CGImage?, _ name: String) {
    guard let img else { print("capture failed", name); return }
    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    print("wrote", name, img.width, img.height)
}

@MainActor func shoot<V: View>(_ name: String, _ v: V, wait: Double = 0.9) {
    let w = makeWindow(v); settle(wait); save(capture(w), name); w.orderOut(nil); w.close()
}

struct Px {
    let w: Int, h: Int; var d: [UInt8]
    init(_ img: CGImage) {
        w = img.width; h = img.height; d = [UInt8](repeating: 0, count: w * h * 4)
        let c = CGContext(data: &d, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    func at(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * w + x) * 4; return (Int(d[i]), Int(d[i+1]), Int(d[i+2])) }
    func lum(_ x: Int, _ y: Int) -> Double { let c = at(x, y); return 0.299 * Double(c.0) + 0.587 * Double(c.1) + 0.114 * Double(c.2) }
}
func dist(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int { max(abs(a.0-b.0), abs(a.1-b.1), abs(a.2-b.2)) }
/// "Blue-ish accent": blue channel clearly dominant.
func isAccent(_ c: (Int, Int, Int)) -> Bool { c.2 > 150 && c.2 - c.0 > 70 && c.2 - c.1 > 25 }

var log: [String] = []
func say(_ s: String) { print(s); log.append(s) }

func suiteNamed() -> (String, UserDefaults) {
    let n = "MacStatsReviewR3B-\(UUID().uuidString)"
    return (n, UserDefaults(suiteName: n)!)
}
func drop(_ n: String) {
    UserDefaults.standard.removePersistentDomain(forName: n)
    CFPreferencesAppSynchronize(n as CFString)
    Thread.sleep(forTimeInterval: 0.3)
    try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(n).plist"))
}

// MARK: - Render

/// Walks from the card edge outward along one axis in the tour image (and the base image): returns
/// (px of unchanged pixels = clear gap, px of accent ring, px where the dim starts).
func walk(_ base: Px, _ tour: Px, x0: Int, y0: Int, dx: Int, dy: Int) -> (gap: Int, ring: Int) {
    var x = x0, y = y0, gap = 0, ring = 0
    while x >= 0, y >= 0, x < tour.w, y < tour.h, dist(base.at(x, y), tour.at(x, y)) <= 6 { gap += 1; x += dx; y += dy }
    while x >= 0, y >= 0, x < tour.w, y < tour.h, isAccent(tour.at(x, y)) || (ring < 6 && dist(base.at(x,y), tour.at(x,y)) > 6 && ring < 1) {
        ring += 1; x += dx; y += dy
    }
    return (gap, ring)
}

@MainActor func measureStep(_ name: String, base: CGImage, tour: CGImage, id: String) {
    guard let t = anchorRects[id] else { say("\(name): anchor \(id) missing"); return }
    let b = Px(base), p = Px(tour)
    let s = CGFloat(b.w) / Design.panelWidth
    let panel = CGRect(x: 0, y: 0, width: Design.panelWidth, height: Design.panelHeight)
    let cut = TourLayout.cutout(target: t, targetRadius: Design.cardCornerRadius, panel: panel, scale: s)
    let geo = (L: t.minX - cut.rect.minX, R: cut.rect.maxX - t.maxX, T: t.minY - cut.rect.minY, B: cut.rect.maxY - t.maxY)
    let mx = Int(t.midX * s), my = Int(t.midY * s)
    let l = walk(b, p, x0: Int((t.minX * s).rounded()) - 1, y0: my, dx: -1, dy: 0)
    let r = walk(b, p, x0: Int((t.maxX * s).rounded()), y0: my, dx: 1, dy: 0)
    let top = walk(b, p, x0: mx, y0: Int((t.minY * s).rounded()) - 1, dx: 0, dy: -1)
    let bot = walk(b, p, x0: mx, y0: Int((t.maxY * s).rounded()), dx: 0, dy: 1)
    func pt(_ px: Int) -> String { String(format: "%.1f", Double(px) / Double(s)) }
    // Dim darkness in a strip just outside each side of the cutout (tour/base luminance), 3 pt deep.
    func strip(_ rect: CGRect) -> String {
        let r = rect.intersection(panel)
        guard r.width > 0.5, r.height > 0.5 else { return "n/a" }
        var tb = 0.0, bb = 0.0
        for y in Int(r.minY * s)..<Int(r.maxY * s) { for x in Int(r.minX * s)..<Int(r.maxX * s) { tb += p.lum(x, y); bb += b.lum(x, y) } }
        return String(format: "%.3f", bb > 0 ? tb / bb : 0)
    }
    let c = cut.rect
    let sT = strip(CGRect(x: c.minX + 20, y: c.minY - 3, width: c.width - 40, height: 3))
    let sB = strip(CGRect(x: c.minX + 20, y: c.maxY, width: c.width - 40, height: 3))
    let sL = strip(CGRect(x: c.minX - 3, y: c.minY + 12, width: 3, height: max(0, c.height - 24)))
    let sR = strip(CGRect(x: c.maxX, y: c.minY + 12, width: 3, height: max(0, c.height - 24)))
    say("\(name): card=(\(t.minX),\(t.minY),\(t.width)x\(t.height)) cutout=(\(c.minX),\(c.minY),\(c.width)x\(c.height)) r=\(cut.radius) "
        + "geom insets L/R/T/B=\(geo.L)/\(geo.R)/\(geo.T)/\(geo.B)pt | pixels clear-gap L/R/T/B=\(pt(l.gap))/\(pt(r.gap))/\(pt(top.gap))/\(pt(bot.gap))pt "
        + "ring L/R/T/B=\(pt(l.ring))/\(pt(r.ring))/\(pt(top.ring))/\(pt(bot.ring))pt "
        + "-> hole edge L/R/T/B=\(pt(l.gap+l.ring))/\(pt(r.gap+r.ring))/\(pt(top.gap+top.ring))/\(pt(bot.gap+bot.ring))pt | dim strip T/B/L/R=\(sT)/\(sB)/\(sL)/\(sR)")
}

final class Scan {
    let scanner = BreakdownScanner()
    func run(_ m: BreakdownMetric) -> BreakdownScanner.Result {
        let a = attributionAnchors(NSWorkspace.shared.runningApplications.map {
            RunningAppInfo(pid: Int32($0.processIdentifier), hasBundleIdentifier: $0.bundleIdentifier != nil,
                           isBackgroundOnly: $0.activationPolicy == .prohibited) })
        let time = Date().timeIntervalSinceReferenceDate, abs = mach_absolute_time(), ticks = readCPUTicks()
        let raw = readRawProcesses(includeEnergy: m == .energy)
        return scanner.scan(raw, appPIDs: a.apps, fallbackAppPIDs: a.fallbacks, metric: m, time: time, absTime: abs, cpuTicks: ticks)
    }
}

@MainActor func click(_ w: NSWindow, at p: CGPoint) {
    guard let host = w.contentView?.subviews.first else { return }
    let loc = NSPoint(x: p.x, y: Design.panelHeight - p.y)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                   pressure: type == .leftMouseDown ? 1 : 0)!
        NSApp.postEvent(e, atStart: true)
        _ = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true)
        let target = host.hitTest(host.superview!.convert(loc, from: nil)) ?? host
        if type == .leftMouseDown { target.mouseDown(with: e) } else { target.mouseUp(with: e) }
        settle(0.08)
    }
}

@MainActor func render() {
    let (sn, d) = suiteNamed()
    defer { drop(sn) }
    d.set(TourAudience.existing.rawValue, forKey: TourKey.audience)
    d.set(true, forKey: TourKey.breakdownMenuUsed)
    for dark in [false, true] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let look = dark ? "dark" : "light"
        // Overview + every tour step in one window.
        let store = makeStore()
        let tour = TourController(defaults: d, hasBattery: { true })
        let w = makeWindow(Panel(store: store, tour: tour, defaults: d))
        settle(1)
        guard let base = capture(w) else { return }
        save(base, "overview-\(look)")
        tour.start()
        for (i, step) in TourCatalog.steps.enumerated() {
            settle(1.0)
            let img = capture(w)
            save(img, "tour\(i + 1)-\(step.id.rawValue)-\(look)")
            if let img { measureStep("step\(i + 1) \(step.id.rawValue) \(look)", base: base, tour: img, id: step.anchor) }
            tour.next()
        }
        say("after Done: phase=\(tour.state.phase) seen=\(d.object(forKey: TourKey.seenVersion) ?? "nil")")
        // Click-through: start again, click the CPU card inside the cutout.
        d.removeObject(forKey: TourKey.seenVersion)
        w.orderOut(nil); w.close()

        // No battery: progress and last step.
        let nb = makeStore(battery: nil)
        let nt = TourController(defaults: d, hasBattery: { false })
        let nw = makeWindow(Panel(store: nb, tour: nt, defaults: d))
        settle(0.8)
        if let nbase = capture(nw) {
            save(nbase, "overview-nobattery-\(look)")
            nt.start(); nt.next(); nt.next(); nt.next()
            settle(1)
            if let img = capture(nw) {
                save(img, "tour-nobattery-last-\(look)")
                measureStep("nobattery last \(look)", base: nbase, tour: img, id: "overview.footer")
            }
            say("nobattery progress=\(nt.progress.map { "\($0.number) of \($0.total)" } ?? "nil")")
        }
        nw.orderOut(nil); nw.close()

        // Welcome (new user).
        let (wn, wd) = suiteNamed()
        wd.set(TourAudience.new.rawValue, forKey: TourKey.audience)
        let wt = TourController(defaults: wd, hasBattery: { true })
        wt.panelOpened()
        say("welcome phase=\(wt.state.phase) defers=\(wt.defersPermissionPrompts)")
        shoot("welcome-\(look)", Panel(store: makeStore(), tour: wt, defaults: wd), wait: 1.1)
        drop(wn)
        // Existing-user chip.
        let (cn, cd) = suiteNamed()
        cd.set(TourAudience.existing.rawValue, forKey: TourKey.audience)
        let ct = TourController(defaults: cd, hasBattery: { true })
        ct.panelOpened()
        shoot("chip-\(look)", Panel(store: makeStore(), tour: ct, defaults: cd))
        drop(cn)
        // Settings.
        shoot("settings-\(look)", SettingsView(onBack: {}).frame(width: Design.panelWidth, height: Design.panelHeight)
            .background(PanelBackdrop()).defaultAppStorage(d))

        // Breakdowns with real scans, then click the row of the app with the most processes.
        for metric in [BreakdownMetric.cpu, .memory, .energy] {
            let bs = makeStore()
            if metric == .energy {
                bs.setBattery(BatterySample(percent: 72, state: .discharging, timeToEmptyMinutes: 312))
            }
            bs.beginBreakdown(metric: metric)
            let sc = Scan()
            var r = sc.run(metric)
            bs.setBreakdown(r.apps, measuring: r.measuring, totalCPU: r.totalCPUPercent)
            if metric == .cpu && !dark {
                shoot("breakdown-cpu-measuring-light", BreakdownView(store: bs, metric: metric, quitHint: true, onBack: {})
                    .background(PanelBackdrop()).defaultAppStorage(d), wait: 0.6)
            }
            settle(0.5); r = sc.run(metric); bs.setBreakdown(r.apps, measuring: r.measuring, totalCPU: r.totalCPUPercent)
            settle(2); r = sc.run(metric); bs.setBreakdown(r.apps, measuring: r.measuring, totalCPU: r.totalCPUPercent)
            let w = makeWindow(BreakdownView(store: bs, metric: metric, quitHint: false, onBack: {})
                .background(PanelBackdrop()).defaultAppStorage(d))
            settle(1)
            save(capture(w), "breakdown-\(metric)-\(look)")
            let top = bs.breakdown.prefix(6)
            if let target = top.filter({ $0.processes.count > 1 }).max(by: { $0.processes.count < $1.processes.count }),
               let index = bs.breakdown.firstIndex(where: { $0.appPID == target.appPID }) {
                var y: CGFloat = 36
                if metric == .memory { y += NSHostingView(rootView: MemoryPartsCard(store: bs).frame(width: 304)).fittingSize.height + 6 }
                if metric == .energy { y += NSHostingView(rootView: BatteryDetailsCard(store: bs).frame(width: 304)).fittingSize.height + 6 }
                click(w, at: CGPoint(x: 120, y: y + 4 + 36 * CGFloat(index) + 18))
                settle(0.9)
                save(capture(w), "breakdown-\(metric)-expanded-\(look)")
                say("\(metric) \(look): clicked row \(index) (\(target.processes.count) processes)")
            }
            w.orderOut(nil); w.close()
        }
    }
    try? (log.joined(separator: "\n") + "\n").write(toFile: "\(outDir)/render-log.txt", atomically: true, encoding: .utf8)
}

// MARK: - Stability (headless, real scans)

struct Track {
    var last: String?, prev: String?, changes = 0, flips = 0
    mutating func see(_ s: String) {
        if let l = last, l != s { changes += 1; if s == prev { flips += 1 }; prev = l }
        last = s
    }
}

func nm(_ k: Int32) -> String {
    k == -1 ? "Other processes" : k == -2 ? "System" : NSRunningApplication(processIdentifier: k)?.localizedName ?? "pid\(k)"
}

@MainActor final class Run {
    enum Pointer { case away, hover(from: Double, to: Double), still }
    let name: String, metric: BreakdownMetric, pointer: Pointer
    let store = MetricsStore()
    let scan = Scan()
    var inside = false
    var expanded: Int32?
    var expandWanted: Int32?
    var lastTop8: [Int32]?
    var orderChanges = 0, top3Changes = 0, countedSeconds = 0.0, lastT: Double?
    var orderLog: [String] = []
    var texts: [Int32: Track] = [:]
    var childTexts: [Int32: Track] = [:]
    var freezeStart: [String]?
    var frozenShifts = 0, frozenInserted = 0, frozenScans = 0, frozenRemoved = 0
    var shiftLog: [String] = []
    var collapses = 0, expandedVanished = 0
    var topRowChanges: [Double] = []
    var lastTopRow: Int32?
    var errSteps: [Double] = []
    var missorts = 0, scans = 0, invScans = 0
    var childOrderChangesUnfrozen = 0, lastKids: [Int32]?

    init(_ name: String, _ m: BreakdownMetric, _ p: Pointer) {
        self.name = name; metric = m; pointer = p
        store.beginBreakdown(metric: m)
        store.breakdownPointerProbe = { [unowned self] in
            switch self.pointer {
            case .still: return BreakdownPointer(inside: true, moved: false)
            default: return BreakdownPointer(inside: self.inside, moved: true)
            }
        }
    }

    func tick(now: Date, t: Double) {
        if case .hover(let a, let b) = pointer {
            let want = t >= a && t < b
            if want != inside { inside = want; store.setBreakdownPointerInside(want, time: now.timeIntervalSinceReferenceDate) }
        }
        let r = scan.run(metric)
        store.setBreakdown(r.apps, measuring: r.measuring, totalCPU: r.totalCPUPercent, time: now.timeIntervalSinceReferenceDate)
        guard !store.breakdownMeasuring else { return }
        let rows = store.breakdown
        let ids = rows.map(\.appPID)
        if expanded == nil, let want = expandWanted, rows.contains(where: { $0.appPID == want && $0.processes.count > 1 }) {
            expanded = want
        }
        // BreakdownView's onChange: collapse when the expanded app is gone or down to one process.
        if let e = expanded {
            let c = rows.first { $0.appPID == e }?.processes.count ?? 0
            if c <= 1 { collapses += 1; if c == 0 { expandedVanished += 1 }; expanded = nil
                shiftLog.append(String(format: "t=%.1f expanded app collapsed (processes=%d)", t, c)) }
        }
        let flat = BreakdownList.rows(rows, expanded: expanded, visible: BreakdownList.initialChildren).map(\.id)
        let frozenNow: Bool = { if case .hover = pointer { return inside }; return false }()
        if frozenNow {
            frozenScans += 1
            if let start = freezeStart {
                for (i, id) in start.enumerated() {
                    if let j = flat.firstIndex(of: id) {
                        if j != i { frozenShifts += 1; if shiftLog.count < 12 { shiftLog.append(String(format: "t=%.1f row %@ moved %d→%d", t, id, i, j)) } }
                    } else { frozenRemoved += 1 }
                }
                // Rows that appeared above the end of the frozen list.
                for (j, id) in flat.enumerated() where !start.contains(id) && j < start.count {
                    frozenInserted += 1
                    if shiftLog.count < 12 { shiftLog.append(String(format: "t=%.1f new row %@ inserted at %d (of %d)", t, id, j, start.count)) }
                }
                freezeStart = flat   // compare scan to scan
            } else { freezeStart = flat }
        } else { freezeStart = nil }

        if case .still = pointer {
            if let lt = lastTopRow, lt != ids.first { topRowChanges.append(t) }
            lastTopRow = ids.first
        }
        let unfreezeTail: Bool = { if case .hover(_, let b) = pointer { return t >= b && t < b + 3 }; return false }()
        let top8 = Array(ids.prefix(8))
        if !frozenNow && !unfreezeTail {
            if let l = lastTop8, l != top8 { orderChanges += 1
                if Array(l.prefix(3)) != Array(top8.prefix(3)) { top3Changes += 1 }
                if orderLog.count < 10 {
                    let vals = rows.prefix(8).map { breakdownValueText(metric, store.shownValue(app: $0.appPID) ?? 0) }
                    orderLog.append(String(format: "t=%.1f ", t) + zip(top8, vals).map { "\(nm($0.0)) \($0.1)" }.joined(separator: " | "))
                }
            }
            if let lt = lastT { countedSeconds += t - lt }
            scans += 1
            let shown = rows.prefix(8).map { store.shownValue(app: $0.appPID) ?? $0.value(for: metric) }
            var inv = false
            for i in 1..<max(1, shown.count) where !(metric == .memory && (rows[i].appPID < 0) != (rows[i-1].appPID < 0)) {
                if breakdownValueText(metric, shown[i]) != breakdownValueText(metric, shown[i-1]) && shown[i] > shown[i-1] { inv = true }
            }
            if inv { invScans += 1 }
            for (i, app) in rows.prefix(8).enumerated() {
                texts[app.appPID, default: Track()].see(breakdownValueText(metric, shown[i]))
                let exact = app.value(for: metric)
                errSteps.append(abs(shown[i] - exact) / breakdownValueStep(metric, exact))
                if i > 0 {
                    let a = shown[i - 1], b = shown[i]
                    let groupEdge = metric == .memory && (app.appPID < 0) != (rows[i - 1].appPID < 0)
                    if !groupEdge, b > a * 1.25, b - a > 2 * breakdownValueStep(metric, b) { missorts += 1 }
                }
            }
            if let e = expanded, let app = rows.first(where: { $0.appPID == e }) {
                let kids = Array(app.processes.prefix(5).map(\.pid))
                if let lk = lastKids, lk != kids { childOrderChangesUnfrozen += 1 }
                lastKids = kids
                for p in app.processes.prefix(5) {
                    childTexts[p.pid, default: Track()].see(breakdownValueText(metric, store.shownValue(app: e, pid: p.pid) ?? 0))
                }
            }
        }
        lastTop8 = top8
        lastT = t
    }

    func report() {
        let m = max(countedSeconds, 1) / 60
        let tc = texts.values.reduce(0) { $0 + $1.changes }, tf = texts.values.reduce(0) { $0 + $1.flips }
        let cc = childTexts.values.reduce(0) { $0 + $1.changes }, cf = childTexts.values.reduce(0) { $0 + $1.flips }
        let e = errSteps.sorted()
        print("[\(name)] counted \(Int(countedSeconds)) s unfrozen, \(scans) scans")
        print(String(format: "  top-3 order changes/min = %.1f; scans with a visible inversion in top 8 (printed lower above printed higher) = %d/%d", Double(top3Changes) / m, invScans, scans))
        print(String(format: "  top-8 order changes/min = %.1f; top-8 row-text changes/min = %.1f (flip-backs %.1f/min); missorted pairs = %d",
                     Double(orderChanges) / m, Double(tc) / m, Double(tf) / m, missorts))
        if !e.isEmpty { print(String(format: "  held-vs-exact, printed steps: p50 %.2f p95 %.2f max %.2f", e[e.count/2], e[Int(Double(e.count) * 0.95)], e.last!)) }
        if let x = expanded ?? expandWanted { print("  expanded app: \(nm(x)); child top-5 order changes (unfrozen) = \(childOrderChangesUnfrozen); child text changes \(cc) (flip-backs \(cf))") }
        if case .hover = pointer {
            print("  frozen scans=\(frozenScans) shifted-rows=\(frozenShifts) inserted-mid-list=\(frozenInserted) removed=\(frozenRemoved) collapses=\(collapses) vanished=\(expandedVanished)")
        }
        if case .still = pointer { print("  top row changed at t = \(topRowChanges.map { String(format: "%.1f", $0) })") }
        for l in shiftLog { print("   " + l) }
        if name.hasSuffix("away") { for l in orderLog { print("   order " + l) } }
        let order = store.breakdown.prefix(6).map { "\(nm($0.appPID)) \(breakdownValueText(metric, store.shownValue(app: $0.appPID) ?? 0))" }
        print("  final top 6: \(order.joined(separator: " · "))")
    }
}

struct Snap { let time: Date; let cpu: CPUTicks; let net: NetCounters }

@MainActor func stability(seconds total: Double) {
    let me = getpid()
    // Which row holds this probe (its responsible app, or Other processes)?
    let s0 = Scan(); _ = s0.run(.memory)
    let r0 = s0.run(.memory)
    let myApp = r0.apps.first { $0.processes.contains { $0.pid == me } }?.appPID
    print("probe pid \(me) is under: \(myApp.map(nm) ?? "?") (\(r0.apps.first { $0.appPID == myApp }?.processes.count ?? 0) processes)")

    let runs = [Run("cpu-away", .cpu, .away),
                Run("cpu-hover", .cpu, .hover(from: 15, to: total - 25)),
                Run("mem-hover", .memory, .hover(from: 15, to: total - 25)),
                Run("energy-away", .energy, .away),
                Run("cpu-still", .cpu, .still)]
    // Expand: the probe's own app in the hover runs (it gains processes on purpose); the busiest
    // multi-process app in the away runs.
    runs[1].expandWanted = myApp; runs[2].expandWanted = myApp
    let overview = MetricsStore()
    var snaps: [Snap] = []
    var cpuT = Track(), memT = Track(), downT = Track(), upT = Track()
    var cpuErr: [Double] = []
    var spawned: [Process] = []
    var yesStart: Double?, yesSeen: Double?, yesGone: Double?, yesGoneSeen: Double?
    var preYes = 0.0
    let start = Date()
    var nextTick = start, nextScan = start, scanN = 0
    var events: Set<String> = []
    while true {
        let now = Date(), t = now.timeIntervalSince(start)
        if t >= total { break }
        // Scripted events while the hover runs are frozen.
        if t >= 25, !events.contains("sleep") {
            events.insert("sleep")
            for _ in 0..<2 { let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["9"]; try? p.run(); spawned.append(p) }
            print(String(format: "t=%.1f spawned 2× sleep 9", t))
        }
        if t >= 45, !events.contains("yes") {
            events.insert("yes")
            preYes = overview.cardCPUPercent
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/yes"); p.standardOutput = FileHandle.nullDevice
            try? p.run(); spawned.append(p); yesStart = t
            print(String(format: "t=%.1f started yes (card shows %.0f%%)", t, preYes))
        }
        if let ys = yesStart, t >= ys + 6, !events.contains("yeskill") {
            events.insert("yeskill"); spawned.last?.terminate(); yesGone = t
            print(String(format: "t=%.1f killed yes", t))
        }
        if now >= nextTick {
            snaps.append(Snap(time: now, cpu: readCPUTicks(), net: readNetCounters()))
            let b = rateBaselineIndex(times: snaps.lazy.map { $0.time.timeIntervalSinceReferenceDate }, now: now.timeIntervalSinceReferenceDate, window: rateWindowSeconds)
            if b > 0 { snaps.removeFirst(b) }
            if snaps.count > 1, let cur = snaps.last {
                let cpu = cpuBusyPercent(previous: snaps[0].cpu, current: cur.cpu)
                let net = networkThroughput(previous: snaps[0].net, current: cur.net, secondsElapsed: now.timeIntervalSince(snaps[0].time))
                let mem = memorySample(raw: readVMRaw(), totalBytes: ProcessInfo.processInfo.physicalMemory, pressureLevel: readMemoryPressureLevel())
                overview.record(cpuPercent: cpu, memory: mem, network: net, time: now.timeIntervalSinceReferenceDate)
                cpuT.see("\(Int(overview.cardCPUPercent.rounded()))%"); cpuErr.append(abs(overview.cardCPUPercent - cpu))
                memT.see(String(format: "%.1f", Double(overview.cardMemory?.usedBytes ?? 0) / 1_073_741_824))
                downT.see(formattedRate(bytesPerSecond: overview.cardNetwork?.downBytesPerSec ?? 0))
                upT.see(formattedRate(bytesPerSecond: overview.cardNetwork?.upBytesPerSec ?? 0))
                if let ys = yesStart, yesSeen == nil, t > ys, overview.cardCPUPercent >= preYes + 6 { yesSeen = t }
                if let yg = yesGone, yesGoneSeen == nil, t > yg, overview.cardCPUPercent <= preYes + 4 { yesGoneSeen = t }
            }
            nextTick = nextTick.addingTimeInterval(0.5)
        }
        if now >= nextScan {
            for r in runs { r.tick(now: now, t: t) }
            scanN += 1
            nextScan = scanN == 1 ? start.addingTimeInterval(firstRescanDelay) : nextScan.addingTimeInterval(breakdownScanInterval)
        }
        RunLoop.current.run(until: min(nextTick, nextScan))
    }
    spawned.forEach { if $0.isRunning { $0.terminate() } }
    let m = Date().timeIntervalSince(start) / 60
    print(String(format: "overview: CPU card changes/min %.1f (flip-backs %.1f); memory %.1f (%.1f); ↓ %.1f (%.1f); ↑ %.1f (%.1f)",
                 Double(cpuT.changes)/m, Double(cpuT.flips)/m, Double(memT.changes)/m, Double(memT.flips)/m,
                 Double(downT.changes)/m, Double(downT.flips)/m, Double(upT.changes)/m, Double(upT.flips)/m))
    let ce = cpuErr.sorted()
    print(String(format: "overview: CPU card vs exact pp p50 %.2f p95 %.2f max %.2f", ce[ce.count/2], ce[Int(Double(ce.count)*0.95)], ce.last!))
    if let ys = yesStart { print(String(format: "overview: one busy core started t=%.1f → card +6pp at %@; stopped t=%@ → card back at %@", ys,
                                         yesSeen.map { String(format: "%.1f (%.1f s)", $0, $0 - ys) } ?? "never",
                                         yesGone.map { String(format: "%.1f", $0) } ?? "-",
                                         yesGoneSeen.map { String(format: "%.1f (%.1f s)", $0, $0 - (yesGone ?? 0)) } ?? "never")) }
    for r in runs { r.report() }
}

// MARK: - Synthetic: an expanded app gains a process while the list is frozen

@MainActor func synthetic() {
    func app(_ pid: Int32, _ kids: [(Int32, Double)]) -> AppUsage {
        AppUsage(appPID: pid, processes: kids.map { ProcessUsage(pid: $0.0, appPID: pid, cpuPercent: $0.1, memoryBytes: 0) },
                 cpuPercent: kids.reduce(0) { $0 + $1.1 }, memoryBytes: 0)
    }
    let s = MetricsStore()
    s.beginBreakdown(metric: .cpu)
    var ptr = BreakdownPointer(inside: false, moved: true)
    s.breakdownPointerProbe = { ptr }
    let t0 = Date().timeIntervalSinceReferenceDate
    let a1 = [app(100, [(100, 5), (101, 2), (102, 1)]), app(200, [(200, 3)]), app(300, [(300, 2)])]
    s.setBreakdown(a1, measuring: false, totalCPU: 20, time: t0)
    s.setBreakdown(a1, measuring: false, totalCPU: 20, time: t0 + 2)
    let before = BreakdownList.rows(s.breakdown, expanded: 100, visible: 5).map(\.id)
    ptr = BreakdownPointer(inside: true, moved: true); s.setBreakdownPointerInside(true, time: t0 + 3)
    let a2 = [app(100, [(100, 5), (101, 2), (102, 1), (103, 0.4)]), app(200, [(200, 3)]), app(300, [(300, 2)])]
    s.setBreakdown(a2, measuring: false, totalCPU: 20, time: t0 + 4)
    let after = BreakdownList.rows(s.breakdown, expanded: 100, visible: 5).map(\.id)
    print("synthetic, frozen, expanded app 100 gains pid 103:")
    print("  before: \(before)")
    print("  after:  \(after)")
    // And when it has 5 visible + gains a 6th: a "more" row appears.
    let b1 = [app(100, (0..<5).map { (Int32(100 + $0), 5.0 - Double($0)) }), app(200, [(200, 3)])]
    let s2 = MetricsStore(); s2.beginBreakdown(metric: .cpu)
    var p2 = BreakdownPointer(inside: false, moved: true); s2.breakdownPointerProbe = { p2 }
    s2.setBreakdown(b1, measuring: false, totalCPU: 20, time: t0); s2.setBreakdown(b1, measuring: false, totalCPU: 20, time: t0 + 2)
    let x = BreakdownList.rows(s2.breakdown, expanded: 100, visible: 5).map(\.id)
    p2 = BreakdownPointer(inside: true, moved: true)
    let b2 = [app(100, (0..<6).map { (Int32(100 + $0), 5.0 - Double($0)) }), app(200, [(200, 3)])]
    s2.setBreakdown(b2, measuring: false, totalCPU: 20, time: t0 + 4)
    let y = BreakdownList.rows(s2.breakdown, expanded: 100, visible: 5).map(\.id)
    print("synthetic, frozen, expanded app with 5 shown gains a 6th:")
    print("  before: \(x)")
    print("  after:  \(y)")
}

// MARK: - Cost: SwiftUI overview with/without the tour host, at the open cadence

@MainActor func cost() {
    func cpuSeconds() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6 }
    let (n, d) = suiteNamed(); defer { drop(n) }
    d.set(TourAudience.existing.rawValue, forKey: TourKey.audience); d.set(1, forKey: TourKey.seenVersion)
    for (label, host, on) in [("no tour host", false, false), ("tour host, tour off", true, false), ("tour on (step 1)", true, true)] {
        let store = makeStore()
        let tour = TourController(defaults: d, hasBattery: { true })
        let w = makeWindow(Panel(store: store, tour: tour, defaults: d, host: host))
        settle(1)
        if on { tour.start(); settle(0.5) }
        var i = 0.0
        let c0 = cpuSeconds(), t0 = Date()
        while Date().timeIntervalSince(t0) < 20 {
            i += 1
            store.record(cpuPercent: 20 + 10 * sin(i / 4), memory: MemorySample(usedBytes: UInt64(11e9 + 2e8 * sin(i / 3)), totalBytes: 17_179_869_184, pressure: .normal),
                         network: NetworkSample(downBytesPerSec: 100_000 + 80_000 * sin(i / 2), upBytesPerSec: 9_000), time: Date().timeIntervalSinceReferenceDate)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        print(String(format: "cost %@: %.2f %% of a core", label, (cpuSeconds() - c0) / Date().timeIntervalSince(t0) * 100))
        w.orderOut(nil); w.close()
    }
    // Scanner: time per scan, current code.
    let sc = Scan(); _ = sc.run(.cpu)
    var times: [Double] = []
    for _ in 0..<15 { settle(2); let a = Date(); _ = sc.run(.cpu); times.append(Date().timeIntervalSince(a) * 1000) }
    times.sort()
    print(String(format: "scan(.cpu) ms p50 %.1f max %.1f → %.2f %% of a core at one scan / %.0f s", times[7], times.last!, times[7] / 10 / breakdownScanInterval, breakdownScanInterval))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    switch mode {
    case "stability": stability(seconds: Double(outDir) ?? 100)
    case "synthetic": synthetic()
    case "cost": cost()
    default: render()
    }
    print("done")
}

// Computed: a stored global at the end of main.swift would still be 0 when the code above runs.
var firstRescanDelay: TimeInterval {
    #if FIRST_RESCAN
    breakdownFirstRescanDelay
    #else
    breakdownScanInterval
    #endif
}

// Reviewer B (round 2) off-screen render probe. Renders the REAL MacStats views (Sources/MacStatsApp
// minus the @main, compiled into this target) in windows at desktop level + 1, ordered back, never
// activated; captures each with CGWindowListCreateImage; closes it. Tour state lives in throwaway
// UserDefaults suites that are deleted at the end. Breakdowns are filled with REAL scans of this Mac.
import AppKit
import SwiftUI
import MacStatsCore

setvbuf(stdout, nil, _IONBF, 0)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "out"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

nonisolated(unsafe) var anchorRects: [String: CGRect] = [:]
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

/// The overview as RootView composes it (fixed frame, .tourHost, clipped, backdrop).
struct Panel: View {
    @ObservedObject var store: MetricsStore
    @ObservedObject var tour: TourController
    let defaults: UserDefaults
    var body: some View {
        OverviewView(store: store, onSelect: { _ in }, onEmptyTrash: {}, onSettings: {},
                     offersTour: tour.offersTour, onTour: {}, onDismissOffer: {})
            .frame(width: Design.panelWidth, height: Design.panelHeight)
            .tourHost(tour, showing: true)
            .modifier(AnchorProbe())
            .clipped()
            .background(PanelBackdrop())
            .defaultAppStorage(defaults)
    }
}

@MainActor func overviewStore(battery: BatterySample?? = nil) -> MetricsStore {
    let s = MetricsStore()
    let now = Date().timeIntervalSinceReferenceDate
    for i in 0..<120 {
        let t = now - 60 + Double(i) * 0.5
        let mem = MemorySample(usedBytes: 11_480_000_000, totalBytes: 17_179_869_184, pressure: .normal,
                               appBytes: 7_100_000_000, wiredBytes: 2_300_000_000, compressedBytes: 1_800_000_000,
                               compressedDataBytes: 5_200_000_000)
        s.record(cpuPercent: 14 + 6 * sin(Double(i) / 7) + Double(i % 3), memory: mem,
                 network: NetworkSample(downBytesPerSec: 84_000 + 60_000 * sin(Double(i) / 5), upBytesPerSec: 12_000),
                 time: t)
    }
    if let b = battery { s.setBattery(b) } else { s.setBattery(readBattery()) }
    s.setBatteryTelemetry(SmartBatteryReader().read(), powerWatts: 6.8, averageWatts: 7.4, averageSinceUnplug: true)
    s.setCPUTemperature(46)
    s.setTrashBytes(842_000_000)
    return s
}

// MARK: windows

@MainActor func settle(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
}

@MainActor func makeWindow<V: View>(_ view: V) -> (NSWindow, NSView) {
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
    w.setFrameOrigin(NSPoint(x: 60, y: 60))
    w.orderBack(nil)
    return (w, host)
}

@MainActor func capture(_ w: NSWindow) -> CGImage? {
    for win in NSApp.windows where win.level.rawValue > Int(CGWindowLevelForKey(.desktopWindow)) + 1 {
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1); win.orderBack(nil)
    }
    if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber),
                                         [.boundsIgnoreFraming, .bestResolution]) { return img }
    guard let view = w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep.cgImage
}

func save(_ img: CGImage?, _ name: String) {
    guard let img else { print("capture failed", name); return }
    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    print("wrote", name, img.width, "x", img.height)
}

@MainActor func shoot<V: View>(_ name: String, _ view: V, wait: Double = 0.8) {
    let (w, _) = makeWindow(view)
    settle(wait)
    save(capture(w), name)
    w.orderOut(nil); w.close()
}

/// Presses the first accessibility button whose label contains `text`.
@MainActor func press(_ root: Any, containing text: String) -> Bool {
    func walk(_ e: Any, depth: Int) -> Bool {
        guard depth < 30, let el = e as? NSAccessibilityProtocol else { return false }
        let label = (el.accessibilityLabel() ?? "")
        if label.contains(text), el.accessibilityRole() == .button || el.accessibilityRole() == .cell
            || el.accessibilityRole() == .group {
            if el.accessibilityPerformPress() { return true }
        }
        for c in (el.accessibilityChildren() ?? []) { if walk(c, depth: depth + 1) { return true } }
        return false
    }
    return walk(root, depth: 0)
}

@MainActor func dumpA11y(_ root: Any, depth: Int = 0, max: Int = 4) {
    guard depth < max, let el = root as? NSAccessibilityProtocol else { return }
    print(String(repeating: "  ", count: depth) + "\(el.accessibilityRole()?.rawValue ?? "?") '\(el.accessibilityLabel() ?? "")'")
    for c in (el.accessibilityChildren() ?? []) { dumpA11y(c, depth: depth + 1, max: max) }
}

@MainActor func click(_ w: NSWindow, _ host: NSView, at p: CGPoint) {
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

// MARK: real scans

final class Scan {
    let scanner = BreakdownScanner()
    func run(_ metric: BreakdownMetric) -> BreakdownScanner.Result {
        let anchors = attributionAnchors(NSWorkspace.shared.runningApplications.map { app in
            RunningAppInfo(pid: Int32(app.processIdentifier), hasBundleIdentifier: app.bundleIdentifier != nil,
                           isBackgroundOnly: app.activationPolicy == .prohibited)
        })
        let time = Date().timeIntervalSinceReferenceDate
        let absTime = mach_absolute_time()
        let ticks = readCPUTicks()
        let raw = readRawProcesses(includeEnergy: metric == .energy)
        return scanner.scan(raw, appPIDs: anchors.apps, fallbackAppPIDs: anchors.fallbacks,
                            metric: metric, time: time, absTime: absTime, cpuTicks: ticks)
    }
}

@MainActor func breakdownStore(_ metric: BreakdownMetric) -> MetricsStore {
    let s = overviewStore()
    s.beginBreakdown(metric: metric)
    let scan = Scan()
    var r = scan.run(metric)
    s.setBreakdown(r.apps, measuring: r.measuring, totalCPU: r.totalCPUPercent)
    for _ in 0..<2 {
        settle(2.0)
        r = scan.run(metric)
        s.setBreakdown(r.apps, measuring: r.measuring, totalCPU: r.totalCPUPercent)
    }
    return s
}

// MARK: pixels

struct Px {
    let w: Int, h: Int
    var d: [UInt8]
    init(_ img: CGImage) {
        w = img.width; h = img.height
        d = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &d, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    func at(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * w + x) * 4
        return (Int(d[i]), Int(d[i + 1]), Int(d[i + 2]))
    }
    func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h }
}
func dd(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int { max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) }
func isAccent(_ c: (Int, Int, Int)) -> Bool { c.2 - c.0 > 45 && c.2 > 120 }

/// Walk from inside the target outward. Returns px counts: gap (unchanged px between the target
/// edge and the ring), ring (accent px), and the ring's outer edge offset from the target edge.
func walkOut(_ base: Px, _ tour: Px, edge: (Int, Int), step: (Int, Int)) -> (gap: Int, ring: Int) {
    var (x, y) = edge
    var gap = 0
    while base.inside(x, y), dd(base.at(x, y), tour.at(x, y)) <= 6, !isAccent(tour.at(x, y)) {
        gap += 1; x += step.0; y += step.1
    }
    var ring = 0
    while base.inside(x, y), isAccent(tour.at(x, y)) { ring += 1; x += step.0; y += step.1 }
    return (gap, ring)
}

/// Along the 45° diagonal from a box corner inward: px to the first accent pixel (ring outer edge)
/// and to the first pixel after the ring that equals the base (hole interior).
func diagonal(_ base: Px, _ tour: Px, from: (Int, Int), step: (Int, Int)) -> (toRing: Int, ringEnd: Int) {
    var (x, y) = from
    var n = 0
    while base.inside(x, y), !isAccent(tour.at(x, y)), n < 80 { n += 1; x += step.0; y += step.1 }
    let toRing = n
    while base.inside(x, y), isAccent(tour.at(x, y)), n < 120 { n += 1; x += step.0; y += step.1 }
    return (toRing, n)
}

/// Along the diagonal from the target's box corner inward in the BASE image: px until the card
/// surface starts (first pixel differing from the backdrop sample by > 2).
func cardDiagonal(_ base: Px, from: (Int, Int), step: (Int, Int), backdrop: (Int, Int, Int)) -> Int {
    var (x, y) = from
    var n = 0
    while base.inside(x, y), dd(base.at(x, y), backdrop) <= 2, n < 60 { n += 1; x += step.0; y += step.1 }
    return n
}

nonisolated(unsafe) var lines: [String] = []
func log(_ s: String) { print(s); lines.append(s) }

@MainActor func measure(_ name: String, base: CGImage, tour: CGImage, target: CGRect) {
    let b = Px(base), t = Px(tour)
    let s = CGFloat(b.w) / Design.panelWidth
    let midX = Int(target.midX * s), midY = Int(target.midY * s)
    let minX = Int((target.minX * s).rounded()), maxX = Int((target.maxX * s).rounded())
    let minY = Int((target.minY * s).rounded()), maxY = Int((target.maxY * s).rounded())
    let L = walkOut(b, t, edge: (minX - 1, midY), step: (-1, 0))
    let R = walkOut(b, t, edge: (maxX, midY), step: (1, 0))
    let T = walkOut(b, t, edge: (midX, minY - 1), step: (0, -1))
    let B = walkOut(b, t, edge: (midX, maxY), step: (0, 1))
    func pt(_ px: Int) -> String { String(format: "%.1f", Double(px) / Double(s)) }
    // Insets of the cutout (ring outer edge) from the target edge, in points.
    log("\(name): target=(\(target.minX),\(target.minY),\(target.width)x\(target.height))pt  "
        + "cutout inset L=\(pt(L.gap + L.ring)) R=\(pt(R.gap + R.ring)) T=\(pt(T.gap + T.ring)) B=\(pt(B.gap + B.ring)) pt; "
        + "clear gap L/R/T/B=\(pt(L.gap))/\(pt(R.gap))/\(pt(T.gap))/\(pt(B.gap)) ring=\(pt(L.ring))/\(pt(R.ring))/\(pt(T.ring))/\(pt(B.ring))")
    // Corners: ring vs card along the diagonals, in px.
    let backdrop = b.at(minX - Int(2 * s), midY)   // 2 pt outside the card, inside the hole
    var corner: [String] = []
    for (cx, cy, sx, sy, label) in [(minX, minY, 1, 1, "TL"), (maxX - 1, minY, -1, 1, "TR"),
                                    (minX, maxY - 1, 1, -1, "BL"), (maxX - 1, maxY - 1, -1, -1, "BR")] {
        let cardD = cardDiagonal(b, from: (cx, cy), step: (sx, sy), backdrop: backdrop)
        let ox = cx - sx * Int(3 * s), oy = cy - sy * Int(3 * s)   // the cutout's box corner (3 pt out)
        let ring = diagonal(b, t, from: (ox, oy), step: (sx, sy))
        // radial gap along the diagonal between ring inner edge and card edge, in pt (diagonal px × √2 / s)
        let gapDiag = Double((Int(3 * s) + cardD) - ring.ringEnd) * 1.41421 / Double(s)
        corner.append("\(label): cutout-corner→ring \(ring.toRing)px, ring ends \(ring.ringEnd)px, card edge \(Int(3 * s) + cardD)px "
                      + String(format: "(ring-inner→card gap along diagonal %.1f pt)", gapDiag))
    }
    log("   corners " + corner.joined(separator: " | "))
}

/// Saves a nearest-neighbour zoom of a region (px) of `img`.
func zoom(_ img: CGImage, _ r: CGRect, _ factor: Int, _ name: String) {
    guard let crop = img.cropping(to: r) else { return }
    let w = crop.width * factor, h = crop.height * factor
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none
    ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
    save(ctx.makeImage(), name)
}

// MARK: suites

nonisolated(unsafe) var suiteNames: [String] = []
@MainActor func suite(_ audience: TourAudience) -> UserDefaults {
    let name = "MacStatsReviewB2-\(UUID().uuidString)"
    suiteNames.append(name)
    let d = UserDefaults(suiteName: name)!
    d.set(audience.rawValue, forKey: TourKey.audience)
    return d
}
func dropSuites() {
    for name in suiteNames {
        UserDefaults.standard.removePersistentDomain(forName: name)
        CFPreferencesAppSynchronize(name as CFString)
    }
    Thread.sleep(forTimeInterval: 0.5)
    for name in suiteNames {
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(name).plist"))
    }
    try? suiteNames.joined(separator: "\n").write(toFile: "\(outDir)/suites.txt", atomically: true, encoding: .utf8)
}

// MARK: run

let onlyBreakdowns = CommandLine.arguments.count > 2
@MainActor func run() {
    defer { dropSuites() }
    for dark in [false, true] {
      if !onlyBreakdowns {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let look = dark ? "dark" : "light"

        // Overview + every tour step, measured against the same window without the tour.
        let d = suite(.existing)
        d.set(TourCatalog.version, forKey: TourKey.seenVersion)   // no chip in the base
        let store = overviewStore()
        let tour = TourController(defaults: d, hasBattery: { store.battery != nil })
        let (w, _) = makeWindow(Panel(store: store, tour: tour, defaults: d))
        settle(1.0)
        guard let base = capture(w) else { return }
        save(base, "overview-\(look)")
        tour.start()
        settle(0.6)
        for (i, step) in TourCatalog.steps.enumerated() where tour.currentStep?.step.id == step.id {
            settle(0.9)
            guard let img = capture(w) else { continue }
            save(img, "tour-step\(i + 1)-\(look)")
            if let target = anchorRects[step.anchor] { measure("step\(i + 1) \(step.id.rawValue) \(look)", base: base, tour: img, target: target) }
            else { log("step\(i + 1) anchor missing") }
            if i == 0 || i == 4 {
                let s = CGFloat(img.width) / Design.panelWidth
                if let t = anchorRects[step.anchor] {
                    zoom(img, CGRect(x: (t.minX - 6) * s, y: (t.minY - 6) * s, width: 28 * s, height: 28 * s), 6, "zoom-step\(i + 1)-TL-\(look)")
                    zoom(img, CGRect(x: (t.maxX - 22) * s, y: (t.maxY - 22) * s, width: 28 * s, height: 28 * s), 6, "zoom-step\(i + 1)-BR-\(look)")
                }
            }
            tour.next()
        }
        log("after Done: phase=\(tour.state.phase) seenVersion=\(d.object(forKey: TourKey.seenVersion) ?? "nil")")
        w.orderOut(nil); w.close()

        // Welcome (new user) and the chip (existing user).
        let wd = suite(.new)
        let wt = TourController(defaults: wd, hasBattery: { true })
        wt.panelOpened()
        shoot("welcome-\(look)", Panel(store: overviewStore(), tour: wt, defaults: wd), wait: 1.0)
        let cd = suite(.existing)
        let ct = TourController(defaults: cd, hasBattery: { true })
        ct.panelOpened()
        shoot("chip-\(look)", Panel(store: overviewStore(), tour: ct, defaults: cd))

        // Settings.
        shoot("settings-\(look)", SettingsView(onBack: {})
            .frame(width: Design.panelWidth, height: Design.panelHeight).background(PanelBackdrop()).defaultAppStorage(cd))

      }
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let look = dark ? "dark" : "light"
        let cd2 = suite(.existing)
        // Breakdowns with real data, one app expanded by an accessibility press.
        for metric in [BreakdownMetric.cpu, .memory, .energy] {
            let bs = breakdownStore(metric)
            let hintFirst = metric == .cpu && !dark
            let view = BreakdownView(store: bs, metric: metric, quitHint: hintFirst, onBack: {})
                .background(PanelBackdrop()).defaultAppStorage(cd2)
            let (bw, host) = makeWindow(view)
            settle(1.0)
            save(capture(bw), "breakdown-\(metric)-\(look)")
            let names = bs.breakdown.prefix(8).map { "\(NSRunningApplication(processIdentifier: $0.appPID)?.localizedName ?? "\($0.appPID)")(\($0.processes.count))" }
            log("breakdown \(metric) \(look) top8: " + names.joined(separator: ", "))
            if let target = bs.breakdown.prefix(6).first(where: { $0.isApp && $0.processes.count > 2 }),
               let name = NSRunningApplication(processIdentifier: target.appPID)?.localizedName {
                let idx = bs.breakdown.firstIndex { $0.appPID == target.appPID }!
                var top: CGFloat = 36
                if metric == .memory { top += NSHostingView(rootView: MemoryPartsCard(store: bs).frame(width: 304)).fittingSize.height + 6 }
                if metric == .energy { top += NSHostingView(rootView: BatteryDetailsCard(store: bs).frame(width: 304)).fittingSize.height + 6 }
                let y = top + 4 + 36 * CGFloat(idx) + 18
                click(bw, host, at: CGPoint(x: 120, y: y))
                let ok = true
                settle(0.8)
                log("expand \(name) (\(target.processes.count) processes) pressed=\(ok)")
                save(capture(bw), "breakdown-\(metric)-expanded-\(look)")
            }
            bw.orderOut(nil); bw.close()
        }
    }

    if onlyBreakdowns { return }
    // Edge states (light): measuring, no battery, trash permission, opacity 1 tour step.
    NSApp.appearance = NSAppearance(named: .aqua)
    let e = suite(.existing)
    e.set(TourCatalog.version, forKey: TourKey.seenVersion)
    let ms = overviewStore()
    ms.beginBreakdown(metric: .cpu)
    shoot("breakdown-cpu-measuring-light", BreakdownView(store: ms, metric: .cpu, onBack: {}).background(PanelBackdrop()))
    let nb = overviewStore(battery: .some(nil))
    let nt = TourController(defaults: e, hasBattery: { false })
    shoot("overview-nobattery-light", Panel(store: nb, tour: nt, defaults: e))
    nt.start(); nt.next(); nt.next(); nt.next()
    log("nobattery: at footer step progress=\(nt.progress.map { "\($0.number) of \($0.total)" } ?? "nil")")
    shoot("tour-nobattery-last-light", Panel(store: nb, tour: nt, defaults: e), wait: 1.2)
    let ts = overviewStore()
    ts.setTrashBytes(nil); ts.setTrashNeedsPermission(true)
    shoot("overview-trash-permission-light", Panel(store: ts, tour: TourController(defaults: e, hasBattery: { true }), defaults: e))
    try? (lines.joined(separator: "\n") + "\n").write(toFile: "\(outDir)/measure.txt", atomically: true, encoding: .utf8)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    run()
    print("done")
}

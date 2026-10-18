// Reviewer B's independent probe. Two jobs, no UI on the owner's screen:
//  1. Live-flow stability: the REAL MetricsStore + BreakdownScanner on live processes at the app's
//     cadence (0.5 s overview ticks; breakdown scans at 0, +0.5 s, then every 2 s), with an expanded
//     (pinned) app and a simulated pointer resting in the list. Counts what a user would see move.
//  2. Renders of the REAL SwiftUI views (overview, breakdowns, Settings, tour) in borderless windows at
//     desktop level + 1, ordered back, never activated; captured by window id; closed at once.
// Tour state lives in a throwaway defaults suite deleted at the end.
import AppKit
import SwiftUI
import MacStatsCore

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "out"
let mode = args.count > 2 ? args[2] : "all"
let stabSeconds = args.count > 3 ? Double(args[3]) ?? 70 : 70
let coresD = Double(ProcessInfo.processInfo.activeProcessorCount)
let pinEnabled = mode != "inv"

nonisolated(unsafe) var report: [String] = []
func log(_ s: String) { print(s); report.append(s) }

// MARK: Live pipeline (copies of AppModel.sample / BreakdownScanSession.scan)

@MainActor final class Live {
    let store = MetricsStore()
    let total = ProcessInfo.processInfo.physicalMemory
    let smart = SmartBatteryReader()
    let thermal = CPUTemperatureReader()
    var snaps: [(t: Date, cpu: CPUTicks, net: NetCounters)] = []
    var raw: (cpu: Double, mem: MemorySample, net: NetworkSample)?
    let scanner = BreakdownScanner()
    var hasBundle: [Int32: Bool] = [:]
    var scanMs: [Double] = []

    func tick(_ now: Date = Date()) {
        snaps.append((now, readCPUTicks(), readNetCounters()))
        let base = rateBaselineIndex(times: snaps.lazy.map { $0.t.timeIntervalSinceReferenceDate },
                                     now: now.timeIntervalSinceReferenceDate, window: rateWindowSeconds)
        if base > 0 { snaps.removeFirst(base) }
        guard snaps.count > 1, let cur = snaps.last else { return }
        let b = snaps[0]
        let cpu = cpuBusyPercent(previous: b.cpu, current: cur.cpu)
        let net = networkThroughput(previous: b.net, current: cur.net, secondsElapsed: now.timeIntervalSince(b.t))
        let mem = memorySample(raw: readVMRaw(), totalBytes: total, pressureLevel: readMemoryPressureLevel())
        store.record(cpuPercent: cpu, memory: mem, network: net, time: now.timeIntervalSinceReferenceDate)
        raw = (cpu, mem, net)
    }

    func slow() {
        store.setBattery(readBattery())
        let t = smart.read()
        store.setBatteryTelemetry(t, powerWatts: t?.instantWatts, averageWatts: nil)
        store.setCPUTemperature(thermal.read())
    }

    func scan(_ metric: BreakdownMetric) -> BreakdownScanner.Result {
        let t0 = DispatchTime.now().uptimeNanoseconds
        var hb: [Int32: Bool] = [:]
        let anchors = attributionAnchors(NSWorkspace.shared.runningApplications.map { app in
            let pid = Int32(app.processIdentifier)
            let has = hasBundle[pid] ?? (app.bundleIdentifier != nil)
            hb[pid] = has
            return RunningAppInfo(pid: pid, hasBundleIdentifier: has, isBackgroundOnly: app.activationPolicy == .prohibited)
        })
        hasBundle = hb
        let time = Date().timeIntervalSinceReferenceDate
        let abs = mach_absolute_time()
        let ticks = readCPUTicks()
        let rawP = readRawProcesses(includeEnergy: metric == .energy)
        let r = scanner.scan(rawP, appPIDs: anchors.apps, fallbackAppPIDs: anchors.fallbacks, metric: metric,
                             time: time, absTime: abs, cpuTicks: ticks)
        scanMs.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        return r
    }
}

@MainActor func settle(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
}

func cpuSeconds() -> Double {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
}

// MARK: 1. Stability

struct Flip { var history: [String] = []; var changes = 0; var flipBacks = 0
    mutating func add(_ s: String, count: Bool) {
        if let last = history.last, last != s, count {
            changes += 1
            if history.count >= 2, history[history.count - 2] == s { flipBacks += 1 }
        }
        history.append(s); if history.count > 3 { history.removeFirst() }
    }
}

@MainActor func stability(_ live: Live, metric: BreakdownMetric, seconds: Double, scanStart: Double = 0) {
    let s = live.store
    s.beginBreakdown(metric: metric)
    let start = Date()
    var nextTick = start, nextScan = start, scans = 0
    var target: Int32?
    let pointerFrom = seconds * 0.4, pointerTo = seconds * 0.4 + 20
    var pointerIn = false
    var pointerIDs: (child: String?, app: String?) = (nil, nil)
    var pointerChildIdx = 0, pointerAppIdx = 0
    var frozenChanges = (child: 0, app: 0, rowsShifted: 0, scans: 0)
    var lastFlat: [String]?
    var lastAppOrder: [Int32]?
    var counted = 0.0, lastScanAt: Date?
    var c = (top8: 0, appMoves: 0, targetMoves: 0, targetGone: 0, childOrder: 0, childSet: 0, scans: 0)
    var texts: [Int32: Flip] = [:]
    var header = Flip()
    var maxErr = 0.0, sumErr = 0.0, nErr = 0
    var lastTargetIdx: Int?, lastChildren: [String]?
    var exitedToggles = 0, lastHadExited: Bool?
    var unfreezeLagScans = 0
    var inv = (scansWith: 0, pairs: 0, maxGap: 0.0, scans: 0)
    var invExample = ""
    // Overview cards
    var cards = (cpu: Flip(), mem: Flip(), down: Flip(), up: Flip())
    var cardErrMax = 0.0, cardErrBig = 0, cardN = 0

    func step(_ v: Double) -> Double { breakdownValueStep(metric, v) }
    while true {
        let now = Date(), el = now.timeIntervalSince(start)
        if el >= seconds { break }
        if now >= nextTick {
            live.tick(now)
            if Int(el * 2) % 20 == 0 { live.slow() }
            if let r = live.raw {
                let cpuT = "\(Int(s.cardCPUPercent.rounded()))%"
                let memT = String(format: "%.1f", Double(s.cardMemory?.usedBytes ?? 0) / 1_073_741_824)
                cards.cpu.add(cpuT, count: true); cards.mem.add(memT, count: true)
                cards.down.add(formattedRate(bytesPerSecond: s.cardNetwork?.downBytesPerSec ?? 0), count: true)
                cards.up.add(formattedRate(bytesPerSecond: s.cardNetwork?.upBytesPerSec ?? 0), count: true)
                let e = abs(s.cardCPUPercent - r.cpu)
                cardErrMax = max(cardErrMax, e); if e >= 2 { cardErrBig += 1 }; cardN += 1
            }
            nextTick = nextTick.addingTimeInterval(0.5)
        }
        if now >= nextScan {
            // Pointer enters / leaves the list.
            let wantIn = el >= pointerFrom && el < pointerTo
            if wantIn != pointerIn {
                pointerIn = wantIn
                s.setBreakdownPointerInside(wantIn, time: now.timeIntervalSinceReferenceDate)
            }
            let r = live.scan(metric)
            s.setBreakdown(r.apps, measuring: r.measuring, totalCPU: r.totalCPUPercent,
                           time: now.timeIntervalSinceReferenceDate)
            scans += 1
            nextScan = scans == 1 ? start.addingTimeInterval(breakdownFirstRescanDelay)
                                  : nextScan.addingTimeInterval(breakdownScanInterval)
            let interval = lastScanAt.map { now.timeIntervalSince($0) } ?? 0
            lastScanAt = now
            if r.measuring { continue }
            let rows = s.breakdown
            if target == nil || !rows.contains(where: { $0.appPID == target }) {
                if target != nil { c.targetGone += 1 }
                // The app with the most processes, as a user would expand (like VS Code / a browser).
                target = rows.filter { $0.isApp && $0.processes.count > 2 }.max { $0.processes.count < $1.processes.count }?.appPID
                s.setBreakdownPinnedApp(pinEnabled ? target : nil)
                lastTargetIdx = nil; lastChildren = nil
            }
            let flat = BreakdownList.rows(rows, expanded: target, visible: BreakdownList.initialChildren).map(\.id)
            let appOrder = rows.map(\.appPID)
            let tIdx = target.flatMap { t in appOrder.firstIndex(of: t) }
            let children = target.flatMap { t in rows.first { $0.appPID == t } }
                .map { Array($0.processes.prefix(BreakdownList.initialChildren).map { "p\($0.pid)" }) } ?? []
            let hasExited = target.flatMap { t in rows.first { $0.appPID == t } }?
                .processes.contains { $0.pid == BreakdownGroup.exitedProcesses } ?? false

            if pointerIn {
                if pointerIDs.child == nil {
                    // Pointer over the expanded app's 2nd child, and over the 6th row of the list.
                    pointerChildIdx = (flat.firstIndex(of: "a\(target ?? 0)") ?? 0) + 2
                    pointerAppIdx = min(5, flat.count - 1)
                    pointerIDs = (flat.indices.contains(pointerChildIdx) ? flat[pointerChildIdx] : nil, flat[pointerAppIdx])
                } else {
                    frozenChanges.scans += 1
                    let ch = flat.indices.contains(pointerChildIdx) ? flat[pointerChildIdx] : nil
                    if ch != pointerIDs.child { frozenChanges.child += 1; pointerIDs.child = ch }
                    let ap = flat.indices.contains(pointerAppIdx) ? flat[pointerAppIdx] : nil
                    if ap != pointerIDs.app { frozenChanges.app += 1; pointerIDs.app = ap }
                    if let lf = lastFlat, lf != flat { frozenChanges.rowsShifted += 1 }
                }
            } else if el >= pointerTo && el < pointerTo + 1.0 + breakdownScanInterval {
                unfreezeLagScans += 1    // the scans inside the 1 s unfreeze delay: not counted
            } else {
                c.scans += 1
                counted += interval
                if let lo = lastAppOrder {
                    if Array(lo.prefix(8)) != Array(appOrder.prefix(8)) { c.top8 += 1 }
                    for (i, key) in lo.prefix(10).enumerated() {
                        if let j = appOrder.firstIndex(of: key), j != i { c.appMoves += 1 }
                    }
                }
                if let t = tIdx, let lt = lastTargetIdx, t != lt { c.targetMoves += 1 }
                if let lc = lastChildren {
                    if Set(lc) != Set(children) { c.childSet += 1 } else if lc != children { c.childOrder += 1 }
                }
                for app in rows.prefix(8) {
                    let shown = s.shownValue(app: app.appPID) ?? app.value(for: metric)
                    texts[app.appPID, default: Flip()].add(breakdownValueText(metric, shown), count: true)
                    let exact = app.value(for: metric)
                    let e = abs(shown - exact) / (metric == .memory ? 1_048_576 : 1)
                    maxErr = max(maxErr, e); sumErr += e; nErr += 1
                }
                if metric == .cpu, let h = s.breakdownShownTotalCPU { header.add("\(Int(h.rounded()))", count: true) }
                // Visible mis-ordering: a row printed clearly lower than a row below it.
                let top = Array(rows.filter { $0.appPID != target || !pinEnabled }.prefix(8))
                var pairs = 0
                for i in 0..<top.count { for j in (i+1)..<max(i+1, top.count) {
                    let vi = top[i].value(for: metric), vj = top[j].value(for: metric)
                    if vj - vi > max(2 * step(vj), 0.25 * vj) { pairs += 1; if vj - vi > inv.maxGap { inv.maxGap = vj - vi
                        invExample = top.map { breakdownValueText(metric, $0.value(for: metric)) }.joined(separator: ",") } }
                } }
                inv.scans += 1; inv.pairs += pairs; if pairs > 0 { inv.scansWith += 1 }
                if let le = lastHadExited, le != hasExited { exitedToggles += 1 }
            }
            if pointerIn == false && pointerIDs.child != nil { pointerIDs = (nil, nil) }
            lastFlat = flat; lastAppOrder = appOrder; lastTargetIdx = tIdx; lastChildren = children
            lastHadExited = hasExited
        }
        RunLoop.current.run(until: min(nextTick, nextScan))
    }
    let m = max(counted, 1) / 60
    func pm(_ n: Int) -> String { String(format: "%.1f", Double(n) / m) }
    let name = target.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "none"
    let tProcs = target.flatMap { t in s.breakdown.first { $0.appPID == t }?.processes.count } ?? 0
    let textChanges = texts.values.reduce(0) { $0 + $1.changes }
    let flipBacks = texts.values.reduce(0) { $0 + $1.flipBacks }
    log("== stability metric=\(metric) seconds=\(Int(seconds)) counted_s=\(Int(counted)) scans_counted=\(c.scans) rows=\(s.breakdown.count)")
    log("expanded_app=\(name) processes=\(tProcs)")
    log("per_min: top8_order_changes=\(pm(c.top8)) app_row_index_changes(top10)=\(pm(c.appMoves)) expanded_app_index_changes=\(c.targetMoves) expanded_app_vanished=\(c.targetGone)")
    log("per_min: expanded_children_reorders=\(pm(c.childOrder)) expanded_children_set_changes=\(pm(c.childSet)) exited_row_toggles=\(exitedToggles)")
    log("per_min: top8_row_text_changes=\(pm(textChanges)) (flip-backs A>B>A total=\(flipBacks)) header_text_changes=\(pm(header.changes)) header_flipbacks=\(header.flipBacks)")
    log("inversions(top8, >max(2 steps,25%)): scans_with=\(inv.scansWith)/\(inv.scans) pairs_total=\(inv.pairs) max_gap=\(String(format: "%.3f", inv.maxGap)) worst_top8=[\(invExample)]")
    log(String(format: "shown_vs_exact top8: max=%.2f mean=%.3f (%@)", maxErr, nErr > 0 ? sumErr / Double(nErr) : 0,
               metric == .memory ? "MiB" : metric == .cpu ? "pp of Mac" : "W"))
    log("pointer_window_20s: scans=\(frozenChanges.scans) row_under_pointer_changed(child_slot)=\(frozenChanges.child) row_under_pointer_changed(row6)=\(frozenChanges.app) any_flat_list_change=\(frozenChanges.rowsShifted)")
    let wm = seconds / 60
    func pw(_ n: Int) -> String { String(format: "%.1f", Double(n) / wm) }
    log("cards per_min: cpu=\(pw(cards.cpu.changes)) (flipbacks \(cards.cpu.flipBacks)) mem=\(pw(cards.mem.changes)) (fb \(cards.mem.flipBacks)) down=\(pw(cards.down.changes)) (fb \(cards.down.flipBacks)) up=\(pw(cards.up.changes)) (fb \(cards.up.flipBacks))")
    log(String(format: "card_cpu_vs_raw: max=%.2fpp ticks_off_by>=2pp=%d/%d", cardErrMax, cardErrBig, cardN))
}

// MARK: 2. Windows, captures, clicks

@MainActor func makeWindow<V: View>(_ view: V, solid: Bool = false) -> NSWindow {
    let frame = NSRect(x: 0, y: 0, width: Design.panelWidth, height: Design.panelHeight)
    let host = NSHostingView(rootView: view.frame(width: Design.panelWidth, height: Design.panelHeight))
    host.frame = frame
    let container: NSView
    if solid {
        let v = NSView(frame: frame); v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container = v
    } else {
        let fx = NSVisualEffectView(frame: frame)
        fx.material = .popover; fx.state = .active; fx.blendingMode = .behindWindow
        container = fx
    }
    container.wantsLayer = true
    container.layer?.cornerRadius = Design.panelCornerRadius; container.layer?.cornerCurve = .continuous
    container.layer?.masksToBounds = true
    container.addSubview(host)
    let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.isReleasedWhenClosed = false
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
    v.cacheDisplay(in: v.bounds, to: rep); return rep.cgImage
}

func save(_ img: CGImage?, _ name: String) {
    guard let img else { log("capture failed \(name)"); return }
    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    print("wrote", name)
}

/// A click at panel point `p` (top-left origin), delivered straight to the hit view.
@MainActor func click(_ w: NSWindow, _ p: CGPoint) {
    let loc = NSPoint(x: p.x, y: Design.panelHeight - p.y)
    guard let content = w.contentView, let hit = content.hitTest(loc) else { log("click: no hit view"); return }
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                         pressure: type == .leftMouseDown ? 1 : 0) else { continue }
        NSApp.postEvent(e, atStart: true)
        _ = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true)
        if type == .leftMouseDown { hit.mouseDown(with: e) } else { hit.mouseUp(with: e) }
        settle(0.06)
    }
}

// MARK: Pixels

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
        let i = (y * w + x) * 4; return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }
    func lum(_ x: Int, _ y: Int) -> Int { let c = rgb(x, y); return (c.0 * 3 + c.1 * 6 + c.2) / 10 }
    func sat(_ x: Int, _ y: Int) -> Int { let c = rgb(x, y); return max(c.0, c.1, c.2) - min(c.0, c.1, c.2) }
    func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h }
}

/// Along a ray from `from` (outside the card, in the dim) toward the card: the first accent (ring)
/// pixel, the first pixel after the ring, and the card's own edge found in the solid base image
/// (first pixel whose luminance departs from the gap's by > 3 levels). All in px from `from`.
func ray(base: Pixels, tour: Pixels, from: (Int, Int), dir: (Int, Int), maxLen: Int) -> (ringOut: Int?, ringIn: Int?, card: Int?) {
    var ringOut: Int?, ringIn: Int?, card: Int?
    var i = 0
    while i < maxLen {
        let x = from.0 + dir.0 * i, y = from.1 + dir.1 * i
        guard tour.inside(x, y) else { break }
        let accent = tour.sat(x, y) > 70
        if ringOut == nil, accent { ringOut = i }
        if ringOut != nil, ringIn == nil, !accent { ringIn = i }
        if let ri = ringIn, card == nil, i > ri {
            let gapLum = base.lum(from.0 + dir.0 * ri, from.1 + dir.1 * ri)
            if abs(base.lum(x, y) - gapLum) > 3 { card = i }
        }
        if card != nil { break }
        i += 1
    }
    return (ringOut, ringIn, card)
}

// MARK: Views

/// Reads the same anchors the overlay reads, on the same panel frame.
nonisolated(unsafe) var anchorRects: [String: CGRect] = [:]
struct AnchorRead: ViewModifier {
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
                     offersTour: tour.offersTour, onTour: {}, onDismissOffer: {})
            .frame(width: Design.panelWidth, height: Design.panelHeight)
            .tourHost(tour, showing: true).modifier(AnchorRead())
            .clipped()
            .background(PanelBackdrop())
            .defaultAppStorage(defaults)
    }
}

func dropSuite(_ name: String) {
    UserDefaults.standard.removePersistentDomain(forName: name)
    try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(name).plist"))
}

@MainActor func breakdownShot(_ live: Live, metric: BreakdownMetric, name: String, expand: Bool) {
    // Keep it live for a few scans so the rows are real.
    for _ in 0..<3 {
        let r = live.scan(metric); live.store.setBreakdown(r.apps, measuring: r.measuring, totalCPU: r.totalCPUPercent)
        live.tick(); settle(0.6)
    }
    for dark in [false, true] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let w = makeWindow(BreakdownView(store: live.store, metric: metric, quitHint: metric == .cpu && !dark, onBack: {})
            .background(PanelBackdrop()))
        settle(0.8)
        if expand {
            // The app with the most processes; app rows are ~36 pt tall from y = 40 (+ parts card on memory).
            let rows = live.store.breakdown
            if let i = rows.firstIndex(where: { $0.isApp && $0.processes.count > 2 }) ?? rows.firstIndex(where: { $0.processes.count > 1 }) {
                let top: CGFloat = metric == .cpu ? 40 : 40 + 44
                let y = top + 36 * CGFloat(i) + 18
                if y < Design.panelHeight - 50 {
                    live.store.setBreakdownPinnedApp(rows[i].appPID)
                    click(w, CGPoint(x: 150, y: y))
                    settle(0.6)
                } else { log("expand: row \(i) below the fold") }
            }
        }
        save(capture(w), "\(name)-\(dark ? "dark" : "light")")
        w.orderOut(nil); w.close()
    }
}

@MainActor func render(_ live: Live) {
    let suiteName = "MacStatsReviewB-\(UUID().uuidString)"
    defer { dropSuite(suiteName) }
    let d = UserDefaults(suiteName: suiteName)!
    d.set(TourAudience.existing.rawValue, forKey: TourKey.audience)
    let hasBattery = live.store.battery != nil

    for dark in [false, true] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let look = dark ? "dark" : "light"
        // Overview + every tour step, showcase (glass) window.
        let tour = TourController(defaults: d, hasBattery: { hasBattery })
        let w = makeWindow(Panel(store: live.store, tour: tour, defaults: d))
        settle(0.9)
        save(capture(w), "overview-\(look)")
        tour.start()
        var i = 1
        while tour.currentStep != nil {
            settle(0.9); save(capture(w), "tour-step\(i)-\(look)"); tour.next(); i += 1
        }
        w.orderOut(nil); w.close()

        // Measurement: the same, on a solid panel so card edges are crisp.
        let mt = TourController(defaults: d, hasBattery: { hasBattery })
        let mw = makeWindow(Panel(store: live.store, tour: mt, defaults: d), solid: true)
        settle(0.9)
        guard let baseImg = capture(mw) else { return }
        let base = Pixels(baseImg)
        let s = CGFloat(base.w) / Design.panelWidth
        anchorRects = [:]
        mt.start()
        while let cur = mt.currentStep {
            settle(0.9)
            guard let img = capture(mw), let target = anchorRects[cur.step.anchor] else { log("missing \(cur.step.id)"); mt.next(); continue }
            let t = Pixels(img)
            let panel = CGRect(x: 0, y: 0, width: Design.panelWidth, height: Design.panelHeight)
            let cut = TourLayout.cutout(target: target, targetRadius: Design.cardCornerRadius, panel: panel, scale: s)
            func px(_ v: CGFloat) -> Int { Int((v * s).rounded()) }
            let midX = px(target.midX), midY = px(target.midY), far = px(8)
            // Rays from 8 pt outside the target toward it.
            let L = ray(base: base, tour: t, from: (px(target.minX) - far, midY), dir: (1, 0), maxLen: far * 2)
            let R = ray(base: base, tour: t, from: (px(target.maxX) + far - 1, midY), dir: (-1, 0), maxLen: far * 2)
            let T = ray(base: base, tour: t, from: (midX, px(target.minY) - far), dir: (0, 1), maxLen: far * 2)
            let Bm = ray(base: base, tour: t, from: (midX, px(target.maxY) + far - 1), dir: (0, -1), maxLen: far * 2)
            func inset(_ r: (ringOut: Int?, ringIn: Int?, card: Int?)) -> String {
                guard let o = r.ringOut, let c = r.card, let ri = r.ringIn else { return "n/a" }
                return String(format: "%.1f(ring %.1f, gap %.1f)", CGFloat(c - o) / s, CGFloat(ri - o) / s, CGFloat(c - ri) / s)
            }
            // Corners: along the 45° diagonal through the card's corner-arc centre.
            let r8 = Design.cardCornerRadius
            var corners: [String] = []
            for (cx, cy, dx, dy) in [(target.minX + r8, target.minY + r8, -1, -1), (target.maxX - r8, target.minY + r8, 1, -1),
                                     (target.minX + r8, target.maxY - r8, -1, 1), (target.maxX - r8, target.maxY - r8, 1, 1)] {
                // Start 8 pt beyond the arc along the diagonal and walk back in.
                let dist = (r8 + 8) / sqrt(2)
                let start = (px(cx + CGFloat(dx) * dist), px(cy + CGFloat(dy) * dist))
                let rr = ray(base: base, tour: t, from: start, dir: (-dx, -dy), maxLen: px(16))
                if let o = rr.ringOut, let c = rr.card { corners.append(String(format: "%.1f", CGFloat(c - o) * sqrt(2) / s)) }
                else { corners.append("n/a") }
            }
            func f(_ r: CGRect) -> String { String(format: "(%.1f,%.1f %.1fx%.1f)", r.minX, r.minY, r.width, r.height) }
            log("tour \(look) step=\(cur.step.id) target=\(f(target)) cutout=\(f(cut.rect)) r=\(cut.radius) "
                + "geom insets L=\(target.minX - cut.rect.minX) R=\(cut.rect.maxX - target.maxX) T=\(target.minY - cut.rect.minY) B=\(cut.rect.maxY - target.maxY) | "
                + "pixel insets(pt) L=\(inset(L)) R=\(inset(R)) T=\(inset(T)) B=\(inset(Bm)) corners(diag pt)=\(corners.joined(separator: ","))")
            mt.next()
        }
        mw.orderOut(nil); mw.close()

        // Welcome (new user) and the chip (existing user).
        let wn = "MacStatsReviewB-w-\(UUID().uuidString)"
        let wd = UserDefaults(suiteName: wn)!
        wd.set(TourAudience.new.rawValue, forKey: TourKey.audience)
        let wt = TourController(defaults: wd, hasBattery: { hasBattery })
        wt.panelOpened()
        let ww = makeWindow(Panel(store: live.store, tour: wt, defaults: wd))
        settle(1.0); save(capture(ww), "welcome-\(look)"); ww.orderOut(nil); ww.close()
        // Welcome centering on a solid panel: rows/cols brighter than the dim.
        let ws = makeWindow(Panel(store: live.store, tour: wt, defaults: wd), solid: true)
        settle(1.0)
        if let img = capture(ws) {
            let p = Pixels(img); let s2 = CGFloat(p.w) / Design.panelWidth
            let dimRef = p.lum(Int(4 * s2), p.h / 2)
            var top = -1, bottom = -1, left = -1, right = -1
            for y in 0..<p.h where p.lum(p.w / 2, y) > dimRef + 8 { if top < 0 { top = y }; bottom = y }
            for x in 0..<p.w where p.lum(x, p.h / 2) > dimRef + 8 { if left < 0 { left = x }; right = x }
            log(String(format: "welcome %@ card margins(pt): top=%.1f bottom=%.1f left=%.1f right=%.1f", look,
                       CGFloat(top) / s2, CGFloat(p.h - 1 - bottom) / s2, CGFloat(left) / s2, CGFloat(p.w - 1 - right) / s2))
        }
        ws.orderOut(nil); ws.close()
        dropSuite(wn)

        let cn = "MacStatsReviewB-c-\(UUID().uuidString)"
        let cd = UserDefaults(suiteName: cn)!
        cd.set(TourAudience.existing.rawValue, forKey: TourKey.audience)
        let ct = TourController(defaults: cd, hasBattery: { hasBattery })
        ct.panelOpened()
        let cw = makeWindow(Panel(store: live.store, tour: ct, defaults: cd))
        settle(0.8); save(capture(cw), "chip-\(look)"); cw.orderOut(nil); cw.close()
        dropSuite(cn)

        let sw = makeWindow(SettingsView(onBack: {}).frame(width: Design.panelWidth, height: Design.panelHeight)
            .background(PanelBackdrop()).defaultAppStorage(d))
        settle(0.8); save(capture(sw), "settings-\(look)"); sw.orderOut(nil); sw.close()
    }
}

/// MacStats-like CPU cost of the open overview: 15 s tour off, 15 s on step 1, live ticks at 0.5 s.
@MainActor func cost(_ live: Live) {
    let n = "MacStatsReviewB-k-\(UUID().uuidString)"
    defer { dropSuite(n) }
    let d = UserDefaults(suiteName: n)!
    d.set(TourAudience.existing.rawValue, forKey: TourKey.audience)
    NSApp.appearance = NSAppearance(named: .aqua)
    let tour = TourController(defaults: d, hasBattery: { true })
    let w = makeWindow(Panel(store: live.store, tour: tour, defaults: d))
    settle(1)
    func run(_ label: String) {
        let c0 = cpuSeconds(), t0 = Date()
        while Date().timeIntervalSince(t0) < 15 { live.tick(); RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        log(String(format: "cost %@ probe_process_cpu_pct=%.2f", label, (cpuSeconds() - c0) / Date().timeIntervalSince(t0) * 100))
    }
    run("overview-tour-off")
    tour.start()
    run("overview-tour-on-step1")
    tour.skip()
    w.orderOut(nil); w.close()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let live = Live()
    live.tick(); live.slow()
    settle(0.6); live.tick()
    if mode == "inv" {
        stability(live, metric: .cpu, seconds: stabSeconds)
        stability(live, metric: .energy, seconds: stabSeconds)
        stability(live, metric: .memory, seconds: stabSeconds)
    }
    if mode == "all" || mode == "stability" {
        stability(live, metric: .cpu, seconds: stabSeconds)
        if mode == "all" { breakdownShot(live, metric: .cpu, name: "breakdown-cpu-expanded", expand: true) }
        stability(live, metric: .memory, seconds: max(60, stabSeconds - 10))
        if mode == "all" { breakdownShot(live, metric: .memory, name: "breakdown-memory-expanded", expand: true) }
        stability(live, metric: .energy, seconds: max(60, stabSeconds - 10))
        if mode == "all" { breakdownShot(live, metric: .energy, name: "breakdown-battery", expand: false) }
        let mean = live.scanMs.isEmpty ? 0 : live.scanMs.reduce(0, +) / Double(live.scanMs.count)
        log(String(format: "scan_ms mean=%.2f max=%.2f n=%d", mean, live.scanMs.max() ?? 0, live.scanMs.count))
        live.store.clearBreakdown()
    }
    if mode == "all" || mode == "render" {
        if live.store.cpuHistory.count < 60 { for _ in 0..<40 { live.tick(); settle(0.5) } }
        live.slow()
        render(live)
        cost(live)
    }
    try? (report.joined(separator: "\n") + "\n").write(toFile: "\(outDir)/report.txt", atomically: true, encoding: .utf8)
    print("done")
}

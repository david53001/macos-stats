// Off-screen checks of the review-round-1 fixes (README.md): the real BreakdownView / OverviewView /
// tour overlay in windows at desktop level + 1, ordered back, never activated, closed after use.
//  1. A process that ends while the list is frozen stays in place as a dimmed "Ended" row.
//  2. A click inside the tour's cutout reaches the highlighted card; a click on the dim does not.
//  3. The breakdown's PointerProbe reports the real pointer: inside when the list is under it.
// Tour state uses a throwaway UserDefaults suite, deleted at the end.
import AppKit
import SwiftUI
import MacStatsCore

setvbuf(stdout, nil, _IONBF, 0)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "out"
nonisolated(unsafe) var report: [String] = []
nonisolated(unsafe) var failures = 0
func log(_ s: String) { print(s); report.append(s) }
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1 }; log("\(ok ? "PASS" : "FAIL") \(what)") }

@MainActor func settle(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
}

@MainActor func makeWindow<V: View>(_ view: V, origin: NSPoint = NSPoint(x: 40, y: 40)) -> NSWindow {
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
    w.setFrameOrigin(origin)
    w.orderBack(nil)
    return w
}

@MainActor func save(_ w: NSWindow, _ name: String) {
    guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber),
                                            [.boundsIgnoreFraming, .bestResolution]) else { log("capture failed \(name)"); return }
    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    log("wrote \(name)")
}

/// A synthetic click at `point` (panel points, top-left origin) delivered to the view under it.
@MainActor func click(_ w: NSWindow, at point: CGPoint) {
    guard let content = w.contentView else { return }
    let p = NSPoint(x: point.x, y: content.bounds.height - point.y)
    let hit = content.hitTest(p)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { continue }
        if type == .leftMouseDown { hit?.mouseDown(with: e) } else { hit?.mouseUp(with: e) }
        settle(0.05)
    }
}

@MainActor func app(_ pid: Int32, _ cpu: Double, children: [(Int32, Double)]) -> AppUsage {
    AppUsage(appPID: pid, processes: children.map { ProcessUsage(pid: $0.0, appPID: pid, cpuPercent: $0.1, memoryBytes: 0) },
             cpuPercent: cpu, memoryBytes: 0)
}

MainActor.assumeIsolated {
    let nsApp = NSApplication.shared
    nsApp.setActivationPolicy(.accessory)
    let me = Int32(getpid())
    let others = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        .map { Int32($0.processIdentifier) }.filter { $0 != me }.prefix(3)
    // Children: this probe's own pid + a few launchd-era pids that exist on every Mac, so names resolve.
    let kids: [(Int32, Double)] = [(me, 4), (1, 2), (Int32(getppid()), 1.5), (me &+ 100_000, 1)]

    for (look, dark) in [("light", false), ("dark", true)] {
        nsApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        // 1. Ended process placeholder in an expanded app.
        let store = MetricsStore()
        store.beginBreakdown(metric: .cpu)
        var rows = [app(me, 8.5, children: kids)] + others.enumerated().map { app($1, 2 - Double($0) * 0.5, children: [($1, 2 - Double($0) * 0.5)]) }
        store.setBreakdown(rows, measuring: false, totalCPU: 20, time: 0)
        let w = makeWindow(BreakdownView(store: store, metric: .cpu, quitHint: true, onBack: {}))
        settle(0.6)
        click(w, at: CGPoint(x: 160, y: 66))   // the first app row: expand it
        settle(0.5)
        store.setBreakdownPointerInside(true, time: 1)
        rows[0] = app(me, 6.5, children: kids.filter { $0.0 != 1 })   // pid 1's row "ended"
        store.setBreakdown(rows, measuring: false, totalCPU: 20, time: 2)
        settle(0.6)
        let pids = store.breakdown.first?.pids ?? []
        check(pids == kids.map(\.0) && store.isEnded(app: me, pid: 1), "\(look): ended child keeps its place \(pids)")
        save(w, "breakdown-ended-child-\(look)")
        w.orderOut(nil); w.close()
    }
    nsApp.appearance = NSAppearance(named: .aqua)

    // 2. Tour click-through: on step 1 a click on the CPU card selects it; a click on the dim doesn't.
    let suiteName = "MacStatsR1Probe-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(TourAudience.existing.rawValue, forKey: TourKey.audience)
    let tour = TourController(defaults: defaults, hasBattery: { true })
    tour.start()
    nonisolated(unsafe) var selected: [BreakdownMetric] = []
    let store = MetricsStore()
    store.setBattery(BatterySample(percent: 64, state: .discharging, timeToEmptyMinutes: 245))
    let panel = OverviewView(store: store, onSelect: { selected.append($0) }, onEmptyTrash: {}, onSettings: {})
        .frame(width: Design.panelWidth, height: Design.panelHeight)
        .tourHost(tour, showing: true)
        .defaultAppStorage(defaults)
    // Control: with the tour off, the same synthetic click reaches the card.
    let offTour = TourController(defaults: defaults, hasBattery: { true })
    let cw = makeWindow(OverviewView(store: store, onSelect: { selected.append($0) }, onEmptyTrash: {}, onSettings: {})
        .frame(width: Design.panelWidth, height: Design.panelHeight).tourHost(offTour, showing: true))
    settle(0.8)
    click(cw, at: CGPoint(x: 160, y: 69))
    check(selected == [.cpu], "control: without the tour the click reaches the CPU card (\(selected))")
    selected = []
    cw.orderOut(nil); cw.close()

    // Why TourOverlay puts `.onHover` before its content shape: a plain even-odd dim with the CPU
    // card's hole. 0 = contentShape(eo) + tap; 1 = the same + .onHover AFTER (the hole is blocked);
    // 2 = no gesture at all; 3 = .onHover BEFORE contentShape(eo) + tap (what TourOverlay does).
    for variant in 0...3 {
        selected = []
        let hole = CGRect(x: 5, y: 33, width: 310, height: 73)
        let ew = makeWindow(OverviewView(store: store, onSelect: { selected.append($0) }, onEmptyTrash: {}, onSettings: {})
            .frame(width: Design.panelWidth, height: Design.panelHeight)
            .overlay {
                let shape = ExpHoled(hole: hole)
                switch variant {
                case 0: shape.fill(Color.black.opacity(0.3), style: FillStyle(eoFill: true))
                        .contentShape(shape, eoFill: true).onTapGesture {}
                case 1: shape.fill(Color.black.opacity(0.3), style: FillStyle(eoFill: true))
                        .contentShape(shape, eoFill: true).onTapGesture {}.onHover { _ in }
                case 2: shape.fill(Color.black.opacity(0.3), style: FillStyle(eoFill: true))
                default: shape.fill(Color.black.opacity(0.3), style: FillStyle(eoFill: true))
                        .onHover { _ in }.contentShape(shape, eoFill: true).onTapGesture {}
                }
            })
        settle(0.6)
        click(ew, at: CGPoint(x: 160, y: 69))
        log("dim variant \(variant): \(selected)")
        ew.orderOut(nil); ew.close()
    }
    selected = []

    let tw = makeWindow(panel)
    settle(0.8)
    click(tw, at: CGPoint(x: 160, y: 288))   // the Battery card, under the dim (not the callout)
    check(selected.isEmpty, "tour: a click on the dim does nothing (\(selected))")
    click(tw, at: CGPoint(x: 160, y: 69))    // the CPU card, inside the cutout
    check(selected == [.cpu], "tour: a click in the cutout reaches the CPU card (\(selected))")
    tw.orderOut(nil); tw.close()
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
    let plist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(suiteName).plist")
    try? FileManager.default.removeItem(at: plist)

    // 3. PointerProbe: put the list under the real pointer, then away from it.
    let ps = MetricsStore()
    ps.beginBreakdown(metric: .cpu)
    ps.setBreakdown([app(me, 5, children: [(me, 5)])], measuring: false, totalCPU: 10, time: 0)
    let mouse = NSEvent.mouseLocation
    // Panel point (160, 200) from the top-left = inside the list.
    let pw = makeWindow(BreakdownView(store: ps, metric: .cpu, onBack: {}),
                        origin: NSPoint(x: mouse.x - 160, y: mouse.y - (Design.panelHeight - 200)))
    settle(0.6)
    let inside = ps.breakdownPointerProbe?() ?? false
    pw.setFrameOrigin(NSPoint(x: mouse.x + 600, y: mouse.y + 600))   // far from the pointer
    settle(0.2)
    let away = ps.breakdownPointerProbe?() ?? true
    check(inside && !away, "pointer probe: inside=\(inside) away=\(away) (mouse \(mouse))")
    pw.orderOut(nil); pw.close()

    log("failures=\(failures)")
    try? (report.joined(separator: "\n") + "\n").write(toFile: "\(outDir)/report.txt", atomically: true, encoding: .utf8)
    exit(0)
}

struct ExpHoled: Shape {
    var hole: CGRect
    func path(in rect: CGRect) -> Path { var p = Path(rect); p.addRect(hole); return p }
}

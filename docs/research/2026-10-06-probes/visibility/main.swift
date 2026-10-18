import AppKit
import SwiftUI

// Does SwiftUI's onDisappear fire when the hosting window is ordered out, and does the
// occlusion / key observer report it? (Mechanics behind AppModel.panelWindowChanged.)
final class Log { static var lines: [String] = []; static func add(_ s: String) { lines.append(String(format: "%6.2f ", CFAbsoluteTimeGetCurrent().truncatingRemainder(dividingBy: 1000)) + s); print(lines.last!) } }

struct Observer: NSViewRepresentable {
    func makeNSView(context: Context) -> V { V() }
    func updateNSView(_ v: V, context: Context) {}
    final class V: NSView {
        var obs: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            obs.forEach(NotificationCenter.default.removeObserver); obs = []
            guard let window else { return }
            obs = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification].map { n in
                NotificationCenter.default.addObserver(forName: n, object: window, queue: .main) { [weak self] note in
                    guard let w = self?.window else { return }
                    Log.add("notify \(note.name.rawValue.replacingOccurrences(of: "NSWindowDid", with: "")) isVisible=\(w.isVisible) occl.visible=\(w.occlusionState.contains(.visible)) => onScreen=\(w.isVisible && w.occlusionState.contains(.visible))")
                }
            }
        }
    }
}

struct Content: View {
    var body: some View {
        Text("probe").frame(width: 200, height: 100)
            .background(Observer())
            .onAppear { Log.add("onAppear") }
            .onDisappear { Log.add("onDisappear") }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let w = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 200, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
w.isReleasedWhenClosed = false
w.contentView = NSHostingView(rootView: Content())
func step(_ t: Double, _ label: String, _ body: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + t) { Log.add("== \(label)"); body() }
}
step(0.2, "orderBack") { w.orderBack(nil) }
step(1.5, "orderOut") { w.orderOut(nil) }
step(3.0, "orderBack again") { w.orderBack(nil) }
step(4.5, "orderOut again") { w.orderOut(nil) }
step(6.0, "close") { w.close() }
step(7.0, "exit") { exit(0) }
app.run()

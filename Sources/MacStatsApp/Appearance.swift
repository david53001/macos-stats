import AppKit
import SwiftUI
import MacStatsCore

/// The popover background's response to the Opacity setting (`UIOpacity`, key `uiOpacity`).
/// Placed behind the screens in `RootView`; the default (0.5) draws nothing and touches nothing,
/// so the popover looks exactly like the plain `MenuBarExtra` panel.
///
/// - Toward 1.0: a window-background-colour layer behind the cards, clipped to the panel's
///   continuous corners, fades in until the panel is fully solid.
/// - Toward 0.0: the system's Liquid Glass tint is thinned (`PopoverGlass`), so more of what's
///   behind shows through while the blur (and therefore legibility) stays. Text is never faded.
struct PanelBackdrop: View {
    @AppStorage(UIOpacity.key) private var opacity = UIOpacity.defaultValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: Design.panelCornerRadius, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor))
            .opacity(UIOpacity.solidBackgroundAlpha(opacity))
            .background(GlassTintHook(scale: UIOpacity.glassTintScale(opacity), colorScheme: colorScheme))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Gives `PopoverGlass` the panel's window and re-applies the tint whenever the setting or the
/// appearance changes (the system rebuilds its glass on appearance changes) and on every open.
private struct GlassTintHook: NSViewRepresentable {
    let scale: Double
    /// Only here so an appearance change re-runs `updateNSView`.
    let colorScheme: ColorScheme

    func makeNSView(context: Context) -> HookView { HookView() }

    func updateNSView(_ view: HookView, context: Context) {
        view.scale = scale
        view.apply()
    }

    final class HookView: NSView {
        var scale = 1.0
        private var observers: [NSObjectProtocol] = []

        /// The panel window is reused across opens and the system rebuilds its glass each time
        /// it's shown, so re-apply whenever it's shown (occlusion change) or becomes key.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let window {
                observers = [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification]
                    .map { name in
                        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                            MainActor.assumeIsolated { self?.apply() }
                        }
                    }
            }
            apply()
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        /// Deferred one turn so SwiftUI has finished (re)building the glass layers first.
        func apply() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                PopoverGlass.setTintScale(self.scale, in: window)
            }
        }
    }
}

/// Thins the Liquid Glass behind the `MenuBarExtra` panel.
///
/// Why this reaches into private layers: on macOS 26 the panel's background is SwiftUI's own
/// Liquid Glass, rendered for the private `MenuBarExtraWindow` as a `CABackdropLayer` with a
/// `glassBackground` filter (found 2026-09-30 by dumping the layer tree; see
/// `docs/superpowers/plans/2026-09-30-opacity-progress.md`). There is no public way to change it:
/// `containerBackground(_:for: .window)` is ignored by `MenuBarExtra`, window
/// `backgroundColor`/`isOpaque` don't affect it, and fading the backdrop layer (or the window's
/// `alphaValue`) shows the page behind *unblurred*, which makes text unreadable. Scaling the
/// alpha of the filter's face fill colour keeps the blur and only lightens the tint.
///
/// Fails safe: if the layer or filter isn't there (another OS version), nothing happens and the
/// popover keeps its default look. At scale 1, or with Reduce Transparency on, the system's own
/// value is restored.
@MainActor
enum PopoverGlass {
    private static let fillKeyPath = "filters.glassBackground.inputFaceColorMatrixFillColor"
    /// Stored on the backdrop layer (CALayer accepts arbitrary KVC keys): the system's fill,
    /// and the fill we last wrote, so a system rebuild (new fill) is detected and adopted.
    private static let originalKey = "macstatsSystemGlassFill"
    private static let appliedKey = "macstatsAppliedGlassFill"

    static func setTintScale(_ scale: Double, in window: NSWindow) {
        guard let root = window.contentView?.superview?.layer ?? window.contentView?.layer else { return }
        let effective = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : scale
        forEachGlassLayer(in: root) { apply(effective, to: $0) }
    }

    private static func apply(_ scale: Double, to layer: CALayer) {
        guard let current = color(layer.value(forKeyPath: fillKeyPath)) else { return }
        let applied = color(layer.value(forKey: appliedKey))
        // If what's there isn't what we wrote, the system (re)built the glass: that's the original.
        let original: CGColor
        if let applied, applied == current, let stored = color(layer.value(forKey: originalKey)) {
            original = stored
        } else {
            original = current
            layer.setValue(current, forKey: originalKey)
        }
        let target = scale >= 1 ? original : original.copy(alpha: original.alpha * scale) ?? original
        guard target != current else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(target, forKeyPath: fillKeyPath)
        CATransaction.commit()
        layer.setValue(target, forKey: appliedKey)
    }

    private static func forEachGlassLayer(in layer: CALayer, _ body: (CALayer) -> Void) {
        if NSStringFromClass(type(of: layer)) == "CABackdropLayer",
           layer.filters?.contains(where: { ($0 as? NSObject)?.value(forKey: "name") as? String == "glassBackground" }) == true {
            body(layer)
        }
        for sublayer in layer.sublayers ?? [] { forEachGlassLayer(in: sublayer, body) }
    }

    private static func color(_ value: Any?) -> CGColor? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CGColor.typeID else { return nil }
        return (value as! CGColor)
    }
}

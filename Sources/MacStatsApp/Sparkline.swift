import AppKit
import SwiftUI
import MacStatsCore

/// A compact Apple-style chart of a metric's recent history: gradient area under a
/// round-capped line, on a fixed time axis — x comes from each sample's time, the newest
/// sample sits at the right edge and `window` seconds span the width, so nothing stretches
/// as points arrive. The curve is monotone (no overshoot above the peak or below zero).
///
/// Motion: when a sample arrives the curve is redrawn once at its new position, shown offset
/// right by one open-panel sample interval and slid back to zero until the next sample
/// (`sparklineSlideLag`), so the graph drifts left slowly and steadily rather than hopping.
/// The graph is Core Animation layers (`SparklineLayerView`), not SwiftUI drawing: the card is
/// a `Button`, so a SwiftUI graph shared the card's one CPU-drawn layer and every frame of the
/// slide re-rendered the card's text too (~8 % of a core with the overview open). The slide is
/// a layer animation, so between samples the app does no work.
struct Sparkline: View {
    let points: [SamplePoint]
    let color: Color
    /// Upper bound of the Y scale, or 0 for a dynamic "nice" bound that follows the data.
    let maxValue: Double
    /// Floor for the dynamic bound, so idle noise draws as a flat line instead of a full-height one.
    var dynamicMinimum: Double = 1
    var window: TimeInterval = 60

    var body: some View {
        let end = points.last?.time ?? 0
        // The slide shows up to two sample intervals more on the left (`sparklineSlideLag`).
        let visible = Array(visibleSamples(points, end: end, window: window + 2 * refreshInterval(for: .popoverOpen)))
        let upper = maxValue > 0
            ? maxValue
            : niceUpperBound(peak: visible.map(\.value).max() ?? 0, minimum: dynamicMinimum)

        SparklineLayers(graph: SparklineGraph(samples: visible, end: end, window: window, upper: upper),
                        color: color)
            .background(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)   // baseline hairline
            }
            .frame(height: 38)
    }
}

/// What one sparkline shows; the layer view redraws only when it changes.
private struct SparklineGraph: Equatable {
    let samples: [SamplePoint]
    let end: TimeInterval
    let window: TimeInterval
    let upper: Double

    func path(in rect: CGRect, area: Bool, upper: Double? = nil) -> CGPath {
        sparklinePath(samples: samples, end: end, window: window, upper: upper ?? self.upper, in: rect, area: area)
    }
}

private struct SparklineLayers: NSViewRepresentable {
    let graph: SparklineGraph
    let color: Color

    func makeNSView(context: Context) -> SparklineLayerView { SparklineLayerView() }

    func updateNSView(_ view: SparklineLayerView, context: Context) {
        view.color = color
        view.show(graph)
    }
}

/// The sparkline's layers: `slideLayer` (moved by the slide) holds the gradient fill, masked by
/// the area path, and the line on top. Paths are set once a sample, with implicit animations off.
private final class SparklineLayerView: NSView {
    var color: Color = .clear {
        didSet { if color != oldValue { applyColors() } }
    }

    private var graph: SparklineGraph?
    /// A new view (the card was rebuilt, e.g. the tour's anchor toggling) slides from the clock
    /// once layout gives it a width, so the graph keeps its place instead of snapping left.
    private var needsInitialSlide = false
    private let slideLayer = CALayer()
    private let fillLayer = CAGradientLayer()
    private let areaMask = CAShapeLayer()
    private let lineLayer = CAShapeLayer()
    private var allLayers: [CALayer] { [slideLayer, fillLayer, areaMask, lineLayer] }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = true
        fillLayer.mask = areaMask
        lineLayer.fillColor = nil
        lineLayer.lineWidth = 1.6
        lineLayer.lineCap = .round
        lineLayer.lineJoin = .round
        slideLayer.addSublayer(fillLayer)
        slideLayer.addSublayer(lineLayer)
        layer?.addSublayer(slideLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// y down, as `sparklinePath` draws.
    override var isFlipped: Bool { true }

    /// Clicks and hover go to the card underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let frame = CGRect(origin: .zero, size: bounds.size)
        guard frame != slideLayer.frame else { return }
        withoutActions {
            allLayers.forEach { $0.frame = frame }
            setPaths()
            startInitialSlideIfReady()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()   // light/dark
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyScale()
    }

    func show(_ new: SparklineGraph) {
        guard new != graph else { return }   // SwiftUI also updates the view when the card's text changes
        let old = graph
        graph = new
        withoutActions {
            setPaths()
            if let old {
                animate(from: old, to: new)
            } else {
                needsInitialSlide = true
                startInitialSlideIfReady()
            }
        }
    }

    private func setPaths() {
        guard let graph else { return }
        let rect = CGRect(origin: .zero, size: bounds.size)
        areaMask.path = graph.path(in: rect, area: true)
        lineLayer.path = graph.path(in: rect, area: false)
    }

    private func animate(from old: SparklineGraph, to new: SparklineGraph) {
        let rect = CGRect(origin: .zero, size: bounds.size)
        // A dynamic scale change (network only, rare) eases: the new samples from the old scale.
        if old.upper != new.upper {
            for (shape, area) in [(areaMask, true), (lineLayer, false)] {
                let rescale = CABasicAnimation(keyPath: "path")
                rescale.fromValue = new.path(in: rect, area: area, upper: old.upper)
                rescale.toValue = shape.path
                rescale.duration = 0.4
                rescale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                shape.add(rescale, forKey: "rescale")
            }
        }
        // The slide. A longer gap (the first sample after reopening) shows in place; a late sample
        // holds still at the end of the last slide (the model offset is 0).
        let interval = refreshInterval(for: .popoverOpen)
        let gap = new.end - old.end
        guard gap > 0, gap <= 2 * interval else { return }
        slide(new)
    }

    /// The first slide of a new view, from the clock as the old SwiftUI graph did.
    private func startInitialSlideIfReady() {
        guard needsInitialSlide, let graph, bounds.width > 0 else { return }
        needsInitialSlide = false
        slide(graph)
    }

    /// Shows `graph` `sparklineSlideLag` behind and slides it to 0 by the next sample.
    private func slide(_ graph: SparklineGraph) {
        guard graph.window > 0 else { return }
        let lag = sparklineSlideLag(end: graph.end, now: Date().timeIntervalSinceReferenceDate,
                                    interval: refreshInterval(for: .popoverOpen))
        guard lag > 0 else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = lag / graph.window * Double(sparklinePlotWidth(bounds.width))
        slide.toValue = 0
        slide.duration = lag
        slide.timingFunction = CAMediaTimingFunction(name: .linear)
        slideLayer.add(slide, forKey: "slide")
    }

    /// Resolves the SwiftUI color for this view's appearance (system colors differ in dark mode).
    private func applyColors() {
        var line: CGColor?, top: CGColor?, bottom: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let resolved = NSColor(color)
            line = resolved.cgColor
            top = resolved.withAlphaComponent(resolved.alphaComponent * 0.45).cgColor
            bottom = resolved.withAlphaComponent(0).cgColor
        }
        withoutActions {
            lineLayer.strokeColor = line
            fillLayer.colors = [top, bottom].compactMap { $0 }
        }
    }

    private func applyScale() {
        guard let scale = window?.backingScaleFactor else { return }
        withoutActions { allLayers.forEach { $0.contentsScale = scale } }
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

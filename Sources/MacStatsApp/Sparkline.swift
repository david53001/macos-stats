import SwiftUI
import MacStatsCore

/// A compact Apple-style chart of a metric's recent history: gradient area under a
/// round-capped line, on a fixed time axis — x comes from each sample's time, the newest
/// sample sits at the right edge and `window` seconds span the width, so nothing stretches
/// as points arrive. The curve is monotone (no overshoot above the peak or below zero).
///
/// Motion: when a sample arrives the curve is redrawn once at its new position, then shown
/// offset right by the time that just elapsed and slid back to zero — linearly, over one
/// open-popover sample interval, so the graph drifts left slowly and steadily rather than
/// hopping. Only an `offset` is animated, so no path is rebuilt per frame.
struct Sparkline: View {
    let points: [SamplePoint]
    let color: Color
    /// Upper bound of the Y scale, or 0 for a dynamic "nice" bound that follows the data.
    let maxValue: Double
    /// Floor for the dynamic bound, so idle noise draws as a flat line instead of a full-height one.
    var dynamicMinimum: Double = 1
    var window: TimeInterval = 60

    /// The newest-sample time the chart is currently shown at. It trails `points.last` for
    /// the length of a slide; `nil` until the first sample change (shown in place).
    @State private var shownEnd: TimeInterval?

    /// Longer gaps (e.g. the first sample after reopening) jump instead of sliding.
    private static let slideLimit: TimeInterval = 2

    var body: some View {
        let end = points.last?.time ?? 0
        let visible = Array(visibleSamples(points, end: end, window: window + Self.slideLimit))
        let upper = maxValue > 0
            ? maxValue
            : niceUpperBound(peak: visible.map(\.value).max() ?? 0, minimum: dynamicMinimum)
        let lag = min(max(end - (shownEnd ?? end), 0), Self.slideLimit)

        GeometryReader { geo in
            let slide = CGFloat(lag / window) * SparklineShape.plotWidth(geo.size.width)
            ZStack {
                shape(.area, visible, end, upper)
                    .fill(LinearGradient(colors: [color.opacity(0.45), color.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                shape(.line, visible, end, upper)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
            .animation(.smooth(duration: 0.4), value: upper)   // rescale eases, rarely happens
            .offset(x: slide)
        }
        .background(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)   // baseline hairline
        }
        .clipped()
        .frame(height: 38)
        .onChange(of: end) { old, new in
            if new > old, new - old <= Self.slideLimit {
                withAnimation(.linear(duration: refreshInterval(for: .popoverOpen))) { shownEnd = new }
            } else {
                shownEnd = new
            }
        }
    }

    private func shape(_ part: SparklineShape.Part, _ samples: [SamplePoint],
                       _ end: TimeInterval, _ upper: Double) -> SparklineShape {
        SparklineShape(samples: samples, end: end, window: window, upper: upper, part: part)
    }
}

/// One layer of the sparkline (area or line) — both share this geometry so they
/// stay aligned. `upper` is animatable so a change of dynamic scale eases rather than jumps.
private struct SparklineShape: Shape {
    enum Part { case area, line }

    let samples: [SamplePoint]
    let end: TimeInterval
    let window: TimeInterval
    var upper: Double
    let part: Part

    static let edgeInset: CGFloat = 1.5
    /// Keeps the line's round cap inside the right edge.
    static func plotWidth(_ width: CGFloat) -> CGFloat { max(width - edgeInset - 1, 0) }

    var animatableData: Double {
        get { upper }
        set { upper = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let width = Self.plotWidth(rect.width)
        let top = rect.minY + Self.edgeInset + 0.5, bottom = rect.maxY - 1
        let scale = upper > 0 ? upper : 1
        let pts = samples.map { s -> CGPoint in
            let fraction = CGFloat(min(max(s.value / scale, 0), 1))
            return CGPoint(x: rect.minX + sparklineX(time: s.time, end: end, window: window, width: width),
                           y: bottom - fraction * (bottom - top))
        }
        var path = Path()
        guard let first = pts.first else { return path }

        path.move(to: first)
        let segments = monotoneCubicSegments(pts)
        for s in segments { path.addCurve(to: s.end, control1: s.control1, control2: s.control2) }
        if part == .area {
            let lastX = segments.last?.end.x ?? first.x
            path.addLine(to: CGPoint(x: lastX, y: rect.maxY))
            path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

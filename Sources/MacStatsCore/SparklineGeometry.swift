import Foundation
import CoreGraphics

/// Pure geometry behind the popover's sparklines, kept out of the view layer so it can be
/// unit-tested: the fixed time axis, the smooth-but-honest curve, and the dynamic y scale.

/// One cubic Bézier segment of a sparkline curve.
public struct CubicSegment: Equatable, Sendable {
    public let start: CGPoint
    public let control1: CGPoint
    public let control2: CGPoint
    public let end: CGPoint

    public init(start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint) {
        self.start = start; self.control1 = control1; self.control2 = control2; self.end = end
    }

    /// The point at parameter `t` (0...1) along the segment.
    public func point(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * start.x + b * control1.x + c * control2.x + d * end.x,
                       y: a * start.y + b * control1.y + c * control2.y + d * end.y)
    }
}

/// Smooth curve through `points` that is *monotone between neighbours*: each segment stays
/// within the y-range of its two endpoints, so the curve never overshoots above the peak or
/// dips below zero the way a Catmull-Rom spline does. Tangents use Steffen's method (the
/// same as d3's `curveMonotoneX`), which caps each slope at twice the smaller neighbouring
/// secant — inside Fritsch–Carlson's monotonicity region. Points whose x doesn't increase
/// are skipped (a duplicate timestamp would otherwise divide by zero).
public func monotoneCubicSegments(_ points: [CGPoint]) -> [CubicSegment] {
    var p: [CGPoint] = []
    p.reserveCapacity(points.count)
    for pt in points where p.last.map({ pt.x > $0.x }) ?? true { p.append(pt) }
    let n = p.count
    guard n >= 2 else { return [] }

    // Secant slope of each interval.
    var secant = [CGFloat](repeating: 0, count: n - 1)
    for i in 0..<(n - 1) { secant[i] = (p[i + 1].y - p[i].y) / (p[i + 1].x - p[i].x) }

    // Tangent at each point. Ends take the adjacent secant; interior points are zero at a
    // local extremum (secants change sign) and otherwise bounded by the smaller secant.
    var tangent = [CGFloat](repeating: 0, count: n)
    tangent[0] = secant[0]
    tangent[n - 1] = secant[n - 2]
    if n > 2 {
        for i in 1..<(n - 1) {
            let s0 = secant[i - 1], s1 = secant[i]
            let h0 = p[i].x - p[i - 1].x, h1 = p[i + 1].x - p[i].x
            let blended = (s0 * h1 + s1 * h0) / (h0 + h1)
            let sign = (s0 > 0 ? 1 : s0 < 0 ? -1 : 0) + (s1 > 0 ? 1 : s1 < 0 ? -1 : 0)
            tangent[i] = CGFloat(sign) * min(abs(s0), abs(s1), 0.5 * abs(blended))
        }
    }

    // Hermite → Bézier: control points a third of the interval in along each tangent.
    var segments: [CubicSegment] = []
    segments.reserveCapacity(n - 1)
    for i in 0..<(n - 1) {
        let dx = (p[i + 1].x - p[i].x) / 3
        segments.append(CubicSegment(
            start: p[i],
            control1: CGPoint(x: p[i].x + dx, y: p[i].y + tangent[i] * dx),
            control2: CGPoint(x: p[i + 1].x - dx, y: p[i + 1].y - tangent[i + 1] * dx),
            end: p[i + 1]))
    }
    return segments
}

/// Maps a sample time onto the chart's fixed time axis: `end` (the newest sample) lands at
/// `width`, `end - window` at 0, older times go negative (drawn off the left edge, clipped).
/// Positions depend only on time, so nothing stretches as new points arrive.
public func sparklineX(time: TimeInterval, end: TimeInterval, window: TimeInterval,
                       width: CGFloat) -> CGFloat {
    guard window > 0 else { return width }
    return width * CGFloat(1 - (end - time) / window)
}

/// The samples needed to draw the last `window` seconds before `end` (points must be in
/// time order): everything inside the window plus the one sample just before it, so the
/// curve enters from beyond the left edge instead of starting abruptly inside the chart.
public func visibleSamples(_ points: [SamplePoint], end: TimeInterval,
                           window: TimeInterval) -> ArraySlice<SamplePoint> {
    let start = end - window
    guard let firstInside = points.firstIndex(where: { $0.time >= start }) else {
        return points.suffix(1)
    }
    return points[max(0, firstInside - 1)...]
}

/// A rounded ("nice") y-axis maximum for a dynamically scaled chart: the smallest value on
/// the 1-2-5 ladder (…, 1, 2, 5, 10, 20, 50, …) that leaves `headroom` above `peak`.
/// Snapping to coarse steps means the scale only changes when traffic moves by a real
/// factor, not on every small wobble. Never below `minimum` (so idle noise stays flat).
public func niceUpperBound(peak: Double, headroom: Double = 1.25, minimum: Double = 1) -> Double {
    let target = max(peak * headroom, minimum)
    guard target.isFinite, target > 0 else { return max(minimum, 1) }
    let magnitude = pow(10, floor(log10(target)))
    for step in [1.0, 2.0, 5.0, 10.0] where step * magnitude >= target * (1 - 1e-9) {
        return step * magnitude
    }
    return 10 * magnitude
}

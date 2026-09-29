import Foundation

/// One timestamped sparkline reading. `time` is seconds since the reference date
/// (`Date().timeIntervalSinceReferenceDate`), so points taken at different cadences (the
/// 10s idle sampler, the fast open-popover ticks) sit at their true place on a time axis.
public struct SamplePoint: Equatable, Sendable {
    public let time: TimeInterval
    public let value: Double

    public init(time: TimeInterval, value: Double) {
        self.time = time
        self.value = value
    }
}

/// Drops points that have scrolled out of a sparkline's time window, in place. Keeps every
/// point within `window` seconds of the newest, plus the single newest point older than that —
/// the sparkline pins the newest point to its right edge, so that one older point is what lets
/// the line reach the left edge instead of starting part-way in. `maxCount` is a safety net
/// against a burst of samples growing the array without bound; it wins over the window.
/// Assumes `points` is ascending by time.
public func trimHistory(_ points: inout [SamplePoint], window: TimeInterval, maxCount: Int) {
    guard let newest = points.last?.time else { return }
    let cutoff = newest - window
    // First point strictly inside the window; the newest always is (window > 0).
    let firstInside = points.firstIndex { $0.time > cutoff } ?? points.count - 1
    let drop = max(firstInside - 1, points.count - maxCount, 0)
    if drop > 0 { points.removeFirst(drop) }
}

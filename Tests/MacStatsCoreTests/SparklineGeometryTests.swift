import Testing
import CoreGraphics
@testable import MacStatsCore

@Suite struct SparklineGeometryTests {
    /// Samples every segment densely and checks y stays within that segment's endpoints.
    private func expectNoOvershoot(_ points: [CGPoint]) {
        let segments = monotoneCubicSegments(points)
        for seg in segments {
            let lo = min(seg.start.y, seg.end.y) - 1e-9
            let hi = max(seg.start.y, seg.end.y) + 1e-9
            for k in 0...100 {
                let y = seg.point(at: CGFloat(k) / 100).y
                #expect(y >= lo && y <= hi)
            }
        }
    }

    @Test func curvePassesThroughEveryPoint() {
        let pts = [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 3), CGPoint(x: 2, y: 2), CGPoint(x: 4, y: 5)]
        let segs = monotoneCubicSegments(pts)
        #expect(segs.count == 3)
        #expect(segs.map(\.start) == Array(pts.dropLast()))
        #expect(segs.map(\.end) == Array(pts.dropFirst()))
    }

    @Test func spikeDoesNotOvershootPeakOrDipBelowZero() {
        // A lone spike between flat zeros: Catmull-Rom would ring below 0 and above 100.
        expectNoOvershoot([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 2, y: 100),
                           CGPoint(x: 3, y: 0), CGPoint(x: 4, y: 0)])
    }

    @Test func steepStepAndUnevenSpacingStayMonotone() {
        expectNoOvershoot([CGPoint(x: 0, y: 5), CGPoint(x: 0.1, y: 5), CGPoint(x: 3, y: 95),
                           CGPoint(x: 3.2, y: 96), CGPoint(x: 9, y: 2), CGPoint(x: 9.5, y: 60)])
    }

    @Test func randomSeriesNeverOvershoots() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            var x: CGFloat = 0
            let pts = (0..<30).map { _ -> CGPoint in
                x += CGFloat.random(in: 0.05...2, using: &rng)
                return CGPoint(x: x, y: CGFloat.random(in: 0...100, using: &rng))
            }
            expectNoOvershoot(pts)
        }
    }

    @Test func flatRunStaysFlat() {
        let segs = monotoneCubicSegments([CGPoint(x: 0, y: 7), CGPoint(x: 1, y: 7), CGPoint(x: 2, y: 7)])
        #expect(segs.allSatisfy { $0.control1.y == 7 && $0.control2.y == 7 })
    }

    @Test func duplicateTimestampsAreSkipped() {
        let segs = monotoneCubicSegments([CGPoint(x: 0, y: 1), CGPoint(x: 0, y: 9), CGPoint(x: 1, y: 2)])
        #expect(segs.count == 1)
        #expect(segs.allSatisfy { $0.control1.y.isFinite && $0.control2.y.isFinite })
    }

    @Test func tooFewPointsYieldNoSegments() {
        #expect(monotoneCubicSegments([]).isEmpty)
        #expect(monotoneCubicSegments([CGPoint(x: 1, y: 1)]).isEmpty)
    }

    @Test func niceUpperBoundSnapsToOneTwoFiveLadderWithHeadroom() {
        #expect(niceUpperBound(peak: 0) == 1)
        #expect(niceUpperBound(peak: 0.7) == 1)          // 0.875 → 1
        #expect(niceUpperBound(peak: 1) == 2)            // 1.25 → 2
        #expect(niceUpperBound(peak: 3) == 5)            // 3.75 → 5
        #expect(niceUpperBound(peak: 4) == 5)            // exactly 5
        #expect(niceUpperBound(peak: 4.1) == 10)
        #expect(niceUpperBound(peak: 1500) == 2000)
        #expect(niceUpperBound(peak: 700_000) == 1_000_000)
    }

    @Test func niceUpperBoundRespectsMinimumAndBadInput() {
        #expect(niceUpperBound(peak: 200, minimum: 10_000) == 10_000)
        #expect(niceUpperBound(peak: .nan) == 1)
        #expect(niceUpperBound(peak: -5) == 1)
    }

    @Test func niceUpperBoundIsStableForSmallWobbles() {
        let bounds = Set([2100.0, 2600, 3000, 3500, 3990].map { niceUpperBound(peak: $0) })
        #expect(bounds == [5000])
    }

    @Test func timeMapsToFixedAxisWithNewestAtRightEdge() {
        #expect(sparklineX(time: 100, end: 100, window: 60, width: 120) == 120)
        #expect(sparklineX(time: 40, end: 100, window: 60, width: 120) == 0)
        #expect(sparklineX(time: 70, end: 100, window: 60, width: 120) == 60)
        #expect(sparklineX(time: 10, end: 100, window: 60, width: 120) < 0)   // clipped off left
        // One second is always the same width, however many points there are.
        let oneSecond = sparklineX(time: 100, end: 100, window: 60, width: 120)
            - sparklineX(time: 99, end: 100, window: 60, width: 120)
        #expect(abs(oneSecond - 2) < 1e-9)
    }

    @Test func visibleSamplesKeepsWindowPlusOneLeadingPoint() {
        let pts = stride(from: 0.0, through: 100, by: 10).map { SamplePoint(time: $0, value: $0) }
        let slice = visibleSamples(pts, end: 100, window: 35)   // window starts at 65
        #expect(slice.map(\.time) == [60, 70, 80, 90, 100])
        #expect(visibleSamples(pts, end: 100, window: 500).count == pts.count)
        #expect(visibleSamples([], end: 0, window: 60).isEmpty)
    }
    @Test func stickyUpperBoundGrowsAtOnce() {
        #expect(stickyUpperBound(previous: nil, peak: 0.3) == 0.5)       // the minimum
        #expect(stickyUpperBound(previous: 1, peak: 1.2) == 2)           // overflow: grows now
        #expect(stickyUpperBound(previous: 2, peak: 7) == 10)
    }

    @Test func stickyUpperBoundShrinksOnlyBelowFortyPercent() {
        #expect(stickyUpperBound(previous: 2, peak: 0.9) == 2)           // 45 %: stays
        #expect(stickyUpperBound(previous: 2, peak: 1.95) == 2)          // would be 5 fresh: stays
        #expect(stickyUpperBound(previous: 2, peak: 0.7) == 1)           // 35 %: nice again
        #expect(stickyUpperBound(previous: 10, peak: 0.1) == 0.5)
    }

    @Test func stickyUpperBoundNeverGoesBelowTheMinimum() {
        #expect(stickyUpperBound(previous: 0.5, peak: 0) == 0.5)
        #expect(stickyUpperBound(previous: 0.2, peak: 0.01) == 0.5)
        #expect(stickyUpperBound(previous: 5, peak: 0, minimum: 1) == 1)
    }

    // MARK: Path

    /// Each element's kind and the point it ends at (nil for a close).
    private func elements(_ path: CGPath) -> [(type: CGPathElementType, end: CGPoint?)] {
        var out: [(type: CGPathElementType, end: CGPoint?)] = []
        path.applyWithBlock { e in
            let el = e.pointee
            switch el.type {
            case .moveToPoint, .addLineToPoint: out.append((el.type, el.points[0]))
            case .addQuadCurveToPoint: out.append((el.type, el.points[1]))
            case .addCurveToPoint: out.append((el.type, el.points[2]))
            case .closeSubpath: out.append((el.type, nil))
            @unknown default: out.append((el.type, nil))
            }
        }
        return out
    }

    private let pathRect = CGRect(x: 0, y: 0, width: 102.5, height: 38)   // plot width 100
    private let pathSamples = [SamplePoint(time: 30, value: 10), SamplePoint(time: 50, value: 80),
                               SamplePoint(time: 70, value: 0), SamplePoint(time: 100, value: 50)]

    @Test func pathPassesThroughEverySample() {
        let line = elements(sparklinePath(samples: pathSamples, end: 100, window: 60, upper: 100,
                                          in: pathRect, area: false))
        // y: 0 → 37 (1 pt above the bottom), 100 → 2 (2 pt below the top); newest sample at x = 100.
        let expected = pathSamples.map { s in
            CGPoint(x: 100 * (1 - (100 - s.time) / 60), y: 37 - s.value / 100 * 35)
        }
        #expect(line.map(\.type) == [.moveToPoint, .addCurveToPoint, .addCurveToPoint, .addCurveToPoint])
        for (got, want) in zip(line.compactMap(\.end), expected) {
            #expect(abs(got.x - want.x) < 1e-9 && abs(got.y - want.y) < 1e-9)
        }
    }

    @Test func areaPathClosesAtTheBottom() {
        let area = elements(sparklinePath(samples: pathSamples, end: 100, window: 60, upper: 100,
                                          in: pathRect, area: true))
        #expect(area.count == 7)
        #expect(area.suffix(3).map(\.type) == [.addLineToPoint, .addLineToPoint, .closeSubpath])
        #expect(area[4].end == CGPoint(x: 100, y: 38))                  // down from the newest sample
        #expect(area[5].end == CGPoint(x: area[0].end!.x, y: 38))       // back under the oldest
    }

    @Test func pathClampsValuesToTheChart() {
        let pts = [SamplePoint(time: 90, value: -5), SamplePoint(time: 100, value: 250)]
        let line = elements(sparklinePath(samples: pts, end: 100, window: 60, upper: 100, in: pathRect, area: false))
        #expect(line.first?.end?.y == 37)
        #expect(line.last?.end?.y == 2)
    }

    @Test func noSamplesGiveAnEmptyPath() {
        #expect(sparklinePath(samples: [], end: 0, window: 60, upper: 1, in: pathRect, area: false).isEmpty)
        #expect(sparklinePath(samples: [], end: 0, window: 60, upper: 1, in: pathRect, area: true).isEmpty)
    }

    // MARK: Slide

    @Test func slideStartsOneIntervalBehindAndReachesZero() {
        #expect(sparklineSlideLag(end: 100, now: 100, interval: 1) == 1)
        #expect(abs(sparklineSlideLag(end: 100, now: 100.25, interval: 1) - 0.75) < 1e-9)
        #expect(sparklineSlideLag(end: 100, now: 101, interval: 1) == 0)
        #expect(sparklineSlideLag(end: 100, now: 105, interval: 1) == 0)   // a late sample: held, not reversed
    }

    @Test func slideIsContinuousAcrossSamples() {
        // The time shown at the right edge (end - lag) is the same just before and as the next sample arrives.
        let before = 100 - sparklineSlideLag(end: 100, now: 101, interval: 1)
        let after = 101 - sparklineSlideLag(end: 101, now: 101, interval: 1)
        #expect(abs(before - after) < 1e-9)
        // Within one interval the shown time moves at the clock's pace.
        let a = 100 - sparklineSlideLag(end: 100, now: 100.2, interval: 1)
        let b = 100 - sparklineSlideLag(end: 100, now: 100.7, interval: 1)
        #expect(abs((b - a) - 0.5) < 1e-9)
    }

    @Test func slideNeverExceedsTwoIntervals() {
        #expect(sparklineSlideLag(end: 100, now: 90, interval: 1) == 2)   // clock skew
    }
}

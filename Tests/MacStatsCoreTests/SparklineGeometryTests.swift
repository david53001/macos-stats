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
}

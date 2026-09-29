import Testing
@testable import MacStatsCore

/// `trimHistory` keeps a sparkline's points to its time window: everything within `window`
/// of the newest point, plus exactly one older point so the line reaches the left edge.
@Suite struct HistoryTrimTests {
    private func points(_ times: [Double]) -> [SamplePoint] {
        times.map { SamplePoint(time: $0, value: $0) }
    }
    private func trimmed(_ times: [Double], window: Double = 60, maxCount: Int = 1000) -> [Double] {
        var p = points(times)
        trimHistory(&p, window: window, maxCount: maxCount)
        return p.map(\.time)
    }

    @Test func emptyStaysEmpty() {
        #expect(trimmed([]) == [])
    }

    @Test func allInsideWindowKeepsEverything() {
        #expect(trimmed([10, 20, 30]) == [10, 20, 30])
    }

    @Test func keepsExactlyOnePointOlderThanWindow() {
        // Newest 100 → cutoff 40. 50…100 are inside; 30 is the newest point older than that.
        #expect(trimmed([0, 10, 20, 30, 50, 100]) == [30, 50, 100])
    }

    @Test func pointExactlyAtCutoffIsTheKeptOlderPoint() {
        // 40 sits exactly on the left edge — it's the one older point; 30 goes.
        #expect(trimmed([30, 40, 50, 100]) == [40, 50, 100])
    }

    @Test func longGapStillKeepsPreviousPoint() {
        // After a long gap (e.g. sleep) the previous point is kept so the line spans the width.
        #expect(trimmed([0, 500]) == [0, 500])
    }

    @Test func countCapWinsOverWindow() {
        #expect(trimmed([1, 2, 3, 4, 5], maxCount: 2) == [4, 5])
    }
}

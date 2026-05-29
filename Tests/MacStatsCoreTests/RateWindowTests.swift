import Testing
@testable import MacStatsCore

/// `rateBaselineIndex` picks which past snapshot a rate (CPU %, network) should diff against:
/// the newest snapshot still at least `window` old, so the rate is averaged over ~`window`
/// seconds no matter how fast we sample. Decoupling the rate window from the sample interval
/// is what keeps the fast opening fill from inflating readings.
@Suite struct RateWindowTests {
    @Test func singleSnapshotIsItsOwnBaseline() {
        #expect(rateBaselineIndex(times: [0.0], now: 0.1, window: 1.0) == 0)
    }

    @Test func usesOldestWhileHistoryShorterThanWindow() {
        // Only 0.2s of history with a 1s window — diff against the oldest sample available.
        #expect(rateBaselineIndex(times: [0.0, 0.1, 0.2], now: 0.2, window: 1.0) == 0)
    }

    @Test func picksSnapshotAboutOneWindowOld() {
        // 0.5 is exactly 1.0s before now, so it's the baseline that spans the full window.
        #expect(rateBaselineIndex(times: [0.0, 0.5, 1.0, 1.5], now: 1.5, window: 1.0) == 1)
    }

    @Test func baselineSlidesForwardAsTimeAdvances() {
        // One sample later, the window edge moves to 1.0.
        #expect(rateBaselineIndex(times: [0.0, 0.5, 1.0, 1.5, 2.0], now: 2.0, window: 1.0) == 2)
    }

    @Test func includesSnapshotExactlyOneWindowOld() {
        #expect(rateBaselineIndex(times: [0.0, 1.0], now: 1.0, window: 1.0) == 0)
    }

    @Test func neverPicksCurrentSnapshotSoElapsedIsPositive() {
        // The most recent snapshot is never its own baseline (would give a zero window).
        let times = [0.0, 1.0, 2.0, 3.0]
        let i = rateBaselineIndex(times: times, now: 3.0, window: 1.0)
        #expect(i < times.count - 1)
    }
}

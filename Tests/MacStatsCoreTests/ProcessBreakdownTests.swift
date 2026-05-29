import Testing
@testable import MacStatsCore

@Suite struct ProcessBreakdownTests {
    // MARK: processCPUPercent
    @Test func oneCoreFullyBusyOverOneSecond() {
        // 1s of CPU time in 1s wall-clock == 100%
        let pct = processCPUPercent(previousCPUTimeNs: 0, currentCPUTimeNs: 1_000_000_000, elapsedSeconds: 1.0)
        #expect(abs(pct - 100) < 0.001)
    }

    @Test func multiCoreCanExceed100() {
        // 2s of CPU time in 1s wall-clock == 200% (two cores)
        let pct = processCPUPercent(previousCPUTimeNs: 0, currentCPUTimeNs: 2_000_000_000, elapsedSeconds: 1.0)
        #expect(abs(pct - 200) < 0.001)
    }

    @Test func zeroElapsedReturnsZero() {
        #expect(processCPUPercent(previousCPUTimeNs: 0, currentCPUTimeNs: 5, elapsedSeconds: 0) == 0)
    }

    @Test func counterResetReturnsZero() {
        // current < previous (pid reused / counter reset) → 0, never negative
        #expect(processCPUPercent(previousCPUTimeNs: 100, currentCPUTimeNs: 50, elapsedSeconds: 1.0) == 0)
    }
}

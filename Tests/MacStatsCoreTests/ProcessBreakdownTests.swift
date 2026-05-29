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

    // MARK: owningAppPID
    @Test func processThatIsItselfAnApp() {
        #expect(owningAppPID(for: 100, ppid: [100: 1], appPIDs: [100]) == 100)
    }

    @Test func helperAttributedToParentApp() {
        // 300 → parent 200 → parent 100 (an app)
        let ppid: [Int32: Int32] = [300: 200, 200: 100, 100: 1]
        #expect(owningAppPID(for: 300, ppid: ppid, appPIDs: [100]) == 100)
    }

    @Test func orphanProcessReturnsNil() {
        // chain reaches launchd (1), which is not an app
        let ppid: [Int32: Int32] = [500: 1]
        #expect(owningAppPID(for: 500, ppid: ppid, appPIDs: [100]) == nil)
    }

    @Test func brokenChainReturnsNil() {
        // parent pid not present in the map
        #expect(owningAppPID(for: 700, ppid: [700: 650], appPIDs: [100]) == nil)
    }

    @Test func cyclicChainReturnsNilNotHang() {
        let ppid: [Int32: Int32] = [10: 11, 11: 10]
        #expect(owningAppPID(for: 10, ppid: ppid, appPIDs: [999]) == nil)
    }
}

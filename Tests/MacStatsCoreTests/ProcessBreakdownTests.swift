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

    // MARK: aggregate
    @Test func groupsAndSumsByApp() {
        let procs = [
            ProcessUsage(pid: 1, appPID: 100, cpuPercent: 10, memoryBytes: 1_000),
            ProcessUsage(pid: 2, appPID: 100, cpuPercent: 5,  memoryBytes: 2_000),  // same app
            ProcessUsage(pid: 3, appPID: 200, cpuPercent: 30, memoryBytes: 500),
        ]
        let result = aggregate(procs, by: .cpu)
        #expect(result.count == 2)
        let chrome = result.first { $0.appPID == 100 }!
        #expect(abs(chrome.cpuPercent - 15) < 0.001)
        #expect(chrome.memoryBytes == 3_000)
        #expect(Set(chrome.pids) == [1, 2])
    }

    @Test func sortedDescendingByCPU() {
        let procs = [
            ProcessUsage(pid: 1, appPID: 100, cpuPercent: 10, memoryBytes: 9_000),
            ProcessUsage(pid: 2, appPID: 200, cpuPercent: 30, memoryBytes: 1_000),
        ]
        let result = aggregate(procs, by: .cpu)
        #expect(result.map(\.appPID) == [200, 100])    // 30% before 10%
    }

    @Test func sortedDescendingByMemory() {
        let procs = [
            ProcessUsage(pid: 1, appPID: 100, cpuPercent: 99, memoryBytes: 1_000),
            ProcessUsage(pid: 2, appPID: 200, cpuPercent: 1,  memoryBytes: 8_000),
        ]
        let result = aggregate(procs, by: .memory)
        #expect(result.map(\.appPID) == [200, 100])    // 8000 bytes before 1000
    }

    @Test func emptyInputYieldsEmpty() {
        #expect(aggregate([], by: .cpu).isEmpty)
    }

    @Test func tiesKeepStablePidOrder() {
        let procs = [30, 10, 20].map { ProcessUsage(pid: Int32($0), appPID: Int32($0), cpuPercent: 0, memoryBytes: 0) }
        #expect(aggregate(procs, by: .cpu).map(\.appPID) == [10, 20, 30])
    }
}

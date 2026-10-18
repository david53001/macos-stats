import Testing
@testable import MacStatsCore

@Suite @MainActor struct MetricsStoreTests {
    private let mem = MemorySample(usedBytes: 50, totalBytes: 100, pressure: .normal)
    private let net = NetworkSample(downBytesPerSec: 100, upBytesPerSec: 50)

    @Test func recordKeepsLatestAndAppendsHistory() {
        let store = MetricsStore()
        store.record(cpuPercent: 10, memory: mem, network: net, time: 0)
        store.record(cpuPercent: 20, memory: mem, network: net, time: 1)
        #expect(store.cpuPercent == 20)
        #expect(store.cpuHistory.map(\.value) == [10, 20])
        #expect(store.cpuHistory.map(\.time) == [0, 1])
        #expect(store.memHistory.map(\.value) == [0.5, 0.5])
        #expect(store.netDownHistory.map(\.value) == [100, 100])
        #expect(store.memory?.usedBytes == 50)
        #expect(store.network == net)
    }

    @Test func historyIsTrimmedByTime() {
        let store = MetricsStore(historyWindow: 60)
        for t in stride(from: 0.0, through: 100, by: 10) {   // 0, 10, …, 100
            store.record(cpuPercent: t, memory: mem, network: net, time: t)
        }
        // Newest is 100: keep 50…100 (inside the window) plus 40, the one point just older.
        #expect(store.cpuHistory.map(\.time) == [40, 50, 60, 70, 80, 90, 100])
        #expect(store.memHistory.count == 7)
        #expect(store.netDownHistory.count == 7)
    }

    @Test func historyHasHardCountCap() {
        let store = MetricsStore(historyWindow: 60, maxHistoryPoints: 3)
        for t in 0..<10 { store.record(cpuPercent: Double(t), memory: mem, network: net, time: Double(t)) }
        #expect(store.cpuHistory.map(\.value) == [7, 8, 9])
    }

    @Test func recordDoesNotClobberBatteryOrTemperature() {
        let store = MetricsStore()
        let bat = BatterySample(percent: 80, state: .discharging, timeToEmptyMinutes: 120)
        store.setBattery(bat)
        store.setCPUTemperature(47)
        store.record(cpuPercent: 5, memory: mem, network: net, time: 0)
        #expect(store.battery == bat)
        #expect(store.cpuTempCelsius == 47)
    }

    @Test func slowSettersDoNotTouchHistory() {
        let store = MetricsStore()
        store.record(cpuPercent: 5, memory: mem, network: net, time: 0)
        store.setBattery(nil)            // nil = no battery
        store.setCPUTemperature(nil)     // nil = no usable sensor
        #expect(store.battery == nil)
        #expect(store.cpuTempCelsius == nil)
        #expect(store.cpuPercent == 5)
        #expect(store.cpuHistory.count == 1)
    }

    @Test func breakdownLifecycle() {
        let store = MetricsStore()

        store.beginBreakdown(metric: .cpu)
        #expect(store.activeBreakdownMetric == .cpu)
        #expect(store.breakdownMeasuring == true)        // CPU needs two samples
        #expect(store.breakdown.isEmpty)

        let proc = ProcessUsage(pid: 1, appPID: 1, cpuPercent: 12, memoryBytes: 0)
        store.setBreakdown([AppUsage(appPID: 1, processes: [proc], cpuPercent: 12, memoryBytes: 0)],
                           measuring: false, totalCPU: 20)
        #expect(store.breakdown.count == 1)
        #expect(store.breakdownMeasuring == false)
        #expect(store.breakdownTotalCPU == 20)

        store.clearBreakdown()
        #expect(store.activeBreakdownMetric == nil)
        #expect(store.breakdown.isEmpty)
        #expect(store.breakdownMeasuring == false)
        #expect(store.breakdownTotalCPU == nil)
    }

    @Test func beginMemoryBreakdownIsNotMeasuring() {
        let store = MetricsStore()
        store.beginBreakdown(metric: .memory)
        #expect(store.breakdownMeasuring == false)       // memory is instantaneous
    }

    // MARK: Paused while the popover is closed

    @Test func pausedStoreRecordsWithoutPublishing() {
        let store = MetricsStore()
        store.record(cpuPercent: 10, memory: mem, network: net, time: 0)
        var changes = 0
        let watch = store.objectWillChange.sink { _ in changes += 1 }
        store.pausePublishing()
        store.record(cpuPercent: 20, memory: mem, network: net, time: 10)
        store.record(cpuPercent: 30, memory: mem, network: net, time: 20)
        store.setBattery(BatterySample(percent: 50, state: .discharging))
        store.setBatteryTelemetry(nil, powerWatts: nil, averageWatts: 3)
        store.setCPUTemperature(50)
        #expect(changes == 0)                             // nothing for SwiftUI to re-render
        #expect(store.cpuPercent == 10)
        #expect(store.cpuHistory.map(\.value) == [10])
        withExtendedLifetime(watch) {}
    }

    @Test func resumePublishesEverythingRecordedWhilePaused() {
        let store = MetricsStore()
        store.record(cpuPercent: 10, memory: mem, network: net, time: 0)
        store.setCPUTemperature(40)
        store.pausePublishing()
        store.record(cpuPercent: 20, memory: mem, network: net, time: 10)
        store.record(cpuPercent: 30, memory: mem, network: net, time: 20)
        let bat = BatterySample(percent: 50, state: .discharging, timeToEmptyMinutes: 300)
        store.setBattery(bat)
        store.setBatteryTelemetry(nil, powerWatts: nil, averageWatts: 3.5)
        store.resumePublishing()
        // The first open frame shows the latest values and the whole history.
        #expect(store.cpuPercent == 30)
        #expect(store.cpuHistory.map(\.value) == [10, 20, 30])
        #expect(store.memHistory.count == 3)
        #expect(store.netDownHistory.count == 3)
        #expect(store.battery == bat)
        #expect(store.batteryAverageWatts == 3.5)
        #expect(store.cpuTempCelsius == 40)              // not set while paused: unchanged
        // Live again.
        store.record(cpuPercent: 40, memory: mem, network: net, time: 30)
        #expect(store.cpuPercent == 40)
    }

    @Test func nilsRecordedWhilePausedArePublished() {
        // nil battery = "no battery", nil temperature = "no sensor": real values, not "unset".
        let store = MetricsStore()
        store.setBattery(BatterySample(percent: 50, state: .discharging))
        store.setCPUTemperature(40)
        store.pausePublishing()
        store.setBattery(nil)
        store.setCPUTemperature(nil)
        store.resumePublishing()
        #expect(store.battery == nil)
        #expect(store.cpuTempCelsius == nil)
    }

    @Test func pausedHistoryStaysBounded() {
        let store = MetricsStore(historyWindow: 60, maxHistoryPoints: 3)
        store.pausePublishing()
        for t in 0..<100 { store.record(cpuPercent: Double(t), memory: mem, network: net, time: Double(t)) }
        store.resumePublishing()
        #expect(store.cpuHistory.map(\.value) == [97, 98, 99])
    }
    // MARK: Held card values

    @Test func cardValuesHoldThenPassARealMove() {
        let store = MetricsStore()
        let gib: UInt64 = 1_073_741_824
        func memory(_ used: UInt64) -> MemorySample { MemorySample(usedBytes: used, totalBytes: 16 * gib, pressure: .normal) }
        func network(_ down: Double) -> NetworkSample { NetworkSample(downBytesPerSec: down, upBytesPerSec: 0) }
        store.record(cpuPercent: 8.49, memory: memory(10 * gib), network: network(5_000), time: 0)
        #expect(store.cardCPUPercent == 8)
        store.record(cpuPercent: 8.51, memory: memory(10 * gib + 60_000_000), network: network(6_200), time: 0.5)
        #expect(store.cardCPUPercent == 8)
        #expect(store.cardMemory?.usedBytes == 10 * gib)
        #expect(store.cardNetwork?.downBytesPerSec == 5_000)
        store.record(cpuPercent: 9.3, memory: memory(10 * gib + 200_000_000), network: network(9_000), time: 2)
        #expect(store.cardCPUPercent == 9)
        #expect(store.cardMemory?.usedBytes == 10 * gib + 200_000_000)
        #expect(store.cardNetwork?.downBytesPerSec == 9_000)
    }

    @Test func cardTextDwellsUnlessTheReadingJumps() {
        let store = MetricsStore()
        store.record(cpuPercent: 8, memory: mem, network: net, time: 0)
        store.record(cpuPercent: 9.4, memory: mem, network: net, time: 0.5)   // passes the hold, but too soon
        #expect(store.cardCPUPercent == 8)
        store.record(cpuPercent: 9.4, memory: mem, network: net, time: 2)
        #expect(store.cardCPUPercent == 9)
        store.record(cpuPercent: 30, memory: mem, network: net, time: 2.5)    // a jump never waits
        #expect(store.cardCPUPercent == 30)
        #expect(store.cpuPercent == 30)
    }

    @Test func rawValuesAndHistoryStayExact() {
        let store = MetricsStore()
        store.record(cpuPercent: 8.49, memory: mem, network: net, time: 0)
        store.record(cpuPercent: 8.51, memory: mem, network: net, time: 0.5)
        #expect(store.cardCPUPercent == 8)
        #expect(store.cpuPercent == 8.51)
        #expect(store.cpuHistory.map(\.value) == [8.49, 8.51])
    }

    @Test func cardHoldRestartsAfterPauseAndResume() {
        let store = MetricsStore()
        store.record(cpuPercent: 8.4, memory: mem, network: net, time: 0)
        store.record(cpuPercent: 8.6, memory: mem, network: net, time: 0.5)
        #expect(store.cardCPUPercent == 8)   // held
        store.pausePublishing()
        store.record(cpuPercent: 8.6, memory: mem, network: net, time: 10)
        store.resumePublishing()
        #expect(store.cardCPUPercent == 9)   // a fresh open shows the latest reading
    }

    @Test func temperatureHoldsWithinOneDegree() {
        let store = MetricsStore()
        var shown: [Double?] = []
        for t in [47.0, 47.8, 47.4, 48.1, 47.4, 46.9] {
            store.setCPUTemperature(t)
            shown.append(store.cpuTempCelsius)
            #expect(abs((store.cpuTempCelsius ?? 0) - t) < 1.0 + 1e-9)
        }
        #expect(shown == [47, 47, 47, 48, 48, 47])
        store.setCPUTemperature(nil)
        #expect(store.cpuTempCelsius == nil)
    }

    @Test func batteryTimesHoldAndResetOnAStateChange() {
        let store = MetricsStore()
        store.setBattery(BatterySample(percent: 60, state: .discharging, timeToEmptyMinutes: 97))
        store.setBattery(BatterySample(percent: 60, state: .discharging, timeToEmptyMinutes: 99))
        #expect(store.battery?.timeToEmptyMinutes == 97)
        store.setBattery(BatterySample(percent: 60, state: .charging, timeToFullMinutes: 30))
        store.setBattery(BatterySample(percent: 61, state: .charging, timeToFullMinutes: 31))
        #expect(store.battery?.timeToFullMinutes == 30)
        #expect(store.battery?.percent == 61)
        store.setBattery(BatterySample(percent: 61, state: .charging, timeToFullMinutes: 28))
        #expect(store.battery?.timeToFullMinutes == 28)
        store.setBattery(BatterySample(percent: 61, state: .discharging, timeToEmptyMinutes: 99))
        #expect(store.battery?.timeToEmptyMinutes == 99)
    }

    @Test func trashPermissionStateIsSeparateFromTheSize() {
        let store = MetricsStore()
        #expect(!store.trashNeedsPermission)
        store.setTrashBytes(nil)
        store.setTrashNeedsPermission(true)
        #expect(store.trashNeedsPermission)
        #expect(store.trashBytes == nil)
        // Allowed later: the next read has a size and clears the flag.
        store.setTrashBytes(0)
        store.setTrashNeedsPermission(false)
        #expect(!store.trashNeedsPermission)
        #expect(store.trashBytes == 0)
    }
}

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

        store.setBreakdown([AppUsage(appPID: 1, pids: [1], cpuPercent: 12, memoryBytes: 0)], measuring: false)
        #expect(store.breakdown.count == 1)
        #expect(store.breakdownMeasuring == false)

        store.clearBreakdown()
        #expect(store.activeBreakdownMetric == nil)
        #expect(store.breakdown.isEmpty)
        #expect(store.breakdownMeasuring == false)
    }

    @Test func beginMemoryBreakdownIsNotMeasuring() {
        let store = MetricsStore()
        store.beginBreakdown(metric: .memory)
        #expect(store.breakdownMeasuring == false)       // memory is instantaneous
    }
}

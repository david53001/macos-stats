import Testing
@testable import MacStatsCore

@Suite @MainActor struct MetricsStoreTests {
    @Test func keepsLatestAndBoundedHistory() {
        let store = MetricsStore(historyCapacity: 2)
        store.update(cpuPercent: 10, memory: nil, network: nil, battery: nil)
        store.update(cpuPercent: 20, memory: nil, network: nil, battery: nil)
        store.update(cpuPercent: 30, memory: nil, network: nil, battery: nil)
        #expect(store.cpuPercent == 30)
        #expect(store.cpuHistory == [20, 30]) // capacity 2
    }

    @Test func memoryHistoryTracksUsedFraction() {
        let store = MetricsStore(historyCapacity: 5)
        let mem = MemorySample(usedBytes: 50, totalBytes: 100, pressure: .normal)
        store.update(cpuPercent: 0, memory: mem, network: nil, battery: nil)
        #expect(store.memHistory == [0.5])
        #expect(store.memory?.usedBytes == 50)
    }

    @Test func resetClearsLatestAndHistory() {
        let store = MetricsStore(historyCapacity: 5)
        let mem = MemorySample(usedBytes: 50, totalBytes: 100, pressure: .normal)
        let net = NetworkSample(downBytesPerSec: 100, upBytesPerSec: 50)
        store.update(cpuPercent: 42, memory: mem, network: net, battery: nil)

        store.reset()

        #expect(store.cpuPercent == 0)
        #expect(store.memory == nil)
        #expect(store.network == nil)
        #expect(store.battery == nil)
        #expect(store.cpuHistory.isEmpty)
        #expect(store.memHistory.isEmpty)
        #expect(store.netDownHistory.isEmpty)

        // After reset, history rebuilds from empty.
        store.update(cpuPercent: 5, memory: nil, network: nil, battery: nil)
        #expect(store.cpuHistory == [5])
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

    @Test func resetClearsBreakdown() {
        let store = MetricsStore()
        store.beginBreakdown(metric: .cpu)
        store.reset()
        #expect(store.activeBreakdownMetric == nil)
        #expect(store.breakdown.isEmpty)
    }
}

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
}

import Testing
@testable import MacStatsCore

/// The breakdown's flattened rows (apps, the expanded app's processes, its "N more…").
@Suite struct BreakdownListTests {
    private func app(_ pid: Int32, processes: Int) -> AppUsage {
        AppUsage(appPID: pid, processes: (0..<processes).map {
            ProcessUsage(pid: pid * 100 + Int32($0), appPID: pid, cpuPercent: 1, memoryBytes: 0)
        }, cpuPercent: 1, memoryBytes: 0)
    }

    @Test func expandedAppShowsItsFirstProcessesAndAMoreRow() {
        let rows = BreakdownList.rows([app(1, processes: 8), app(2, processes: 3)], expanded: 1, visible: 5)
        #expect(rows.map(\.id) == ["a1", "p100", "p101", "p102", "p103", "p104", "m1", "a2"])
        #expect(rows.map(\.app) == [1, 1, 1, 1, 1, 1, 1, 2])
        guard case .more(let remaining, let enabled) = rows[6].kind else { Issue.record("no more row"); return }
        #expect(remaining == 3 && enabled)
    }

    @Test func anEndedAppKeepsItsMoreRowDisabled() {
        // Removing it while frozen moved every row below the block up under the pointer.
        let rows = BreakdownList.rows([app(1, processes: 8), app(2, processes: 1)], expanded: 1, visible: 5,
                                      ended: { $0 == 1 })
        #expect(rows.map(\.id) == ["a1", "p100", "p101", "p102", "p103", "p104", "m1", "a2"])
        guard case .more(_, let enabled) = rows[6].kind else { Issue.record("no more row"); return }
        #expect(!enabled)
    }
}

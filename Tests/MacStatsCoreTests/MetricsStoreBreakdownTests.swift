import Testing
@testable import MacStatsCore

/// The breakdown as shown: steady order, freeze, pin and held row values (`MetricsStore`).
@Suite @MainActor struct MetricsStoreBreakdownTests {
    private func app(_ pid: Int32, _ cpu: Double, children: [(Int32, Double)] = [],
                     watts: Double = 0, memory: UInt64 = 0) -> AppUsage {
        let procs = children.isEmpty
            ? [ProcessUsage(pid: pid, appPID: pid, cpuPercent: cpu, memoryBytes: memory, watts: watts)]
            : children.map { ProcessUsage(pid: $0.0, appPID: pid, cpuPercent: $0.1, memoryBytes: 0) }
        return AppUsage(appPID: pid, processes: procs, cpuPercent: cpu, memoryBytes: memory, watts: watts)
    }

    /// Rows as the scanner returns them: sorted by value.
    private func scan(_ apps: [AppUsage]) -> [AppUsage] {
        apps.sorted { $0.cpuPercent != $1.cpuPercent ? $0.cpuPercent > $1.cpuPercent : $0.appPID < $1.appPID }
    }

    private func cpuStore() -> MetricsStore {
        let store = MetricsStore()
        store.beginBreakdown(metric: .cpu)
        return store
    }

    private func order(_ store: MetricsStore) -> [Int32] { store.breakdown.map(\.appPID) }

    @Test func stableOrderIsApplied() {
        let store = cpuStore()
        store.setBreakdown(scan([app(1, 5), app(2, 4)]), measuring: false, time: 0)
        #expect(order(store) == [1, 2])
        // 2 edges ahead by noise: the scanner sorts it first, the store keeps the order.
        store.setBreakdown(scan([app(1, 5), app(2, 5.5)]), measuring: false, time: 2)
        #expect(order(store) == [1, 2])
        #expect(store.breakdown.first { $0.appPID == 2 }?.cpuPercent == 5.5)   // values stay exact
    }

    @Test func firstRealScanAfterMeasuringIsAPlainSort() {
        let store = cpuStore()
        store.setBreakdown([app(1, 0), app(2, 0)], measuring: true, time: 0)
        #expect(store.breakdownMeasuring)
        store.setBreakdown(scan([app(1, 1), app(2, 5)]), measuring: false, time: 0.5)
        #expect(order(store) == [2, 1])
    }

    @Test func aSmallInversionLastsOneScan() {
        // 2 edges past 1 by less than the margins: it shows above for one scan, then passes it.
        let store = cpuStore()
        store.setBreakdown(scan([app(1, 3.0), app(2, 2.6)]), measuring: false, time: 0)
        store.setBreakdown(scan([app(1, 3.0), app(2, 3.3)]), measuring: false, time: 2)
        #expect(order(store) == [1, 2])
        store.setBreakdown(scan([app(1, 3.0), app(2, 3.3)]), measuring: false, time: 4)
        #expect(order(store) == [2, 1])
        // A one-scan blip doesn't: 1 leads again before the timeout.
        store.setBreakdown(scan([app(1, 3.4), app(2, 3.3)]), measuring: false, time: 6)
        store.setBreakdown(scan([app(1, 3.0), app(2, 3.3)]), measuring: false, time: 8)
        #expect(order(store) == [2, 1])
    }

    @Test func aMenuOpenedWithoutMovingCountsAsPointing() {
        // Right-click on the row under a pointer that never moved: after the menu closes the list
        // stays frozen while the pointer is still there.
        let store = cpuStore()
        store.setBreakdown(scan([app(1, 5), app(2, 4)]), measuring: false, time: 0)
        store.breakdownPointerProbe = { BreakdownPointer(inside: true, moved: false) }
        store.setBreakdownMenuOpen(true, time: 1)
        store.setBreakdownMenuOpen(false, time: 2)
        store.setBreakdown(scan([app(1, 1), app(2, 40)]), measuring: false, time: 4)
        #expect(order(store) == [1, 2])
    }

    @Test func aFrozenAppGainsNoRows() {
        // New processes (and a first "Finished processes" row) would push the rows below an
        // expanded app down under the pointer: they wait for the unfreeze.
        let store = cpuStore()
        store.setBreakdown([app(1, 6, children: [(10, 3), (11, 2)]), app(2, 1)], measuring: false, time: 0)
        store.setBreakdownPointerInside(true, time: 1)
        let grown = [app(1, 9, children: [(10, 3), (11, 2), (12, 2.5), (BreakdownGroup.exitedProcesses, 1)]),
                     app(2, 1)]
        store.setBreakdown(grown, measuring: false, time: 2)
        #expect(store.breakdown[0].pids == [10, 11])
        #expect(order(store) == [1, 2])
        store.setBreakdownPointerInside(false, time: 3)
        store.setBreakdown(grown, measuring: false, time: 4)
        #expect(Set(store.breakdown[0].pids) == [10, 11, 12, BreakdownGroup.exitedProcesses])
    }

    @Test func theHeaderStartsFromTheCardValue() {
        let store = MetricsStore()
        let memory = MemorySample(usedBytes: 1, totalBytes: 2, pressure: .normal)
        store.record(cpuPercent: 27, memory: memory, network: NetworkSample(downBytesPerSec: 0, upBytesPerSec: 0),
                     time: 0)
        store.beginBreakdown(metric: .cpu)
        store.setBreakdown([app(1, 5)], measuring: false, totalCPU: 26.5, time: 2)
        #expect(store.breakdownShownTotalCPU == 27)
        store.setBreakdown([app(1, 5)], measuring: false, totalCPU: 23, time: 4)
        #expect(store.breakdownShownTotalCPU == 23)
    }

    @Test func freezeHoldsOrderButUpdatesValuesAppendsAndRemoves() {
        let store = cpuStore()
        store.setBreakdown(scan([app(1, 5), app(2, 4), app(3, 3)]), measuring: false, time: 0)
        store.setBreakdownPointerInside(true, time: 1)
        // 1 quit, 3 spiked (would jump to the top), 4 is new.
        store.setBreakdown(scan([app(2, 1), app(3, 50), app(4, 7)]), measuring: false, time: 2)
        // 1 stays in place, ended, so nothing below it moves up under the pointer.
        #expect(order(store) == [1, 2, 3, 4])
        #expect(store.isEnded(app: 1))
        #expect(!store.isEnded(app: 2))
        #expect(store.breakdown.first { $0.appPID == 3 }?.cpuPercent == 50)
        #expect(store.shownValue(app: 3) == 50)
        // At the unfreeze the ended row goes.
        store.setBreakdownPointerInside(false, time: 3)
        store.setBreakdown(scan([app(2, 1), app(3, 50), app(4, 7)]), measuring: false, time: 4.5)
        #expect(!order(store).contains(1))
        #expect(!store.isEnded(app: 1))
    }

    @Test func anEndedAppKeepsItsProcessesWhileFrozen() {
        // The expanded app quit with the pointer on the list: its rows stay (dimmed), so nothing
        // under the pointer collapses or moves up.
        let store = cpuStore()
        store.setBreakdown(scan([app(1, 6, children: [(10, 3), (11, 2), (12, 1)]), app(2, 1)]),
                           measuring: false, time: 0)
        store.setBreakdownPointerInside(true, time: 1)
        store.setBreakdown([app(2, 1)], measuring: false, time: 2)
        #expect(order(store) == [1, 2])
        #expect(store.isEnded(app: 1))
        #expect(store.breakdown[0].pids == [10, 11, 12])
        #expect(store.isEnded(app: 1, pid: 11))
        store.setBreakdownPointerInside(false, time: 3)
        store.setBreakdown([app(2, 1)], measuring: false, time: 4.5)
        #expect(order(store) == [2])
    }

    @Test func endedProcessesKeepTheirPlaceWhileFrozen() {
        let store = cpuStore()
        store.setBreakdown([app(1, 6, children: [(10, 3), (11, 2), (12, 1)])], measuring: false, time: 0)
        store.setBreakdownPointerInside(true, time: 1)
        store.setBreakdown([app(1, 6, children: [(10, 3), (12, 1)])], measuring: false, time: 2)
        #expect(store.breakdown[0].pids == [10, 11, 12])
        #expect(store.isEnded(app: 1, pid: 11))
        #expect(!store.isEnded(app: 1, pid: 12))
        store.setBreakdownPointerInside(false, time: 3)
        store.setBreakdown([app(1, 6, children: [(10, 3), (12, 1)])], measuring: false, time: 4.5)
        #expect(store.breakdown[0].pids == [10, 12])
    }

    @Test func exitedRowStaysOnceItAppeared() {
        let store = cpuStore()
        let exited = BreakdownGroup.exitedProcesses
        store.setBreakdown([app(1, 6, children: [(10, 3), (exited, 2)])], measuring: false, time: 0)
        store.setBreakdown([app(1, 3, children: [(10, 3)])], measuring: false, time: 2)
        #expect(store.breakdown[0].pids == [10, exited])
        #expect(store.breakdown[0].processes.last?.cpuPercent == 0)
        #expect(!store.isEnded(app: 1, pid: exited))
    }

    @Test func memoryHasNoExitedRow() {
        let store = MetricsStore()
        store.beginBreakdown(metric: .memory)
        let procs = [ProcessUsage(pid: 10, appPID: 1, cpuPercent: 0, memoryBytes: 500),
                     ProcessUsage(pid: BreakdownGroup.exitedProcesses, appPID: 1, cpuPercent: 2, memoryBytes: 0)]
        store.setBreakdown([AppUsage(appPID: 1, processes: procs, cpuPercent: 2, memoryBytes: 500)],
                           measuring: false, time: 0)
        #expect(store.breakdown[0].pids == [10])
    }

    @Test func pointerProbeFreezesWithoutAHoverEvent() {
        // A menu closed over a pointer that had moved onto the list: no hover event came.
        let store = cpuStore()
        store.setBreakdown(scan([app(1, 5), app(2, 4)]), measuring: false, time: 0)
        var inside = true
        store.breakdownPointerProbe = { BreakdownPointer(inside: inside, moved: true) }
        let spiked = scan([app(1, 1), app(2, 40)])
        store.setBreakdown(spiked, measuring: false, time: 2)
        #expect(order(store) == [1, 2])
        inside = false
        store.setBreakdown(spiked, measuring: false, time: 4)
        #expect(order(store) == [2, 1])
        store.clearBreakdown()
        #expect(store.breakdownPointerProbe == nil)
    }

    @Test func aPointerStillRestingFromTheClickDoesNotFreeze() {
        // The list appears where the clicked card was. Until the pointer moves it isn't pointing at
        // a row, so the list keeps ranking, even if a hover event said "inside".
        let store = cpuStore()
        store.setBreakdown(scan([app(1, 5), app(2, 4)]), measuring: false, time: 0)
        store.setBreakdownPointerInside(true, time: 0.1)
        var moved = false
        store.breakdownPointerProbe = { BreakdownPointer(inside: true, moved: moved) }
        let spiked = scan([app(1, 1), app(2, 40)])
        store.setBreakdown(spiked, measuring: false, time: 2)
        #expect(order(store) == [2, 1])
        moved = true
        store.setBreakdown(scan([app(1, 50), app(2, 40)]), measuring: false, time: 4)
        #expect(order(store) == [2, 1])
    }

    @Test func unfreezeHappensAtTheFirstScanASecondAfterThePointerLeaves() {
        let store = cpuStore()
        store.setBreakdown(scan([app(1, 5), app(2, 4)]), measuring: false, time: 0)
        store.setBreakdownPointerInside(true, time: 1)
        store.setBreakdownPointerInside(false, time: 5)
        let spiked = scan([app(1, 1), app(2, 40)])
        store.setBreakdown(spiked, measuring: false, time: 5.9)
        #expect(order(store) == [1, 2])
        store.setBreakdown(spiked, measuring: false, time: 6.0)
        #expect(order(store) == [2, 1])
    }

    @Test func menuFreezeWorksTheSameWay() {
        let store = cpuStore()
        store.setBreakdown(scan([app(1, 5), app(2, 4)]), measuring: false, time: 0)
        store.setBreakdownMenuOpen(true, time: 1)
        let spiked = scan([app(1, 1), app(2, 40)])
        store.setBreakdown(spiked, measuring: false, time: 3)
        #expect(order(store) == [1, 2])
        // The pointer leaving while the menu is still open doesn't unfreeze.
        store.setBreakdownPointerInside(true, time: 3.5)
        store.setBreakdownPointerInside(false, time: 4)
        store.setBreakdown(spiked, measuring: false, time: 6)
        #expect(order(store) == [1, 2])
        store.setBreakdownMenuOpen(false, time: 7)
        store.setBreakdown(spiked, measuring: false, time: 7.5)
        #expect(order(store) == [1, 2])
        store.setBreakdown(spiked, measuring: false, time: 8)
        #expect(order(store) == [2, 1])
    }

    @Test func childrenReorderWithHysteresisAndFreeze() {
        let store = cpuStore()
        store.setBreakdown([app(1, 6, children: [(10, 3), (11, 2.8)])], measuring: false, time: 0)
        #expect(store.breakdown[0].pids == [10, 11])
        store.setBreakdown([app(1, 6.1, children: [(11, 3.1), (10, 3)])], measuring: false, time: 2)
        #expect(store.breakdown[0].pids == [10, 11])
        store.setBreakdownPointerInside(true, time: 3)
        store.setBreakdown([app(1, 33, children: [(11, 30), (10, 3)])], measuring: false, time: 4)
        #expect(store.breakdown[0].pids == [10, 11])
        store.setBreakdownPointerInside(false, time: 5)
        store.setBreakdown([app(1, 33, children: [(11, 30), (10, 3)])], measuring: false, time: 6)
        #expect(store.breakdown[0].pids == [11, 10])
    }

    @Test func revisionBumpsOnlyOnARealReorder() {
        let store = cpuStore()
        store.setBreakdown(scan([app(1, 5), app(2, 4)]), measuring: false, time: 0)
        let start = store.breakdownOrderRevision
        store.setBreakdown(scan([app(1, 5.1), app(2, 4.2)]), measuring: false, time: 2)
        store.setBreakdown(scan([app(1, 5), app(2, 5.5)]), measuring: false, time: 4)
        #expect(store.breakdownOrderRevision == start)
        store.setBreakdown(scan([app(1, 1), app(2, 40)]), measuring: false, time: 6)
        #expect(store.breakdownOrderRevision == start + 1)
    }

    @Test func heldTextValuesStayWithinTheirBound() {
        let store = cpuStore()
        var shown: [Double] = []
        for (i, v) in [5.04, 5.06, 5.3, 4.8, 5.6, 5.6, 12.4, 12.9, 13.6, 13.6].enumerated() {
            store.setBreakdown([app(1, v)], measuring: false, time: Double(i * 2))
            let s = store.shownValue(app: 1) ?? -1
            #expect(abs(s - v) <= max(1.5 * breakdownValueStep(.cpu, v), 0.20 * s) + 1e-9)
            shown.append(s)
        }
        // 5.0 holds through the wobble; 5.6 shows once a second scan confirms it; 12.4 is a big
        // move (shows at once); 12.9 holds (10 % band); 13.6 shows on its second scan.
        #expect(shown.map { breakdownValueText(.cpu, $0) } == ["5.0%", "5.0%", "5.0%", "5.0%", "5.0%", "5.6%",
                                                                "12%", "12%", "12%", "14%"])
        // Process rows are held too.
        #expect(store.shownValue(app: 1, pid: 1) == shown.last)
        #expect(store.shownValue(app: 1, pid: 99) == nil)
    }

    @Test func headerIsHeldLikeTheCard() {
        let store = cpuStore()
        store.setBreakdown([app(1, 5)], measuring: false, totalCPU: 20.4, time: 0)
        #expect(store.breakdownShownTotalCPU == 20)
        store.setBreakdown([app(1, 5)], measuring: false, totalCPU: 20.6, time: 2)
        #expect(store.breakdownShownTotalCPU == 20)
        #expect(store.breakdownTotalCPU == 20.6)   // the exact value stays available
        store.setBreakdown([app(1, 5)], measuring: false, totalCPU: 21, time: 4)
        #expect(store.breakdownShownTotalCPU == 21)
    }

    @Test func energyScaleIsSticky() {
        let store = MetricsStore()
        store.beginBreakdown(metric: .energy)
        var scales: [Double] = []
        for w in [0.9, 0.85, 0.5, 1.5] {
            store.setBreakdown([app(1, 0, watts: w)], measuring: false, time: Double(scales.count * 2))
            scales.append(store.breakdownBarScale)
        }
        #expect(scales == [2, 2, 1, 2])
    }

    @Test func cpuBarsFollowTheTopRow() {
        // At light load a 100 % scale left every bar a dot; the scale is a sticky step above the top row.
        let store = cpuStore()
        var scales: [Double] = []
        for top in [3.5, 3.0, 6.0, 30.0] {
            store.setBreakdown([app(1, top), app(2, 0.5)], measuring: false, time: Double(scales.count * 2))
            scales.append(store.breakdownBarScale)
        }
        #expect(scales == [5, 5, 10, 50])
    }

    @Test func everythingResetsOnBeginAndClear() {
        let store = cpuStore()
        store.setBreakdown(scan([app(1, 5), app(2, 4)]), measuring: false, totalCPU: 30, time: 0)
        store.setBreakdownPointerInside(true, time: 1)
        store.clearBreakdown()
        #expect(store.shownValue(app: 1) == nil)
        #expect(store.breakdownShownTotalCPU == nil)
        store.beginBreakdown(metric: .cpu)
        // Not frozen any more: a plain sort.
        store.setBreakdown(scan([app(1, 1), app(2, 40)]), measuring: false, time: 2)
        #expect(order(store) == [2, 1])
        store.setBreakdown(scan([app(1, 1), app(2, 40), app(3, 90)]), measuring: false, time: 4)
        #expect(order(store) == [3, 2, 1])
    }

    @Test func memoryGroupRowsStayLast() {
        let store = MetricsStore()
        store.beginBreakdown(metric: .memory)
        let mb: UInt64 = 1_048_576
        let rows = [app(7, 0, memory: 300 * mb), app(BreakdownGroup.otherProcesses, 0, memory: 4_000 * mb),
                    app(8, 0, memory: 100 * mb)]
        store.setBreakdown(rows, measuring: false, time: 0)
        #expect(order(store) == [7, 8, BreakdownGroup.otherProcesses])
    }
}

import Testing
@testable import MacStatsCore

@Suite struct ProcessAttributionTests {
    private let none: (Int32) -> Int32? = { _ in nil }

    /// The audit's regression case: every Terminal tab is app ← root `login` ← zsh ← child,
    /// and `login` isn't in the user-process list. The full parent map bridges the gap.
    @Test func childUnderRootLoginMapsToApp() {
        let full: [Int32: Int32] = [400: 300, 300: 200, 200: 100, 100: 1]
        #expect(owningAppPID(for: 400, parent: { full[$0] }, responsible: none, appPIDs: [100]) == 100)
    }

    @Test func responsiblePidOverridesParentChain() {
        // An XPC helper launched by launchd on an app's behalf: its parent chain ends at launchd.
        let parents: [Int32: Int32] = [500: 1]
        #expect(owningAppPID(for: 500, parent: { parents[$0] },
                             responsible: { $0 == 500 ? 100 : nil }, appPIDs: [100]) == 100)
    }

    @Test func responsibleAppWinsOverAHelperRegisteredAsAnApp() {
        // e.g. "Google Chrome Helper" shows up in runningApplications but Chrome is responsible.
        let parents: [Int32: Int32] = [600: 100, 100: 1]
        #expect(owningAppPID(for: 600, parent: { parents[$0] },
                             responsible: { $0 == 600 ? 100 : nil }, appPIDs: [100, 600]) == 100)
    }

    @Test func appResponsibleForItselfIsItsOwnRow() {
        #expect(owningAppPID(for: 100, parent: { _ in 1 }, responsible: { $0 }, appPIDs: [100]) == 100)
    }

    @Test func nonAppResponsibleFallsBackToParentChain() {
        // Responsible pid is a daemon (not an app) or unreadable (nil): walk the parents.
        let parents: [Int32: Int32] = [700: 650, 650: 100, 100: 1]
        #expect(owningAppPID(for: 700, parent: { parents[$0] },
                             responsible: { $0 == 700 ? 42 : nil }, appPIDs: [100]) == 100)
    }

    @Test func daemonWithNoAppIsUnattributed() {
        #expect(owningAppPID(for: 800, parent: { _ in 1 }, responsible: { $0 }, appPIDs: [100]) == nil)
    }

    @Test func cycleTerminates() {
        let parents: [Int32: Int32] = [10: 11, 11: 10]
        #expect(owningAppPID(for: 10, parent: { parents[$0] }, responsible: none, appPIDs: [99]) == nil)
    }

    // MARK: ProcessAttributor

    private func raw(_ pid: Int32, _ ppid: Int32, start: UInt64 = 1) -> RawProcess {
        RawProcess(pid: pid, ppid: ppid, cpuTimeNs: 0, memoryBytes: 0, startTime: start)
    }

    @Test func attributorFetchesFullParentMapOnlyWhenTheChainLeavesTheUserList() {
        var fetches = 0
        let attributor = ProcessAttributor(responsible: { _ in nil }, allParents: {
            fetches += 1
            return [200: 100]   // root `login` 200, child of Terminal 100
        })
        let procs = [raw(100, 1), raw(300, 200), raw(400, 300), raw(900, 1)]
        let owners = attributor.owners(for: procs, appPIDs: [100])
        #expect(owners[400] == 100)
        #expect(owners[300] == 100)
        #expect(owners[100] == 100)
        #expect(owners[900] == BreakdownGroup.otherProcesses)   // launchd-parented daemon
        #expect(fetches == 1)
    }

    @Test func attributorCachesPerProcessAndInvalidatesOnChange() {
        var calls = 0
        let attributor = ProcessAttributor(responsible: { pid in calls += 1; return pid == 300 ? 100 : nil },
                                           allParents: { [:] })
        let procs = [raw(100, 1), raw(300, 1)]
        _ = attributor.owners(for: procs, appPIDs: [100])
        let afterFirst = calls
        #expect(attributor.owners(for: procs, appPIDs: [100])[300] == 100)
        #expect(calls == afterFirst)                         // cached
        // Same pid, new process (pid reused): looked up again.
        _ = attributor.owners(for: [raw(100, 1), raw(300, 1, start: 2)], appPIDs: [100])
        #expect(calls > afterFirst)
        // The app quit: nothing may still point at it.
        let owners = attributor.owners(for: [raw(300, 1, start: 2)], appPIDs: [])
        #expect(owners[300] == BreakdownGroup.otherProcesses)
    }
}

@Suite struct ProcessSamplerTests {
    private func p(_ pid: Int32, ppid: Int32 = 1, cpu: UInt64, child: UInt64 = 0, energy: UInt64 = 0,
                   start: UInt64 = 10) -> RawProcess {
        RawProcess(pid: pid, ppid: ppid, cpuTimeNs: cpu, memoryBytes: 0, energyNj: energy,
                   childCPUTimeNs: child, startTime: start)
    }

    @Test func firstScanIsOnlyABaseline() {
        let s = ProcessSampler()
        #expect(s.ingest([p(1, cpu: 5)], time: 0, absTime: 100) == nil)
    }

    @Test func survivingProcessReportsItsDelta() {
        let s = ProcessSampler()
        _ = s.ingest([p(1, cpu: 1_000, energy: 50)], time: 0, absTime: 100)
        let d = s.ingest([p(1, cpu: 3_000, energy: 80)], time: 2, absTime: 200)
        #expect(d?[1] == ProcessDelta(cpuNs: 2_000, energyNj: 30))
        #expect(s.elapsedSeconds == 2)
    }

    @Test func processStartedSinceLastScanCountsFromZero() {
        // Energy used to read 0 W for a new process's first interval; CPU and energy both
        // count from zero when the process started after the previous scan.
        let s = ProcessSampler()
        _ = s.ingest([], time: 0, absTime: 100)
        let d = s.ingest([p(2, cpu: 700, energy: 40, start: 150)], time: 1, absTime: 200)
        #expect(d?[2] == ProcessDelta(cpuNs: 700, energyNj: 40))
    }

    @Test func processMissedByLastScanGetsNoBaselineInsteadOfItsLifetime() {
        // Old process (started before the last scan) that the last scan didn't see: dumping its
        // whole lifetime CPU into one interval would read thousands of percent.
        let s = ProcessSampler()
        _ = s.ingest([], time: 0, absTime: 100)
        let d = s.ingest([p(3, cpu: 9_999_999, energy: 5_000, start: 50)], time: 1, absTime: 200)
        #expect(d?[3] == ProcessDelta(cpuNs: 0, energyNj: 0))
    }

    @Test func reusedPidIsANewProcess() {
        let s = ProcessSampler()
        _ = s.ingest([p(4, cpu: 5_000, start: 10)], time: 0, absTime: 100)
        let d = s.ingest([p(4, cpu: 300, start: 150)], time: 1, absTime: 200)
        #expect(d?[4]?.cpuNs == 300)
    }

    @Test func exitedChildTimeIsCreditedToTheParent() {
        // Parent 10 has child 11 (seen last scan with 400 ns). 11 exits having used 1_000 ns,
        // and a short-lived child that no scan ever saw used 250 ns: the parent's child time
        // grows by 1_250, of which 400 was already counted for 11 itself.
        let s = ProcessSampler()
        _ = s.ingest([p(10, cpu: 0), p(11, ppid: 10, cpu: 400)], time: 0, absTime: 100)
        let d = s.ingest([p(10, cpu: 0, child: 1_250)], time: 1, absTime: 200)
        #expect(d?[10]?.cpuNs == 850)   // 600 unseen of 11 + 250 of the short-lived one
    }

    @Test func exitedGrandchildrenAreNotCountedTwice() {
        // 10 ← 11 ← 12. Both 11 and 12 exit; 10 reaps 11, whose child time includes 12.
        let s = ProcessSampler()
        _ = s.ingest([p(10, cpu: 0), p(11, ppid: 10, cpu: 100), p(12, ppid: 11, cpu: 200)],
                     time: 0, absTime: 100)
        let d = s.ingest([p(10, cpu: 0, child: 1_000)], time: 1, absTime: 200)
        #expect(d?[10]?.cpuNs == 700)   // 1_000 − (100 + 200) already counted
    }

    @Test func notYetReapedChildCarriesItsDebtToTheNextScan() {
        // 11 vanished from the list but the parent hasn't reaped it yet (child time unchanged):
        // the 400 ns already counted must be subtracted when the reap shows up next scan.
        let s = ProcessSampler()
        _ = s.ingest([p(10, cpu: 0), p(11, ppid: 10, cpu: 400)], time: 0, absTime: 100)
        let first = s.ingest([p(10, cpu: 0)], time: 1, absTime: 200)
        #expect(first?[10]?.cpuNs == 0)
        let second = s.ingest([p(10, cpu: 0, child: 500)], time: 2, absTime: 300)
        #expect(second?[10]?.cpuNs == 100)
    }

    @Test func newProcessIncludesChildrenItAlreadyReaped() {
        let s = ProcessSampler()
        _ = s.ingest([], time: 0, absTime: 100)
        let d = s.ingest([p(20, cpu: 100, child: 300, start: 150)], time: 1, absTime: 200)
        #expect(d?[20]?.cpuNs == 400)
    }
}

@Suite struct BreakdownScannerTests {
    private let ticks0 = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)

    private func p(_ pid: Int32, ppid: Int32 = 1, cpu: UInt64, mem: UInt64 = 0) -> RawProcess {
        RawProcess(pid: pid, ppid: ppid, cpuTimeNs: cpu, memoryBytes: mem, startTime: 1)
    }

    private func scanner() -> BreakdownScanner {
        BreakdownScanner(cores: 4, responsible: { _ in nil }, allParents: { [:] })
    }

    @Test func cpuRowsAreAShareOfTheWholeMachineAndAddUpToTheHeader() {
        let s = scanner()
        let first = s.scan([p(100, cpu: 0), p(101, ppid: 100, cpu: 0), p(900, cpu: 0)], appPIDs: [100],
                           metric: .cpu, time: 0, absTime: 10, cpuTicks: ticks0)
        #expect(first.measuring)
        #expect(first.totalCPUPercent == nil)
        // 1 s later: app 100 used one full core (100 % in Activity Monitor terms) = 25 % of a
        // 4-core machine; daemon 900 used half a core = 12.5 %. Host: 50 % busy.
        let r = s.scan([p(100, cpu: 400_000_000), p(101, ppid: 100, cpu: 600_000_000),
                        p(900, cpu: 500_000_000)], appPIDs: [100],
                       metric: .cpu, time: 1, absTime: 20,
                       cpuTicks: CPUTicks(user: 50, system: 0, idle: 50, nice: 0))
        #expect(!r.measuring)
        #expect(r.totalCPUPercent == 50)
        let app = r.apps.first { $0.appPID == 100 }
        #expect(abs((app?.cpuPercent ?? 0) - 25) < 0.001)
        #expect(app?.processes.map(\.pid) == [101, 100])   // ranked inside the app
        let other = r.apps.first { $0.appPID == BreakdownGroup.otherProcesses }
        #expect(abs((other?.cpuPercent ?? 0) - 12.5) < 0.001)
        let system = r.apps.first { $0.appPID == BreakdownGroup.system }
        #expect(abs((system?.cpuPercent ?? 0) - 12.5) < 0.001)
        #expect(abs(r.apps.reduce(0) { $0 + $1.cpuPercent } - 50) < 0.001)
    }

    @Test func memoryIsImmediateAndHasNoSystemRow() {
        let r = scanner().scan([p(100, cpu: 0, mem: 1_000), p(900, cpu: 0, mem: 500)], appPIDs: [100],
                               metric: .memory, time: 0, absTime: 10, cpuTicks: ticks0)
        #expect(!r.measuring)
        #expect(r.apps.map(\.appPID) == [100, BreakdownGroup.otherProcesses])
        #expect(r.apps.map(\.memoryBytes) == [1_000, 500])
    }
}

@Suite struct BreakdownRowsTests {
    @Test func systemRowIsTheUnattributedRemainderNeverNegative() {
        let apps = [AppUsage(appPID: 1, processes: [], cpuPercent: 30, memoryBytes: 0)]
        #expect(addingSystemRow(to: apps, totalCPUPercent: 40).map(\.appPID) == [1, BreakdownGroup.system])
        #expect(addingSystemRow(to: apps, totalCPUPercent: 40).last?.cpuPercent == 10)
        #expect(addingSystemRow(to: apps, totalCPUPercent: 20).last?.cpuPercent == 0)
    }

    @Test func groupRowsSortAfterAppsOnTies() {
        let procs = [
            ProcessUsage(pid: 5, appPID: BreakdownGroup.otherProcesses, cpuPercent: 0, memoryBytes: 0),
            ProcessUsage(pid: 7, appPID: 7, cpuPercent: 0, memoryBytes: 0),
        ]
        #expect(aggregate(procs, by: .cpu).map(\.appPID) == [7, BreakdownGroup.otherProcesses])
    }

    @Test func versionLikeNamesAreDetected() {
        #expect(isVersionLikeProcessName("2.1.289"))
        #expect(isVersionLikeProcessName("18"))
        #expect(!isVersionLikeProcessName("node"))
        #expect(!isVersionLikeProcessName("Code Helper (Renderer)"))
        #expect(!isVersionLikeProcessName(""))
    }
}

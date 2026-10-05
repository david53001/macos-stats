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

    /// Claude.app (100) ← disclaimer (110) ← `npm exec @modelcontextprotocol/…` (120, a
    /// background-only "running app" with no bundle id, responsible for itself) ← node (130).
    /// Live, before the fix, 120 was its own 178 MB row named "npm exec @modelcontextprot…".
    @Test func disclaimedHelperRegisteredAsAnAppGoesToItsParentApp() {
        let parents: [Int32: Int32] = [130: 120, 120: 110, 110: 100, 100: 1]
        let responsible: (Int32) -> Int32? = { pid in
            switch pid {
            case 120, 130: return 120   // disclaimed: responsible for itself (and its children)
            default: return 100
            }
        }
        for pid: Int32 in [120, 130] {
            #expect(owningAppPID(for: pid, parent: { parents[$0] }, responsible: responsible,
                                 appPIDs: [100], fallbackAppPIDs: [120]) == 100)
        }
    }

    @Test func fallbackAppKeepsItsOwnRowWhenNoRealAppIsAbove() {
        // e.g. universalaccessd or a widget extension: launchd's child, listed as a running app.
        #expect(owningAppPID(for: 900, parent: { _ in 1 }, responsible: { $0 }, appPIDs: [100],
                             fallbackAppPIDs: [900]) == 900)
        // …and a child of it goes there too.
        let parents: [Int32: Int32] = [901: 900, 900: 1]
        #expect(owningAppPID(for: 901, parent: { parents[$0] }, responsible: { _ in nil }, appPIDs: [100],
                             fallbackAppPIDs: [900]) == 900)
    }

    @Test func realAppsAndTerminalStillWinWithFallbacksPresent() {
        // A Terminal tab's chain through root `login`, and a VS Code terminal's MCP server whose
        // responsible app is Code: unchanged by the fallback set.
        let full: [Int32: Int32] = [400: 300, 300: 200, 200: 100, 100: 1]
        #expect(owningAppPID(for: 400, parent: { full[$0] }, responsible: none, appPIDs: [100],
                             fallbackAppPIDs: [300]) == 100)
        #expect(owningAppPID(for: 500, parent: { _ in 1 }, responsible: { _ in 100 }, appPIDs: [100],
                             fallbackAppPIDs: [500]) == 100)
        #expect(owningAppPID(for: 100, parent: { _ in 1 }, responsible: { $0 }, appPIDs: [100],
                             fallbackAppPIDs: [500]) == 100)
    }

    @Test func anchorsSplitRealAppsFromBackgroundProcesses() {
        let anchors = attributionAnchors([
            RunningAppInfo(pid: 100, hasBundleIdentifier: true, isBackgroundOnly: false),   // Claude
            RunningAppInfo(pid: 110, hasBundleIdentifier: true, isBackgroundOnly: false),   // a menu-bar app
            RunningAppInfo(pid: 120, hasBundleIdentifier: false, isBackgroundOnly: true),   // npm exec …
            RunningAppInfo(pid: 130, hasBundleIdentifier: true, isBackgroundOnly: true),    // widget extension
            RunningAppInfo(pid: 140, hasBundleIdentifier: false, isBackgroundOnly: false),  // bare helper
            RunningAppInfo(pid: -1, hasBundleIdentifier: true, isBackgroundOnly: false),
        ])
        #expect(anchors.apps == [100, 110])
        #expect(anchors.fallbacks == [120, 130, 140])
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

    @Test func attributorRelooksUpWhenFallbacksChange() {
        let attributor = ProcessAttributor(responsible: { _ in nil }, allParents: { [:] })
        let procs = [raw(100, 1), raw(120, 100), raw(130, 120)]
        #expect(attributor.owners(for: procs, appPIDs: [100])[130] == 100)
        // The same processes, but 120 is now a background "app": still under the real app 100.
        #expect(attributor.owners(for: procs, appPIDs: [100], fallbackAppPIDs: [120])[130] == 100)
        // The real app quit: the fallback takes over.
        #expect(attributor.owners(for: [raw(120, 1), raw(130, 120)], appPIDs: [],
                                  fallbackAppPIDs: [120])[130] == 120)
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

    @Test func childCreditIsMarkedAsSuch() {
        let s = ProcessSampler()
        _ = s.ingest([p(10, cpu: 0)], time: 0, absTime: 100)
        let d = s.ingest([p(10, cpu: 300, child: 500)], time: 1, absTime: 200)
        #expect(d?[10] == ProcessDelta(cpuNs: 800, energyNj: 0, childCreditNs: 500))
    }

    @Test func debtThatIsNeverPaidExpires() {
        // 10 ← 11 ← 12. 11 exits and 12, handed to launchd, exits too: launchd reaps 12, so
        // 10's child time never includes 12's 400 ns. That debt must not swallow 10's later
        // real credit for good.
        let s = ProcessSampler()
        _ = s.ingest([p(10, cpu: 0), p(11, ppid: 10, cpu: 100), p(12, ppid: 11, cpu: 400)],
                     time: 0, absTime: 100)
        _ = s.ingest([p(10, cpu: 0, child: 100)], time: 1, absTime: 200)   // reaped 11 only
        _ = s.ingest([p(10, cpu: 0, child: 100)], time: 2, absTime: 300)
        _ = s.ingest([p(10, cpu: 0, child: 100)], time: 3, absTime: 400)
        let d = s.ingest([p(10, cpu: 0, child: 350)], time: 4, absTime: 500)   // a real 250 ns
        #expect(d?[10]?.cpuNs == 250)
    }

    @Test func newProcessIncludesChildrenItAlreadyReaped() {
        let s = ProcessSampler()
        _ = s.ingest([], time: 0, absTime: 100)
        let d = s.ingest([p(20, cpu: 100, child: 300, start: 150)], time: 1, absTime: 200)
        #expect(d?[20]?.cpuNs == 400)
    }

    // MARK: Energy of reaped children (estimated: rusage has no child-energy field)

    @Test func reapedChildEnergyUsesTheIntervalsEnergyPerCPUTime() {
        // 11 ran 1 ms for 3 mJ (3 nJ per ns). Parent 10 reaped 0.5 ms of short-lived children.
        let s = ProcessSampler()
        _ = s.ingest([p(10, cpu: 0), p(11, cpu: 0)], time: 0, absTime: 100)
        let d = s.ingest([p(10, cpu: 0, child: 500_000), p(11, cpu: 1_000_000, energy: 3_000_000)],
                         time: 1, absTime: 200)
        #expect(d?[10] == ProcessDelta(cpuNs: 500_000, energyNj: 1_500_000, childCreditNs: 500_000,
                                       childCreditEnergyNj: 1_500_000))
        #expect(d?[11]?.energyNj == 3_000_000)   // a process's own energy is untouched
    }

    @Test func processesStartedThisIntervalSetTheRatioWhenTheyRanEnough() {
        // A build: the next compiler (12, new, 4 nJ/ns on a performance core) says more about
        // the reaped compilers than an idle agent on an efficiency core (11, 1 nJ/ns).
        let s = ProcessSampler()
        _ = s.ingest([p(10, cpu: 0), p(11, cpu: 0)], time: 0, absTime: 100)
        let d = s.ingest([p(10, cpu: 0, child: 10_000_000), p(11, cpu: 100_000_000, energy: 100_000_000),
                          p(12, ppid: 10, cpu: 50_000_000, energy: 200_000_000, start: 150)],
                         time: 1, absTime: 200)
        #expect(d?[10]?.energyNj == 40_000_000)
    }

    @Test func newProcessReapedChildrenGetEnergyToo() {
        let s = ProcessSampler()
        _ = s.ingest([p(11, cpu: 0)], time: 0, absTime: 100)
        let d = s.ingest([p(11, cpu: 1_000, energy: 2_000), p(20, cpu: 0, child: 300, start: 150)],
                         time: 1, absTime: 200)
        #expect(d?[20]?.energyNj == 600)
        #expect(d?[20]?.childCreditEnergyNj == 0)   // not part of the capped credit, like its CPU
    }

    // MARK: Work by exited processes that no reap explains

    /// 10 ← 11, 11 busy at one core; 11 exits between the 3rd and 4th scan.
    private func busyChild(reapedBy10: Bool) -> ProcessSampler {
        let s = ProcessSampler()
        _ = s.ingest([p(10, cpu: 0), p(11, ppid: 10, cpu: 0)], time: 0, absTime: 100)
        _ = s.ingest([p(10, cpu: 0), p(11, ppid: 10, cpu: 1_000_000_000)], time: 1, absTime: 200)
        _ = s.ingest([p(10, cpu: 0), p(11, ppid: 10, cpu: 2_000_000_000)], time: 2, absTime: 300)
        _ = s.ingest([p(10, cpu: 0, child: reapedBy10 ? 3_000_000_000 : 0)], time: 3, absTime: 400)
        return s
    }

    @Test func exitWithoutAReapIsReportedAtTheLastRate() {
        #expect(busyChild(reapedBy10: false).unexplainedExitNs == [10: 1_000_000_000])
    }

    @Test func reapedExitIsNotReportedAgain() {
        #expect(busyChild(reapedBy10: true).unexplainedExitNs.isEmpty)
    }

    @Test func exitOfAProcessWithoutAncestorIsAnOrphan() {
        let s = ProcessSampler()
        _ = s.ingest([p(11, cpu: 0)], time: 0, absTime: 100)
        _ = s.ingest([p(11, cpu: 500_000_000)], time: 1, absTime: 200)
        _ = s.ingest([], time: 3, absTime: 300)   // a 2 s interval: twice the last rate
        #expect(s.orphanExitNs == [11: 1_000_000_000])
        #expect(s.unexplainedExitNs.isEmpty)
    }

    @Test func creditedExitWorkIsNotCountedAgainWhenTheReapComesLate() {
        let s = busyChild(reapedBy10: false)
        s.addDebt(1_000_000_000, to: 10)   // what BreakdownScanner credited for it
        // Next scan: 10 finally reaps 11 (3 s of CPU in all: 2 s seen live + 1 s credited).
        let d = s.ingest([p(10, cpu: 0, child: 3_000_000_000)], time: 4, absTime: 500)
        #expect(d?[10]?.cpuNs == 0)
    }
}

@Suite struct ExitWorkCreditTests {
    @Test func creditIsCappedByTheBudgetInProportion() {
        let c = exitWorkCredit(unexplained: [10: 3_000, 20: 1_000], orphans: [:], previousOwners: [:],
                               alive: { _ in true }, budgetNs: 2_000)
        #expect(c == [10: 1_500, 20: 500])
    }

    @Test func fullCreditWhenTheBudgetCoversIt() {
        let c = exitWorkCredit(unexplained: [10: 1_000], orphans: [:], previousOwners: [:],
                               alive: { _ in true }, budgetNs: 5_000)
        #expect(c == [10: 1_000])
    }

    @Test func noCreditWithoutBudget() {
        #expect(exitWorkCredit(unexplained: [10: 1_000], orphans: [:], previousOwners: [:],
                               alive: { _ in true }, budgetNs: 0).isEmpty)
        #expect(exitWorkCredit(unexplained: [10: 1_000], orphans: [:], previousOwners: [:],
                               alive: { _ in true }, budgetNs: -5).isEmpty)
    }

    @Test func orphansGoToTheirAppsMainProcessIfStillRunning() {
        let c = exitWorkCredit(unexplained: [:], orphans: [11: 1_000, 12: 500, 13: 700],
                               previousOwners: [11: 100, 12: 200, 13: BreakdownGroup.otherProcesses],
                               alive: { $0 == 100 }, budgetNs: 10_000)
        #expect(c == [100: 1_000])
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

    @Test func ticksThatDidNotMoveGiveNoHeaderInsteadOfZero() {
        // A stale counter read (the kernel's rate limit) once showed a 0 % header over 25 % of rows.
        let s = scanner()
        let ticks = CPUTicks(user: 10, system: 0, idle: 90, nice: 0)
        _ = s.scan([p(100, cpu: 0)], appPIDs: [100], metric: .cpu, time: 0, absTime: 10, cpuTicks: ticks)
        let r = s.scan([p(100, cpu: 1_000_000_000)], appPIDs: [100], metric: .cpu, time: 1, absTime: 20,
                       cpuTicks: ticks)
        #expect(!r.measuring)
        #expect(r.totalCPUPercent == nil)
        #expect(!r.apps.contains { $0.appPID == BreakdownGroup.system })
        #expect(abs((r.apps.first { $0.appPID == 100 }?.cpuPercent ?? 0) - 25) < 0.001)
    }

    @Test func childCreditNeverPushesTheRowsPastTheHeader() {
        // A Terminal tab's root `login` (unreadable, never scanned) ran `yes` for minutes; when
        // the tab's surviving parent reaps it, its child time jumps by all of that, which
        // earlier scans already counted. Live this read 510 % of one core under an 11 % header.
        let s = scanner()
        _ = s.scan([p(100, cpu: 0), p(101, ppid: 100, cpu: 0)], appPIDs: [100],
                   metric: .cpu, time: 0, absTime: 10, cpuTicks: ticks0)
        let r = s.scan([p(100, cpu: 100_000_000),
                        RawProcess(pid: 101, ppid: 100, cpuTimeNs: 0, memoryBytes: 0,
                                   childCPUTimeNs: 300_000_000_000, startTime: 1)],
                       appPIDs: [100], metric: .cpu, time: 1, absTime: 20,
                       cpuTicks: CPUTicks(user: 20, system: 0, idle: 80, nice: 0))
        #expect(r.totalCPUPercent == 20)
        let app = r.apps.first { $0.appPID == 100 }!
        // Own time: 0.1 s of a 4-core second = 2.5 %; the credit gets the other 17.5 % at most.
        #expect(abs(app.cpuPercent - 20) < 0.001)
        #expect(r.apps.reduce(0) { $0 + $1.cpuPercent } <= 20.001)
    }

    @Test func childCreditThatFitsTheBudgetIsKept() {
        // A build's short-lived compilers: 1.5 cores of reaped work in a 50 %-busy second.
        let s = scanner()
        _ = s.scan([p(100, cpu: 0), p(101, ppid: 100, cpu: 0)], appPIDs: [100],
                   metric: .cpu, time: 0, absTime: 10, cpuTicks: ticks0)
        let r = s.scan([p(100, cpu: 0),
                        RawProcess(pid: 101, ppid: 100, cpuTimeNs: 0, memoryBytes: 0,
                                   childCPUTimeNs: 1_500_000_000, startTime: 1)],
                       appPIDs: [100], metric: .cpu, time: 1, absTime: 20,
                       cpuTicks: CPUTicks(user: 50, system: 0, idle: 50, nice: 0))
        let app = r.apps.first { $0.appPID == 100 }!
        #expect(abs(app.cpuPercent - 37.5) < 0.001)
    }

    @Test func memoryIsImmediateAndHasNoSystemRow() {
        let r = scanner().scan([p(100, cpu: 0, mem: 1_000), p(900, cpu: 0, mem: 500)], appPIDs: [100],
                               metric: .memory, time: 0, absTime: 10, cpuTicks: ticks0)
        #expect(!r.measuring)
        #expect(r.apps.map(\.appPID) == [100, BreakdownGroup.otherProcesses])
        #expect(r.apps.map(\.memoryBytes) == [1_000, 500])
    }

    @Test func memoryRemainderRowWhenTheTotalIsGiven() {
        let r = scanner().scan([p(100, cpu: 0, mem: 1_000), p(900, cpu: 0, mem: 500)], appPIDs: [100],
                               metric: .memory, time: 0, absTime: 10, cpuTicks: ticks0, memoryInUseBytes: 4_000)
        #expect(r.apps.map(\.appPID) == [100, BreakdownGroup.system, BreakdownGroup.otherProcesses])
        #expect(r.apps.map(\.memoryBytes) == [1_000, 2_500, 500])
    }

    /// App 100 ← shell 101 ← `yes` 102 at one core of 4. Between the 2nd and 3rd scan, 102 is
    /// killed and reaped by launchd (its subshell exited): its last stretch can't be read.
    private func orphanRun(busyAtTheEnd: UInt32) -> BreakdownScanner.Result {
        let s = scanner()
        _ = s.scan([p(100, cpu: 0), p(101, ppid: 100, cpu: 0), p(102, ppid: 101, cpu: 0)], appPIDs: [100],
                   metric: .cpu, time: 0, absTime: 10, cpuTicks: ticks0)
        // 26 % busy: 102's core (25 %) + 1 % the kernel.
        _ = s.scan([p(100, cpu: 0), p(101, ppid: 100, cpu: 0), p(102, ppid: 101, cpu: 1_000_000_000)],
                   appPIDs: [100], metric: .cpu, time: 1, absTime: 20,
                   cpuTicks: CPUTicks(user: 26, system: 0, idle: 74, nice: 0))
        return s.scan([p(100, cpu: 0), p(101, ppid: 100, cpu: 0)], appPIDs: [100], metric: .cpu,
                      time: 2, absTime: 30,
                      cpuTicks: CPUTicks(user: 26 + busyAtTheEnd, system: 0, idle: 74 + 100 - busyAtTheEnd, nice: 0))
    }

    @Test func exitedWorkNoReapExplainsGoesBackToItsAppNotSystem() {
        // Live before the fix: 380 % of one core of the user's `yes` showed as System.
        let r = orphanRun(busyAtTheEnd: 26)
        let app = r.apps.first { $0.appPID == 100 }!
        let system = r.apps.first { $0.appPID == BreakdownGroup.system }!
        #expect(abs(app.cpuPercent - 25) < 0.01)
        // Its own child row, not on the (idle) shell that started it.
        #expect(app.processes.first?.pid == BreakdownGroup.exitedProcesses)
        #expect(abs((app.processes.first?.cpuPercent ?? 0) - 25) < 0.01)
        #expect((app.processes.first { $0.pid == 101 }?.cpuPercent ?? 1) < 0.01)
        #expect(abs(system.cpuPercent - 1) < 0.01)
    }

    @Test func orphanWorkShowsAsExitedProcessesNotOnTheAppsMainProcess() {
        // An orphaned `yes` (ppid 1) the app is responsible for, killed between scans. Credited
        // to the app's main process, an idle VS Code read 79 % of one core.
        let s = BreakdownScanner(cores: 4, responsible: { $0 == 102 ? 100 : nil }, allParents: { [:] })
        _ = s.scan([p(100, cpu: 0), p(102, cpu: 0)], appPIDs: [100], metric: .cpu, time: 0, absTime: 10,
                   cpuTicks: ticks0)
        _ = s.scan([p(100, cpu: 0), p(102, cpu: 1_000_000_000)], appPIDs: [100], metric: .cpu, time: 1,
                   absTime: 20, cpuTicks: CPUTicks(user: 26, system: 0, idle: 74, nice: 0))
        let r = s.scan([p(100, cpu: 0)], appPIDs: [100], metric: .cpu, time: 2, absTime: 30,
                       cpuTicks: CPUTicks(user: 52, system: 0, idle: 148, nice: 0))
        let app = r.apps.first { $0.appPID == 100 }!
        #expect(abs(app.cpuPercent - 25) < 0.01)
        #expect(app.processes.map(\.pid) == [BreakdownGroup.exitedProcesses, 100])
        #expect(app.processes[1].cpuPercent == 0)
    }

    @Test func exitedWorkIsOnlyCreditedOutOfARisenRemainder() {
        // 102 was killed right after the last scan: the machine stayed at 1 % (System's level).
        let r = orphanRun(busyAtTheEnd: 1)
        #expect((r.apps.first { $0.appPID == 100 }?.cpuPercent ?? 1) < 0.01)
        #expect(abs((r.apps.first { $0.appPID == BreakdownGroup.system }?.cpuPercent ?? 0) - 1) < 0.01)
    }

    @Test func exitedWorkIsCappedAtWhatTheMachineDidUnseen() {
        // Killed about halfway: only what the machine did beyond System's usual 1 % is
        // credited (13 %), not 102's last rate (25 %).
        let r = orphanRun(busyAtTheEnd: 14)
        let app = r.apps.first { $0.appPID == 100 }!
        #expect(abs(app.cpuPercent - 13) < 0.01)
        #expect(abs(r.apps.reduce(0) { $0 + $1.cpuPercent } - 14) < 0.01)
    }

    @Test func reapedChildPowerIsCappedWithItsCPU() {
        // The reap of a long-dead root `login` subtree (see childCreditNeverPushesTheRowsPastTheHeader)
        // mustn't read as watts either.
        let s = scanner()
        _ = s.scan([p(100, cpu: 0), p(101, ppid: 100, cpu: 0)], appPIDs: [100],
                   metric: .energy, time: 0, absTime: 10, cpuTicks: ticks0)
        let r = s.scan([RawProcess(pid: 100, ppid: 1, cpuTimeNs: 100_000_000, memoryBytes: 0,
                                   energyNj: 100_000_000, startTime: 1),
                        RawProcess(pid: 101, ppid: 100, cpuTimeNs: 0, memoryBytes: 0,
                                   childCPUTimeNs: 300_000_000_000, startTime: 1)],
                       appPIDs: [100], metric: .energy, time: 1, absTime: 20,
                       cpuTicks: CPUTicks(user: 20, system: 0, idle: 80, nice: 0))
        // 1 nJ per ns: own 0.1 W; the credit is capped to 0.7 s of CPU, so 0.7 W, not 300 W.
        let app = r.apps.first { $0.appPID == 100 }!
        #expect(abs(app.watts - 0.8) < 0.001)
    }
}

@Suite struct BreakdownRowsTests {
    @Test func systemRowIsTheUnattributedRemainderNeverNegative() {
        let apps = [AppUsage(appPID: 1, processes: [], cpuPercent: 30, memoryBytes: 0)]
        #expect(addingSystemRow(to: apps, totalCPUPercent: 40).map(\.appPID) == [1, BreakdownGroup.system])
        #expect(addingSystemRow(to: apps, totalCPUPercent: 40).last?.cpuPercent == 10)
        #expect(addingSystemRow(to: apps, totalCPUPercent: 20).last?.cpuPercent == 0)
    }

    @Test func aggregateSumsEveryProcessOfAGroup() {
        let procs = (1...300).map {
            ProcessUsage(pid: Int32($0), appPID: $0 % 3 == 0 ? 7 : BreakdownGroup.otherProcesses,
                         cpuPercent: 0.1, memoryBytes: 10)
        }
        let rows = aggregate(procs, by: .cpu)
        #expect(rows.map(\.appPID) == [BreakdownGroup.otherProcesses, 7])
        #expect(rows.map(\.processes.count) == [200, 100])
        #expect(rows.map(\.memoryBytes) == [2_000, 1_000])
        #expect(abs(rows[1].cpuPercent - 10) < 1e-9)
    }

    @Test func memoryGroupRowsGoLastWhateverTheirSize() {
        // "Other processes" (GBs of macOS agents) and "System & other" used to top the list.
        let procs = [
            ProcessUsage(pid: 5, appPID: BreakdownGroup.otherProcesses, cpuPercent: 0, memoryBytes: 2_000),
            ProcessUsage(pid: 7, appPID: 7, cpuPercent: 0, memoryBytes: 100),
            ProcessUsage(pid: 8, appPID: 8, cpuPercent: 0, memoryBytes: 300),
        ]
        let rows = addingMemoryRemainderRow(to: aggregate(procs, by: .memory), inUseBytes: 10_000)
        #expect(rows.map(\.appPID) == [8, 7, BreakdownGroup.system, BreakdownGroup.otherProcesses])
        #expect(rows[2].memoryBytes == 7_600)
        #expect(rows[2].processes.isEmpty)   // not expandable, no actions
    }

    @Test func memoryRemainderNeverNegative() {
        let apps = [AppUsage(appPID: 1, processes: [], cpuPercent: 0, memoryBytes: 500)]
        #expect(addingMemoryRemainderRow(to: apps, inUseBytes: 400).last?.memoryBytes == 0)
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

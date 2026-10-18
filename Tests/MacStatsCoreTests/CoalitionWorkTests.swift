import Foundation
import Testing
@testable import MacStatsCore

@Suite struct CoalitionTrackerTests {
    private func usage(_ ns: UInt64, _ nj: UInt64 = 0) -> CoalitionUsage {
        CoalitionUsage(cpuTimeNs: ns, energyNj: nj)
    }

    @Test func firstReadingIsOnlyABaseline() {
        var t = CoalitionTracker()
        #expect(t.residuals(readings: [7: usage(1_000)], liveNs: [:], liveNj: [:], elapsed: 0).isEmpty)
    }

    @Test func residualIsWhatTheLiveMembersDidNotDo() {
        var t = CoalitionTracker()
        _ = t.residuals(readings: [7: usage(0, 0)], liveNs: [:], liveNj: [:], elapsed: 0)
        // 1 s: the coalition grew 1.5 core-seconds; its live processes did 0.5 of them.
        let r = t.residuals(readings: [7: usage(1_500_000_000, 3_000_000_000)],
                            liveNs: [7: 500_000_000], liveNj: [7: 1_000_000_000], elapsed: 1)
        #expect(r[7] == CoalitionResidual(ns: 1_000_000_000, nj: 2_000_000_000))
    }

    @Test func readingSkewIsNotAnExit() {
        var t = CoalitionTracker()
        _ = t.residuals(readings: [7: usage(0)], liveNs: [:], liveNj: [:], elapsed: 0)
        // The coalition is read a few ms after its processes: 1 % more is noise.
        let r = t.residuals(readings: [7: usage(1_010_000_000)], liveNs: [7: 1_000_000_000], liveNj: [:],
                            elapsed: 1)
        #expect(r[7]?.ns == 0)
    }

    @Test func aNewCoalitionWaitsForItsBaseline() {
        var t = CoalitionTracker()
        _ = t.residuals(readings: [7: usage(0)], liveNs: [:], liveNj: [:], elapsed: 0)
        let r = t.residuals(readings: [7: usage(0), 8: usage(5_000_000_000)], liveNs: [:], liveNj: [:], elapsed: 1)
        #expect(r[8] == nil)
        #expect(r[7] != nil)
    }

    @Test func contradictoryReadingsSwitchCoalitionsOff() {
        // A changed struct layout: the "cpu" word is something else and reads less than the
        // members' own time. Never trusted; after three strikes, never read again.
        var t = CoalitionTracker()
        _ = t.residuals(readings: [7: usage(0)], liveNs: [:], liveNj: [:], elapsed: 0)
        for i in 1...3 {
            let r = t.residuals(readings: [7: usage(UInt64(i) * 1_000)], liveNs: [7: 900_000_000], liveNj: [:],
                                elapsed: 1)
            #expect(r.isEmpty)
        }
        #expect(!t.isEnabled)
        #expect(t.residuals(readings: [7: usage(10_000_000_000)], liveNs: [:], liveNj: [:], elapsed: 1).isEmpty)
    }

    @Test func countersGoingBackwardsAreAStrike() {
        var t = CoalitionTracker()
        _ = t.residuals(readings: [7: usage(5_000)], liveNs: [:], liveNj: [:], elapsed: 0)
        #expect(t.residuals(readings: [7: usage(1_000)], liveNs: [:], liveNj: [:], elapsed: 1).isEmpty)
        #expect(t.strikes == 1)
    }
}

@Suite struct CoalitionScannerTests {
    private let ticks0 = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)

    private func p(_ pid: Int32, ppid: Int32 = 1, cpu: UInt64, child: UInt64 = 0, energy: UInt64 = 0,
                   coalition: UInt64 = 7) -> RawProcess {
        RawProcess(pid: pid, ppid: ppid, cpuTimeNs: cpu, memoryBytes: 0, energyNj: energy, childCPUTimeNs: child,
                   startTime: 1, coalitionID: coalition)
    }

    private func scanner(_ readings: @escaping () -> [UInt64: CoalitionUsage]) -> BreakdownScanner {
        BreakdownScanner(cores: 4, windowSeconds: 0, responsible: { _ in nil }, allParents: { [:] },
                         coalitionUsage: { readings()[$0] })
    }

    @Test func exitedHelpersAreTheCoalitionsExactRemainder() {
        // App 100 + helper 101 in coalition 7. Over 1 s a short-lived helper did 0.6 core-s
        // and exited unseen; the app did 0.4 core-s. 4 cores, 25 % busy = 1 core-s.
        var now: [UInt64: CoalitionUsage] = [7: CoalitionUsage(cpuTimeNs: 0, energyNj: 0)]
        let s = scanner { now }
        _ = s.scan([p(100, cpu: 0), p(101, ppid: 100, cpu: 0)], appPIDs: [100], metric: .cpu,
                   time: 0, absTime: 10, cpuTicks: ticks0)
        now = [7: CoalitionUsage(cpuTimeNs: 1_000_000_000, energyNj: 0)]
        let r = s.scan([p(100, cpu: 400_000_000), p(101, ppid: 100, cpu: 0)], appPIDs: [100], metric: .cpu,
                       time: 1, absTime: 20, cpuTicks: CPUTicks(user: 25, system: 0, idle: 75, nice: 0))
        let app = r.apps.first { $0.appPID == 100 }!
        #expect(abs(app.cpuPercent - 25) < 0.001)
        let finished = app.processes.first { $0.pid == BreakdownGroup.exitedProcesses }
        #expect(abs((finished?.cpuPercent ?? 0) - 15) < 0.001)   // 0.6 core-s of 4 = 15 %
        #expect(abs((app.processes.first { $0.pid == 100 }?.cpuPercent ?? 0) - 10) < 0.001)
    }

    @Test func reapedChildTimeIsNotCountedTwice() {
        // 101 reaped a 0.5 core-s compiler: rusage credits it to 101 as child time, and the
        // coalition counts it too. Covered, only the coalition's figure counts.
        var now: [UInt64: CoalitionUsage] = [7: CoalitionUsage(cpuTimeNs: 0, energyNj: 0)]
        let s = scanner { now }
        _ = s.scan([p(100, cpu: 0), p(101, ppid: 100, cpu: 0)], appPIDs: [100], metric: .cpu,
                   time: 0, absTime: 10, cpuTicks: ticks0)
        now = [7: CoalitionUsage(cpuTimeNs: 500_000_000, energyNj: 0)]
        let r = s.scan([p(100, cpu: 0), p(101, ppid: 100, cpu: 0, child: 500_000_000)], appPIDs: [100],
                       metric: .cpu, time: 1, absTime: 20,
                       cpuTicks: CPUTicks(user: 50, system: 0, idle: 50, nice: 0))
        let app = r.apps.first { $0.appPID == 100 }!
        #expect(abs(app.cpuPercent - 12.5) < 0.001)   // 0.5 core-s, once
        #expect((app.processes.first { $0.pid == 101 }?.cpuPercent ?? 1) < 0.001)
    }

    @Test func exitedHelpersEnergyIsMeasuredNotEstimated() {
        var now: [UInt64: CoalitionUsage] = [7: CoalitionUsage(cpuTimeNs: 0, energyNj: 0)]
        let s = scanner { now }
        _ = s.scan([p(100, cpu: 0)], appPIDs: [100], metric: .energy, time: 0, absTime: 10, cpuTicks: ticks0)
        // The app: 0.1 J itself; helpers that came and went: 0.4 J more.
        now = [7: CoalitionUsage(cpuTimeNs: 300_000_000, energyNj: 500_000_000)]
        let r = s.scan([p(100, cpu: 100_000_000, energy: 100_000_000)], appPIDs: [100], metric: .energy,
                       time: 1, absTime: 20, cpuTicks: CPUTicks(user: 10, system: 0, idle: 90, nice: 0))
        let app = r.apps.first { $0.appPID == 100 }!
        #expect(abs(app.watts - 0.5) < 0.001)
    }

    @Test func withoutCoalitionReadingsTheEstimateStays() {
        // Same as `childCreditThatFitsTheBudgetIsKept` in ProcessScanTests, but the coalition
        // can't be read (an older or newer macOS): unchanged behaviour.
        let s = scanner { [:] }
        _ = s.scan([p(100, cpu: 0), p(101, ppid: 100, cpu: 0)], appPIDs: [100], metric: .cpu,
                   time: 0, absTime: 10, cpuTicks: ticks0)
        let r = s.scan([p(100, cpu: 0), p(101, ppid: 100, cpu: 0, child: 1_500_000_000)], appPIDs: [100],
                       metric: .cpu, time: 1, absTime: 20, cpuTicks: CPUTicks(user: 50, system: 0, idle: 50, nice: 0))
        #expect(abs((r.apps.first { $0.appPID == 100 }?.cpuPercent ?? 0) - 37.5) < 0.001)
    }

    @Test func residualNeverPushesTheRowsPastTheHeader() {
        var now: [UInt64: CoalitionUsage] = [7: CoalitionUsage(cpuTimeNs: 0, energyNj: 0)]
        let s = scanner { now }
        _ = s.scan([p(100, cpu: 0)], appPIDs: [100], metric: .cpu, time: 0, absTime: 10, cpuTicks: ticks0)
        now = [7: CoalitionUsage(cpuTimeNs: 3_000_000_000, energyNj: 0)]
        let r = s.scan([p(100, cpu: 0)], appPIDs: [100], metric: .cpu, time: 1, absTime: 20,
                       cpuTicks: CPUTicks(user: 20, system: 0, idle: 80, nice: 0))
        #expect(r.apps.reduce(0) { $0 + $1.cpuPercent } <= 20.001)
    }
}

import Testing
import Foundation
@testable import MacStatsCore

@Suite struct AlertMonitorTests {
    private func monitor() -> AlertMonitor {
        var c = AlertMonitor.Config()
        c.cpuThreshold = 85; c.cpuSustain = 30; c.cooldown = 300
        return AlertMonitor(config: c)
    }
    private func t(_ s: Double) -> Date { Date(timeIntervalSinceReferenceDate: s) }
    private func sample(cpu: Double, _ p: MemoryPressure, at s: Double) -> AlertSample {
        AlertSample(cpuPercent: cpu, pressure: p, time: t(s))
    }

    @Test func belowThresholdNeverFires() {
        let m = monitor()
        for s in stride(from: 0.0, through: 100, by: 10) {
            #expect(m.ingest(sample(cpu: 50, .normal, at: s)) == [])
        }
    }
    @Test func sustainedCPUFiresOnceAfterWindow() {
        let m = monitor()
        #expect(m.ingest(sample(cpu: 90, .normal, at: 0)) == [])
        #expect(m.ingest(sample(cpu: 90, .normal, at: 20)) == [])
        #expect(m.ingest(sample(cpu: 90, .normal, at: 30)) == [.highCPU])
        #expect(m.ingest(sample(cpu: 90, .normal, at: 40)) == [])
    }
    @Test func briefSpikeUnderWindowDoesNotFire() {
        let m = monitor()
        #expect(m.ingest(sample(cpu: 90, .normal, at: 0)) == [])
        #expect(m.ingest(sample(cpu: 50, .normal, at: 10)) == [])
        #expect(m.ingest(sample(cpu: 90, .normal, at: 20)) == [])
        #expect(m.ingest(sample(cpu: 90, .normal, at: 45)) == [])
    }
    @Test func cpuRefiresOnlyAfterRecoveryAndCooldown() {
        let m = monitor()
        #expect(m.ingest(sample(cpu: 90, .normal, at: 0)) == [])
        #expect(m.ingest(sample(cpu: 90, .normal, at: 30)) == [.highCPU])
        #expect(m.ingest(sample(cpu: 50, .normal, at: 40)) == [])
        #expect(m.ingest(sample(cpu: 90, .normal, at: 50)) == [])
        #expect(m.ingest(sample(cpu: 90, .normal, at: 90)) == [])
        #expect(m.ingest(sample(cpu: 90, .normal, at: 360)) == [.highCPU])
    }
    @Test func memoryWarningAndCriticalFireOnceUntilRecovery() {
        let m = monitor()
        #expect(m.ingest(sample(cpu: 0, .normal, at: 0)) == [])
        #expect(m.ingest(sample(cpu: 0, .warning, at: 10)) == [.memoryPressure])
        #expect(m.ingest(sample(cpu: 0, .critical, at: 20)) == [])
        #expect(m.ingest(sample(cpu: 0, .normal, at: 30)) == [])
        #expect(m.ingest(sample(cpu: 0, .critical, at: 400)) == [.memoryPressure])
    }
    @Test func bothCanFireInOneSample() {
        let m = monitor()
        _ = m.ingest(sample(cpu: 90, .normal, at: 0))
        let fired = m.ingest(sample(cpu: 90, .warning, at: 30))
        #expect(fired == [.highCPU, .memoryPressure])
    }
}

import Testing
import Darwin
import Foundation
@testable import MacStatsCore

@Suite struct ProcessReaderSmokeTests {
    @Test func returnsCurrentProcessWithSaneFields() {
        let procs = readRawProcesses()
        #expect(!procs.isEmpty)

        let me = procs.first { $0.pid == getpid() }
        #expect(me != nil)                       // our own process is listed
        #expect(me?.ppid ?? 0 > 0)               // has a parent
        // CPU time is cumulative-since-launch (could be small but non-negative); memory > 0.
        #expect((me?.memoryBytes ?? 0) > 0)
    }

    /// Memory must be the physical footprint (Activity Monitor's Memory column), not RSS.
    /// Cross-checked against the kernel's own figure via a separate API (task_info).
    @Test func memoryIsPhysicalFootprint() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        #expect(kr == KERN_SUCCESS)

        let me = readRawProcesses().first { $0.pid == getpid() }
        let ours = Double(me?.memoryBytes ?? 0)
        let footprint = Double(info.phys_footprint)
        // Both reads are microseconds apart; allow a little drift for allocations in between.
        #expect(abs(ours - footprint) <= footprint * 0.05)
    }

    @Test func machTicksConvertToNanoseconds() {
        #expect(machTicksToNanoseconds(1_000, numer: 1, denom: 1) == 1_000)                // Intel
        #expect(machTicksToNanoseconds(24_000_000, numer: 125, denom: 3) == 1_000_000_000) // Apple Silicon: 24 MHz
        #expect(machTicksToNanoseconds(1, numer: 125, denom: 3) == 41)                     // truncates
        // Large counts don't overflow the intermediate product.
        #expect(machTicksToNanoseconds(UInt64.max / 100, numer: 125, denom: 3) > UInt64.max / 100)
    }

    @Test func cpuTimeIsInNanoseconds() {
        // Burn ~0.2s of CPU, then compare our reading's delta with getrusage (µs, unit-safe).
        func rusageNs() -> UInt64 {
            var ru = rusage(); getrusage(RUSAGE_SELF, &ru)
            let us = (ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) * 1_000_000
                + Int(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec)
            return UInt64(us) * 1_000
        }
        func readNs() -> UInt64 { readRawProcesses().first { $0.pid == getpid() }?.cpuTimeNs ?? 0 }
        let (r0, c0) = (rusageNs(), readNs())
        let start = Date()
        var x = 0.0
        while Date().timeIntervalSince(start) < 0.2 { x += sin(x) + 1 }
        let (r1, c1) = (rusageNs(), readNs())
        #expect(x > 0)
        let ratio = Double(c1 - c0) / Double(r1 - r0)
        #expect(ratio > 0.7 && ratio < 1.5)   // unconverted Mach units read ~0.024 on Apple Silicon
    }

    @Test func energyIsReadForOwnProcess() {
        let me = readRawProcesses(includeEnergy: true).first { $0.pid == getpid() }
        #expect(me != nil)
        #expect((me?.energyNj ?? 0) > 0)
    }
}

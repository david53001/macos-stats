import Testing
import Darwin
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

    @Test func energyIsReadForOwnProcess() {
        let me = readRawProcesses(includeEnergy: true).first { $0.pid == getpid() }
        #expect(me != nil)
        #expect((me?.energyNj ?? 0) > 0)
    }
}

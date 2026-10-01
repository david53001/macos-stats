import Foundation
import Darwin

/// Enumerates the current user's processes via libproc and reads each one's cumulative
/// CPU time, memory, and parent pid. Other users' processes are skipped (we can only act on
/// our own, and they shouldn't appear in a "your apps" list). Best-effort: processes that
/// disappear mid-scan or refuse a read are simply omitted.
/// Memory is the physical footprint (`ri_phys_footprint`), the figure Activity Monitor's
/// Memory column shows; resident size (RSS) is used only if the rusage read fails, since it
/// also counts shared framework pages and overstates an app by tens of MB.
/// The same rusage read carries cumulative CPU energy, reported only when `includeEnergy`.
public func readRawProcesses(includeEnergy: Bool = false) -> [RawProcess] {
    let uid = getuid()

    // First call sizes the buffer (bytes), then fetch with headroom for races.
    let sizeBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard sizeBytes > 0 else { return [] }
    let capacity = Int(sizeBytes) / MemoryLayout<pid_t>.size + 64
    var pids = [pid_t](repeating: 0, count: capacity)
    let gotBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard gotBytes > 0 else { return [] }
    let count = Int(gotBytes) / MemoryLayout<pid_t>.size

    var result: [RawProcess] = []
    result.reserveCapacity(count)
    let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
    let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)

    for i in 0..<count {
        let pid = pids[i]
        guard pid > 0 else { continue }

        var bsd = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize,
              bsd.pbi_uid == uid else { continue }

        var task = proc_taskinfo()
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize else { continue }

        // One rusage read per process gives both the footprint and the energy counter.
        var usage = rusage_info_v6()
        let haveUsage = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) == 0
            }
        }
        let energyNj: UInt64 = includeEnergy && haveUsage ? usage.ri_energy_nj : 0

        result.append(RawProcess(
            pid: pid,
            ppid: Int32(bitPattern: bsd.pbi_ppid),
            cpuTimeNs: machTicksToNanoseconds(task.pti_total_user + task.pti_total_system,
                                              numer: machTimebase.numer, denom: machTimebase.denom),
            memoryBytes: haveUsage ? usage.ri_phys_footprint : task.pti_resident_size,
            energyNj: energyNj
        ))
    }
    return result
}

/// `pti_total_user`/`pti_total_system` are in Mach absolute-time units, not nanoseconds:
/// 1 unit = numer/denom ns. That's 1/1 on Intel but 125/3 on Apple Silicon (24 MHz ticks),
/// so the raw values read ~41.7× too low there. Read once; it never changes.
private let machTimebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else {
        return mach_timebase_info_data_t(numer: 1, denom: 1)
    }
    return info
}()

/// Converts Mach absolute-time units to nanoseconds without overflowing the intermediate
/// product (`ticks * numer` would overflow for large tick counts).
func machTicksToNanoseconds(_ ticks: UInt64, numer: UInt32, denom: UInt32) -> UInt64 {
    let n = UInt64(numer), d = UInt64(denom)
    return ticks / d * n + ticks % d * n / d
}

import Foundation
import Darwin

/// Enumerates the current user's processes via libproc and reads each one's cumulative
/// CPU time, resident memory, and parent pid. Other users' processes are skipped (we can
/// only act on our own, and they shouldn't appear in a "your apps" list). Best-effort:
/// processes that disappear mid-scan or refuse a read are simply omitted.
public func readRawProcesses() -> [RawProcess] {
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

        result.append(RawProcess(
            pid: pid,
            ppid: Int32(bitPattern: bsd.pbi_ppid),
            cpuTimeNs: task.pti_total_user + task.pti_total_system,
            memoryBytes: task.pti_resident_size
        ))
    }
    return result
}

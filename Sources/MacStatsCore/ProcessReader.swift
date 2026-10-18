import Foundation
import Darwin

/// Enumerates the current user's processes via libproc and reads each one's cumulative
/// CPU time, memory, and parent pid. Other users' processes are skipped (we can only act on
/// our own, and their usage can't be read anyway). Best-effort: processes that disappear
/// mid-scan or refuse a read are simply omitted.
/// Memory is the physical footprint (`ri_phys_footprint`), the figure Activity Monitor's
/// Memory column shows; resident size (RSS) is used only if the rusage read fails, since it
/// also counts shared framework pages and overstates an app by tens of MB.
/// Two reads per process: a short BSD info (parent, owner) and one rusage read, which carries
/// CPU time, footprint, energy (reported only when `includeEnergy`), reaped children's CPU
/// time and the start time.
public func readRawProcesses(includeEnergy: Bool = false) -> [RawProcess] {
    let uid = getuid()

    // First call sizes the buffer (bytes), then fetch with headroom for races.
    let sizeBytes = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
    guard sizeBytes > 0 else { return [] }
    let capacity = Int(sizeBytes) / MemoryLayout<pid_t>.size + 64
    var pids = [pid_t](repeating: 0, count: capacity)
    let gotBytes = proc_listpids(UInt32(PROC_UID_ONLY), uid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard gotBytes > 0 else { return [] }
    let count = Int(gotBytes) / MemoryLayout<pid_t>.size

    var result: [RawProcess] = []
    result.reserveCapacity(count)
    let bsdSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)

    for i in 0..<count {
        let pid = pids[i]
        guard pid > 0 else { continue }

        var bsd = proc_bsdshortinfo()
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bsd, bsdSize) == bsdSize,
              bsd.pbsi_uid == uid else { continue }

        if let usage = readRusage(pid) {
            result.append(RawProcess(
                pid: pid,
                ppid: Int32(bitPattern: bsd.pbsi_ppid),
                cpuTimeNs: machToNs(usage.ri_user_time + usage.ri_system_time),
                memoryBytes: usage.ri_phys_footprint,
                energyNj: includeEnergy ? usage.ri_energy_nj : 0,
                childCPUTimeNs: machToNs(usage.ri_child_user_time + usage.ri_child_system_time),
                startTime: usage.ri_proc_start_abstime
            ))
        } else {
            // Rare: fall back to task info (CPU time + resident size).
            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize else { continue }
            result.append(RawProcess(
                pid: pid,
                ppid: Int32(bitPattern: bsd.pbsi_ppid),
                cpuTimeNs: machToNs(task.pti_total_user + task.pti_total_system),
                memoryBytes: task.pti_resident_size
            ))
        }
    }
    return result
}

private func readRusage(_ pid: pid_t) -> rusage_info_v6? {
    var usage = rusage_info_v6()
    let ok = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) == 0
        }
    }
    return ok ? usage : nil
}

/// The start time (`RawProcess.startTime`) of `pid` if it is one of the current user's
/// processes, else nil. Lets an action confirm a pid still names the process the user saw.
public func startTimeOfOwnProcess(_ pid: Int32) -> UInt64? {
    guard pid > 0 else { return nil }
    var bsd = proc_bsdshortinfo()
    let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bsd, size) == size,
          bsd.pbsi_uid == getuid() else { return nil }
    return readRusage(pid)?.ri_proc_start_abstime
}

/// Parent pid of every process on the system, root's included (`ps` reads the same table).
/// libproc can't read a root process such as a Terminal tab's `login`, so a parent chain
/// that passes through one needs this to reach the app. ~0.1 ms and a ~0.5 MB transient
/// buffer, so it's fetched only when needed (see `ProcessAttributor`).
public func readAllParentPIDs() -> [Int32: Int32] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
    let stride = MemoryLayout<kinfo_proc>.stride
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
    size = procs.count * stride
    guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return [:] }
    var parents: [Int32: Int32] = [:]
    parents.reserveCapacity(size / stride)
    for p in procs.prefix(size / stride) {
        parents[p.kp_proc.p_pid] = p.kp_eproc.e_ppid
    }
    return parents
}

/// The app macOS holds responsible for `pid` (Terminal for everything in its tabs; an app for
/// its XPC helpers), via libSystem's `responsibility_get_pid_responsible_for_pid`. That
/// function isn't in a public header, so it's looked up at runtime: if a macOS version lacks
/// it, or the call fails (≤ 0, e.g. a root process), this returns nil and attribution falls
/// back to the parent chain.
public func responsiblePID(for pid: Int32) -> Int32? {
    guard let fn = responsibilityFunction else { return nil }
    let r = fn(pid)
    return r > 0 ? r : nil
}

private typealias ResponsibilityFunction = @convention(c) (pid_t) -> pid_t
private let responsibilityFunction: ResponsibilityFunction? = {
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
    guard let symbol = dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(symbol, to: ResponsibilityFunction.self)
}()

/// A process's display name: its full name (`proc_name`, 32 characters, so "Code Helper
/// (Renderer)" isn't cut to 16), or, when that is just a version number (Claude Code's
/// binary is named like "2.1.289"), the command it was launched as. nil if unreadable.
public func processName(_ pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 64)
    guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    let name = String(cString: buffer)
    if isVersionLikeProcessName(name), let launched = launchName(pid) { return launched }
    return name
}

/// "2.1.289", "18": a name made only of digits and dots says nothing about the process.
public func isVersionLikeProcessName(_ name: String) -> Bool {
    guard let first = name.first, first.isASCII, first.isNumber else { return false }
    return name.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == "." }
}

/// Last path component of argv[0], from the kernel's copy of the process's arguments
/// (KERN_PROCARGS2: argc, the executable path, padding, then argv).
private func launchName(_ pid: Int32) -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    var i = MemoryLayout<Int32>.size
    while i < size, buffer[i] != 0 { i += 1 }   // executable path
    while i < size, buffer[i] == 0 { i += 1 }   // padding
    let start = i
    while i < size, buffer[i] != 0 { i += 1 }   // argv[0]
    guard i > start, let arg0 = String(bytes: buffer[start..<i], encoding: .utf8) else { return nil }
    let name = (arg0 as NSString).lastPathComponent
    return name.isEmpty ? nil : name
}

private func machToNs(_ ticks: UInt64) -> UInt64 {
    machTicksToNanoseconds(ticks, numer: machTimebase.numer, denom: machTimebase.denom)
}

/// CPU times from libproc (`ri_*_time`, `pti_total_*`) are in Mach absolute-time units, not
/// nanoseconds: 1 unit = numer/denom ns. That's 1/1 on Intel but 125/3 on Apple Silicon
/// (24 MHz ticks), so the raw values read ~41.7× too low there. Read once; it never changes.
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

import Foundation
import Darwin
import IOKit.ps

/// Reads cumulative aggregate CPU ticks via host_statistics(HOST_CPU_LOAD_INFO).
public func readCPUTicks() -> CPUTicks {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return CPUTicks(user: 0, system: 0, idle: 0, nice: 0) }
    // cpu_ticks is a 4-tuple indexed by CPU_STATE_{USER,SYSTEM,IDLE,NICE} = 0,1,2,3
    return CPUTicks(
        user: info.cpu_ticks.0,
        system: info.cpu_ticks.1,
        idle: info.cpu_ticks.2,
        nice: info.cpu_ticks.3
    )
}

/// Reads VM page statistics via host_statistics64(HOST_VM_INFO64).
public func readVMRaw() -> VMRaw {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    var pageSize: vm_size_t = 0
    host_page_size(mach_host_self(), &pageSize)
    guard kr == KERN_SUCCESS else {
        return VMRaw(free: 0, active: 0, inactive: 0, wired: 0, compressed: 0,
                     internal: 0, purgeable: 0, pageSize: UInt64(pageSize))
    }
    return VMRaw(
        free: UInt64(stats.free_count),
        active: UInt64(stats.active_count),
        inactive: UInt64(stats.inactive_count),
        wired: UInt64(stats.wire_count),
        compressed: UInt64(stats.compressor_page_count),
        internal: UInt64(stats.internal_page_count),
        purgeable: UInt64(stats.purgeable_count),
        pageSize: UInt64(pageSize)
    )
}

/// Sums byte counters across all non-loopback interfaces.
///
/// Uses the `IFMIB_IFALLDATA` sysctl (`net.link.generic`), one call for every interface's
/// 64-bit `if_data64`. `getifaddrs`' `if_data` counters are 32-bit and wrap every 4 GiB per
/// interface (a dropped sample each time, or a blip to 0 on a fast download), and the
/// `NET_RT_IFLIST2` dump hands unentitled apps the same values truncated to 32 bits and rounded
/// to 4 KiB (measured on macOS 26: en0 7 708 354 392 B in `netstat` vs 3 413 385 216 there).
/// This read matched `netstat -ib` to the byte and costs ~7 µs (getifaddrs: ~13 µs).
/// Note: VPN tunnels (`utun*`) are summed too, so traffic through a VPN may count twice (once
/// on the tunnel, once on Wi-Fi). Not verified (no VPN was active when checked); unchanged.
public func readNetCounters() -> NetCounters {
    var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFALLDATA, 0, IFDATA_GENERAL]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
        return NetCounters(rxBytes: 0, txBytes: 0)
    }
    let stride = MemoryLayout<ifmibdata>.stride
    var interfaces = [ifmibdata](repeating: ifmibdata(), count: size / stride + 2)   // + room for a new one
    size = interfaces.count * stride
    guard sysctl(&mib, u_int(mib.count), &interfaces, &size, nil, 0) == 0 else {
        return NetCounters(rxBytes: 0, txBytes: 0)
    }
    return sumInterfaceCounters(interfaces.prefix(size / stride))
}

/// Sums the 64-bit byte counters of `interfaces`, skipping loopback.
func sumInterfaceCounters<C: Collection>(_ interfaces: C) -> NetCounters where C.Element == ifmibdata {
    var rx: UInt64 = 0
    var tx: UInt64 = 0
    for interface in interfaces where interface.ifmd_flags & UInt32(IFF_LOOPBACK) == 0 {
        rx &+= interface.ifmd_data.ifi_ibytes
        tx &+= interface.ifmd_data.ifi_obytes
    }
    return NetCounters(rxBytes: rx, txBytes: tx)
}

/// Reads the kernel's current memory-pressure level via sysctl.
/// Returns 1 (normal), 2 (warning), or 4 (critical); 1 on failure.
public func readMemoryPressureLevel() -> Int {
    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size
    let ok = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
    return ok ? Int(level) : 1
}

/// Reads the first usable power source via IOKit. Returns nil if no battery.
public func readBattery() -> BatterySample? {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
        return nil
    }
    for source in sources {
        if let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
           let sample = parseBattery(desc) {
            return sample
        }
    }
    return nil
}

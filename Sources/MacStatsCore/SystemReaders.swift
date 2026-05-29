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
        return VMRaw(free: 0, active: 0, inactive: 0, wired: 0, compressed: 0, pageSize: UInt64(pageSize))
    }
    return VMRaw(
        free: UInt64(stats.free_count),
        active: UInt64(stats.active_count),
        inactive: UInt64(stats.inactive_count),
        wired: UInt64(stats.wire_count),
        compressed: UInt64(stats.compressor_page_count),
        pageSize: UInt64(pageSize)
    )
}

/// Sums byte counters across all non-loopback link-layer interfaces via getifaddrs.
public func readNetCounters() -> NetCounters {
    var rx: UInt64 = 0
    var tx: UInt64 = 0
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0 else { return NetCounters(rxBytes: 0, txBytes: 0) }
    defer { freeifaddrs(ifap) }
    var ptr = ifap
    while let cur = ptr {
        if let addr = cur.pointee.ifa_addr, Int32(addr.pointee.sa_family) == AF_LINK {
            let name = String(cString: cur.pointee.ifa_name)
            if !name.hasPrefix("lo"), let raw = cur.pointee.ifa_data {
                let data = raw.assumingMemoryBound(to: if_data.self)
                rx += UInt64(data.pointee.ifi_ibytes)
                tx += UInt64(data.pointee.ifi_obytes)
            }
        }
        ptr = cur.pointee.ifa_next
    }
    return NetCounters(rxBytes: rx, txBytes: tx)
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

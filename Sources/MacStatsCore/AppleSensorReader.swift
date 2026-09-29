import Foundation
import CoreFoundation
import CAppleSensors

private let kIOHIDEventTypeTemperature: Int64 = 15
private let temperatureField = Int32(kIOHIDEventTypeTemperature << 16)   // 983040

/// A client matching the thermal sensors (vendor usage page 0xff00, usage 5), or nil.
private func makeThermalClient() -> IOHIDEventSystemClient? {
    guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return nil }
    let matching: [String: Int] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
    IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)
    return client
}

/// (sensor name, service) for every sensor the client currently matches.
private func thermalServices(_ client: IOHIDEventSystemClient) -> [(name: String, service: AnyObject)] {
    guard let services = IOHIDEventSystemClientCopyServices(client) as? [AnyObject] else { return [] }
    return services.compactMap { service in
        guard let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String
        else { return nil }
        return (name: name, service: service)
    }
}

/// Current °C of one sensor, or nil if it produced no event.
private func celsius(of service: AnyObject) -> Double? {
    guard let event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0)
    else { return nil }
    return IOHIDEventGetFloatValue(event, temperatureField)
}

/// Reads Apple thermal sensors via the private IOHIDEventSystemClient API.
/// Returns (sensor name, °C) pairs. Empty if the API yields nothing (graceful no-temp).
/// Creates a fresh client and enumerates every sensor each call — fine for a one-off dump or
/// the smoke test; the app's periodic reads use `CPUTemperatureReader`.
public func readAppleThermalSensors() -> [(name: String, celsius: Double)] {
    guard let client = makeThermalClient() else { return [] }
    return thermalServices(client).compactMap { s in
        celsius(of: s.service).map { (name: s.name, celsius: $0) }
    }
}

/// Periodic CPU-temperature reader. Creating the event-system client and enumerating all
/// (~dozens of) thermal services is the expensive part, so this does it once and caches only
/// the CPU die sensors (`cpuSensorMatches`); each read then copies just those few events.
/// Re-discovers only while the cache is empty (e.g. no usable sensor on this chip). Not
/// thread-safe — use from one thread (the app reads it on the main actor).
public final class CPUTemperatureReader {
    private let client: IOHIDEventSystemClient? = makeThermalClient()
    private var cpuSensors: [(name: String, service: AnyObject)] = []

    public init() {}

    /// Average CPU die temperature (°C, rounded), or nil if no usable sensor.
    public func read() -> Double? {
        if cpuSensors.isEmpty, let client {
            cpuSensors = thermalServices(client).filter { s in
                cpuSensorMatches.contains { s.name.contains($0) }
            }
        }
        return cpuTemperature(from: cpuSensors.compactMap { s in
            celsius(of: s.service).map { (name: s.name, celsius: $0) }
        })
    }
}

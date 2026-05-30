import Foundation
import CoreFoundation
import CAppleSensors

/// Reads Apple thermal sensors via the private IOHIDEventSystemClient API.
/// Returns (sensor name, °C) pairs. Empty if the API yields nothing (graceful no-temp).
public func readAppleThermalSensors() -> [(name: String, celsius: Double)] {
    let kIOHIDEventTypeTemperature: Int64 = 15
    let temperatureField: Int32 = Int32(kIOHIDEventTypeTemperature << 16)   // 983040

    let matching: [String: Int] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]

    guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return [] }
    IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)
    guard let services = IOHIDEventSystemClientCopyServices(client) as? [AnyObject] else {
        return []
    }

    var result: [(name: String, celsius: Double)] = []
    for service in services {
        guard let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String,
              let event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0)
        else { continue }
        let celsius = IOHIDEventGetFloatValue(event, temperatureField)
        result.append((name: name, celsius: celsius))
    }
    return result
}

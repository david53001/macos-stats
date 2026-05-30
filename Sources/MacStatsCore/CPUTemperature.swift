/// Sensor-name substrings treated as CPU/SoC-cluster die temperatures. Confirmed against
/// this machine (Apple M3, Mac15,12) in the Task 11 spike: the readable thermal sensors are
/// phrases like "PMU tdie1" / "PMU2 tdie5" (silicon die temperatures, ~42–50°C). There are
/// no classic Tp/Tc/Te short-code sensors on this chip, so we match the "tdie" substring
/// rather than a prefix. Adjust here if a dump on another chip shows different CPU names.
public let cpuSensorMatches = ["tdie"]

/// Average CPU temperature (°C, rounded) from a set of named thermal sensors, or nil if no
/// CPU-cluster sensor reports a physically sane value.
public func cpuTemperature(from sensors: [(name: String, celsius: Double)]) -> Double? {
    let cpu = sensors.filter { sensor in
        cpuSensorMatches.contains { sensor.name.contains($0) }
    }
    let valid = cpu.filter { $0.celsius > 0 && $0.celsius < 150 }
    guard !valid.isEmpty else { return nil }
    let avg = valid.map(\.celsius).reduce(0, +) / Double(valid.count)
    return avg.rounded()
}

import IOKit.ps

public struct BatterySample: Equatable {
    public var percent: Int
    public var isCharging: Bool
    /// Estimated minutes until empty; nil while charging or when unknown.
    public var timeToEmptyMinutes: Int?

    public init(percent: Int, isCharging: Bool, timeToEmptyMinutes: Int?) {
        self.percent = percent; self.isCharging = isCharging
        self.timeToEmptyMinutes = timeToEmptyMinutes
    }
}

/// Parses one IOPowerSources description dictionary into a BatterySample.
/// Returns nil if the dictionary has no usable capacity (e.g. a desktop with no battery).
public func parseBattery(_ d: [String: Any]) -> BatterySample? {
    guard let current = d[kIOPSCurrentCapacityKey as String] as? Int,
          let maxCap = d[kIOPSMaxCapacityKey as String] as? Int, maxCap > 0 else {
        return nil
    }
    let percent = Int((Double(current) / Double(maxCap) * 100).rounded())
    let charging = (d[kIOPSIsChargingKey as String] as? Bool) ?? false
    let rawTTE = d[kIOPSTimeToEmptyKey as String] as? Int
    let timeToEmpty = (charging || (rawTTE ?? -1) < 0) ? nil : rawTTE
    return BatterySample(percent: percent, isCharging: charging, timeToEmptyMinutes: timeToEmpty)
}

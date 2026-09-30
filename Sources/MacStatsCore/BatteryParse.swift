import IOKit.ps

/// What the battery is doing, as the macOS battery menu reports it.
public enum BatteryState: Equatable {
    case charging
    /// Plugged in and full. The battery may still drift down slowly; macOS calls it charged.
    case charged
    /// Plugged in but held (Optimized Charging, a charge limit, a weak adapter).
    case notCharging
    case discharging

    public var isPluggedIn: Bool { self != .discharging }
}

public struct BatterySample: Equatable {
    public var percent: Int
    public var state: BatteryState
    /// Minutes until empty; nil while plugged in or when unknown. `parseBattery` fills in
    /// macOS's short-horizon figure; the app replaces it with `BatteryEstimator`'s.
    public var timeToEmptyMinutes: Int?
    /// macOS's minutes-to-full while charging; nil otherwise or while it's still calculating.
    public var timeToFullMinutes: Int?

    public var isCharging: Bool { state == .charging }

    public init(percent: Int, state: BatteryState, timeToEmptyMinutes: Int? = nil,
                timeToFullMinutes: Int? = nil) {
        self.percent = percent; self.state = state
        self.timeToEmptyMinutes = timeToEmptyMinutes
        self.timeToFullMinutes = timeToFullMinutes
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
    let charged = (d[kIOPSIsChargedKey as String] as? Bool) ?? false
    let onAC = (d[kIOPSPowerSourceStateKey as String] as? String) == kIOPSACPowerValue

    let state: BatteryState
    if charging { state = .charging }
    else if onAC { state = charged || percent >= 100 ? .charged : .notCharging }
    else { state = .discharging }

    // IOPS reports -1 while "calculating"; 0 means nothing useful either.
    func minutes(_ key: String) -> Int? {
        guard let m = d[key] as? Int, m > 0 else { return nil }
        return m
    }
    return BatterySample(
        percent: percent, state: state,
        timeToEmptyMinutes: state == .discharging ? minutes(kIOPSTimeToEmptyKey) : nil,
        timeToFullMinutes: state == .charging ? minutes(kIOPSTimeToFullChargeKey) : nil)
}

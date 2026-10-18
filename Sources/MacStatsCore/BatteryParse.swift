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
    /// Minutes to full (or to `chargeStopPercent`) while charging; nil otherwise or while
    /// still calculating. `parseBattery` fills in macOS's figure; the app replaces it with
    /// a measured one (`minutesToTarget`).
    public var timeToFullMinutes: Int?
    /// macOS's own figures (`parseBattery`), kept after the app replaces the two above, for the
    /// rows' tooltips. macOS's time to full always counts to 100 %, even with a charge limit.
    public var macOSTimeToEmptyMinutes: Int?
    public var macOSTimeToFullMinutes: Int?
    /// The end-of-charge limit when below 100 (the user's charge limit); nil for a full charge
    /// or when unknown. Set by the app (`chargeStop`).
    public var chargeLimitPercent: Int?
    /// Optimized Charging's hold when charging is heading for it or is held at it. Set by the app.
    public var chargeHoldPercent: Int?
    /// True when nothing is known about a limit, so time to full assumes 100 % and is labelled
    /// "to 100%" rather than "to full". Set by the app.
    public var chargeTargetAssumed = false

    public var isCharging: Bool { state == .charging }

    /// Where the current charge stops below 100 %: the hold, else the limit.
    public var chargeStopPercent: Int? { chargeHoldPercent ?? chargeLimitPercent }

    /// The user's charge limit when charging has stopped at it ("Charged to 85% Limit" in the
    /// macOS battery menu). macOS only reports "not charging"; the shown percent can sit one
    /// off the limit (raw 84.0 % shows as 84 or 85), so within one counts. Further above it (a
    /// limit set while the battery was fuller) stays plain "not charging": "Charged to 85%
    /// limit" at 95 % would be wrong.
    public var heldAtLimitPercent: Int? {
        guard state == .notCharging, chargeHoldPercent == nil, let limit = chargeLimitPercent,
              abs(percent - limit) <= 1 else { return nil }
        return limit
    }

    public init(percent: Int, state: BatteryState, timeToEmptyMinutes: Int? = nil,
                timeToFullMinutes: Int? = nil) {
        self.percent = percent; self.state = state
        self.timeToEmptyMinutes = timeToEmptyMinutes
        self.timeToFullMinutes = timeToFullMinutes
        self.macOSTimeToEmptyMinutes = timeToEmptyMinutes
        self.macOSTimeToFullMinutes = timeToFullMinutes
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

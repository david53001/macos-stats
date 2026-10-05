import Foundation
import IOKit

/// Readings from the `AppleSmartBattery` IORegistry entry: power draw, raw capacity, health.
/// The battery gauge refreshes these about once a minute (`updateTime` steps when it does).
public struct BatteryTelemetry: Equatable {
    /// Gauge update timestamp (Unix seconds). Unchanged ⇒ every other value is unchanged too.
    public var updateTime: Int
    public var voltageMV: Int?
    /// Battery current, mA; negative while discharging.
    public var amperageMA: Int?
    public var currentMAh: Int?
    /// The gauge's full-charge capacity (mAh). `currentMAh / rawMaxMAh` is the gauge's raw
    /// state of charge, which runs a few points off the percent macOS shows (67.8 % raw at
    /// 71 % shown on this M3), so percents shown to the user are sized against it, not equal to it.
    public var rawMaxMAh: Int?
    public var nominalMAh: Int?
    public var designMAh: Int?
    public var cycleCount: Int?
    public var temperatureC: Double?
    public var adapterWatts: Int?
    /// Whole-Mac power draw (mW), Apple Silicon only, plus the running sum/count of it that
    /// gives an exact average between two reads.
    public var systemLoadMW: Int?
    public var accumulatedSystemLoad: UInt64?
    public var systemLoadCount: UInt64?

    public init(updateTime: Int, voltageMV: Int? = nil, amperageMA: Int? = nil, currentMAh: Int? = nil,
                rawMaxMAh: Int? = nil, nominalMAh: Int? = nil, designMAh: Int? = nil, cycleCount: Int? = nil,
                temperatureC: Double? = nil, adapterWatts: Int? = nil, systemLoadMW: Int? = nil,
                accumulatedSystemLoad: UInt64? = nil, systemLoadCount: UInt64? = nil) {
        self.updateTime = updateTime; self.voltageMV = voltageMV; self.amperageMA = amperageMA
        self.currentMAh = currentMAh; self.rawMaxMAh = rawMaxMAh; self.nominalMAh = nominalMAh; self.designMAh = designMAh
        self.cycleCount = cycleCount; self.temperatureC = temperatureC; self.adapterWatts = adapterWatts
        self.systemLoadMW = systemLoadMW; self.accumulatedSystemLoad = accumulatedSystemLoad
        self.systemLoadCount = systemLoadCount
    }

    /// Energy the battery can still deliver, watt-hours: the charge left times the average
    /// voltage over the rest of the discharge, taken midway between now and a 3.5 V-per-cell
    /// end. The pack's voltage sags as it empties (12.1 V at 68 % on a 3-cell pack), so the
    /// present voltage alone overstated it, and the time left, by ~6 %.
    public var remainingWh: Double? {
        guard let mAh = currentMAh, let mV = voltageMV, mAh > 0, mV > 0 else { return nil }
        let volts = Double(mV) / 1000
        // Li-ion cells sit at ≤ 4.45 V, so this is the series cell count (2 or 3 in Macs).
        let endVolts = 3.5 * (volts / 4.45).rounded(.up)
        let averageVolts = volts > endVolts ? (volts + endVolts) / 2 : volts
        return Double(mAh) * averageVolts / 1000
    }

    /// Full-charge capacity vs. new, the "Maximum Capacity" figure in System Settings, which
    /// truncates (4542 / 4563 = 99.5 % shows as 99 %, matching `system_profiler`).
    public var healthPercent: Int? {
        guard let nominal = nominalMAh, let design = designMAh, design > 0, nominal > 0 else { return nil }
        return min(100, Int((Double(nominal) / Double(design) * 100).rounded(.down)))
    }

    /// Instantaneous whole-Mac draw in watts: the telemetry figure, else voltage × current
    /// while discharging (Intel Macs have no telemetry; there it is the battery's own draw;
    /// while charging V × A is the power going *into* the battery, not the Mac's load).
    public var instantWatts: Double? {
        if let mW = systemLoadMW, mW > 0 { return Double(mW) / 1000 }
        guard let mV = voltageMV, let mA = amperageMA, mA < 0 else { return nil }
        return abs(Double(mV) * Double(mA)) / 1_000_000
    }
}

/// The largest of the last few values. The gauge's `NominalChargeCapacity` swings ~2 %
/// between updates (4474 → 4558 mAh within minutes), which made health flicker 98/99 % while
/// System Settings held 99 %; health is taken from the peak of the recent readings. The app
/// saves `values` and seeds the next launch with them: starting empty, the first reading after
/// launch alone set health (4509 mAh → 98 % for about a minute while System Settings said 99 %).
public struct RecentMax: Equatable {
    public let capacity: Int
    public private(set) var values: [Int] = []

    /// `values`: earlier readings, oldest first (e.g. saved by the last launch); the last
    /// `capacity` positive ones are kept.
    public init(capacity: Int, values: [Int] = []) {
        self.capacity = max(1, capacity)
        self.values = Array(values.filter { $0 > 0 }.suffix(self.capacity))
    }

    /// The largest kept value, nil before any.
    public var peak: Int? { values.max() }

    /// Adds a reading and returns the largest of the last `capacity`.
    public mutating func add(_ value: Int) -> Int {
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
        return values.max() ?? value
    }
}

/// Registry keys `SmartBatteryReader` fetches (one property read each — far cheaper than
/// copying the whole property table).
let smartBatteryKeys = ["UpdateTime", "Voltage", "Amperage", "AppleRawCurrentCapacity",
                        "AppleRawMaxCapacity", "NominalChargeCapacity", "DesignCapacity", "CycleCount", "Temperature",
                        "AdapterDetails", "PowerTelemetryData"]

/// Builds `BatteryTelemetry` from `AppleSmartBattery` properties. Signed values (Amperage)
/// arrive as 64-bit unsigned bit patterns. Nil when there's no gauge timestamp.
public func parseSmartBattery(_ d: [String: Any]) -> BatteryTelemetry? {
    func int(_ v: Any?) -> Int? {
        (v as? NSNumber).map { Int(Int64(bitPattern: $0.uint64Value)) }
    }
    guard let updateTime = int(d["UpdateTime"]) else { return nil }
    let telemetry = d["PowerTelemetryData"] as? [String: Any]
    let adapter = d["AdapterDetails"] as? [String: Any]
    return BatteryTelemetry(
        updateTime: updateTime,
        voltageMV: int(d["Voltage"]),
        amperageMA: int(d["Amperage"]),
        currentMAh: int(d["AppleRawCurrentCapacity"]),
        rawMaxMAh: int(d["AppleRawMaxCapacity"]),
        nominalMAh: int(d["NominalChargeCapacity"]),
        designMAh: int(d["DesignCapacity"]),
        cycleCount: int(d["CycleCount"]),
        temperatureC: int(d["Temperature"]).map { Double($0) / 100 },   // centi-°C
        adapterWatts: int(adapter?["Watts"]).flatMap { $0 > 0 ? $0 : nil },
        systemLoadMW: int(telemetry?["SystemLoad"]),
        accumulatedSystemLoad: (telemetry?["AccumulatedSystemLoad"] as? NSNumber)?.uint64Value,
        systemLoadCount: (telemetry?["SystemLoadAccumulatorCount"] as? NSNumber)?.uint64Value)
}

/// Longest gap between two gauge updates that still counts as one awake interval. The gauge
/// steps every ≤ ~85 s while the Mac is awake; across sleep the step is the whole sleep.
public let maxGaugeInterval: TimeInterval = 180

/// Seconds between two gauge updates when they bracket awake time only, else nil.
///
/// The gauge's running power sums keep ticking (≈ 1 count/s) through sleep, so an interval
/// spanning a sleep averages the sleep (≈ 0.05 W) — feeding that to a time-left estimate
/// promises ~13 h right after opening the lid. Such intervals (and stalled or reset gauges)
/// are rejected here; the caller just rebases on the newer reading.
public func gaugeInterval(from previous: BatteryTelemetry, to current: BatteryTelemetry) -> TimeInterval? {
    let seconds = TimeInterval(current.updateTime - previous.updateTime)
    guard seconds > 0, seconds <= maxGaugeInterval else { return nil }
    if let pc = previous.systemLoadCount, let cc = current.systemLoadCount, cc >= pc,
       Double(cc - pc) > maxGaugeInterval {
        return nil
    }
    return seconds
}

/// Average whole-Mac draw (W) between two gauge updates, from the telemetry running sum;
/// falls back to the current instantaneous reading when the sums are missing or reset.
public func averageWatts(from previous: BatteryTelemetry?, to current: BatteryTelemetry) -> Double? {
    if let p = previous, let pa = p.accumulatedSystemLoad, let pc = p.systemLoadCount,
       let ca = current.accumulatedSystemLoad, let cc = current.systemLoadCount,
       cc > pc, ca >= pa {
        let watts = Double(ca - pa) / Double(cc - pc) / 1000
        if watts > 0, watts < 500 { return watts }
    }
    return current.instantWatts
}

/// The draw to show as "Power": the average over the gauge interval that ends at `current`
/// (~1 min), or the instantaneous reading when there's no awake interval to average (first
/// reading, or one after sleep). One instant `SystemLoad` was up to 4.8× off its minute's
/// average (13.2 W in a minute that averaged 3.2 W) and stayed on screen for that minute.
public func intervalWatts(from previous: BatteryTelemetry?, to current: BatteryTelemetry) -> Double? {
    guard let previous, gaugeInterval(from: previous, to: current) != nil else { return current.instantWatts }
    return averageWatts(from: previous, to: current)
}

/// Reads `AppleSmartBattery`, caching the registry entry between reads (~20 µs a read).
public final class SmartBatteryReader {
    private var entry: io_registry_entry_t = 0

    public init() {}

    deinit {
        if entry != 0 { IOObjectRelease(entry) }
    }

    /// nil on Macs without a battery.
    public func read() -> BatteryTelemetry? {
        if entry == 0 {
            entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        }
        guard entry != 0 else { return nil }
        var d: [String: Any] = [:]
        for key in smartBatteryKeys {
            if let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() {
                d[key] = value
            }
        }
        return parseSmartBattery(d)
    }
}

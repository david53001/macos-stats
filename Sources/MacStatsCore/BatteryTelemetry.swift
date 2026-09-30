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
                nominalMAh: Int? = nil, designMAh: Int? = nil, cycleCount: Int? = nil,
                temperatureC: Double? = nil, adapterWatts: Int? = nil, systemLoadMW: Int? = nil,
                accumulatedSystemLoad: UInt64? = nil, systemLoadCount: UInt64? = nil) {
        self.updateTime = updateTime; self.voltageMV = voltageMV; self.amperageMA = amperageMA
        self.currentMAh = currentMAh; self.nominalMAh = nominalMAh; self.designMAh = designMAh
        self.cycleCount = cycleCount; self.temperatureC = temperatureC; self.adapterWatts = adapterWatts
        self.systemLoadMW = systemLoadMW; self.accumulatedSystemLoad = accumulatedSystemLoad
        self.systemLoadCount = systemLoadCount
    }

    /// Energy left in the battery, watt-hours.
    public var remainingWh: Double? {
        guard let mAh = currentMAh, let mV = voltageMV, mAh > 0, mV > 0 else { return nil }
        return Double(mAh) * Double(mV) / 1_000_000
    }

    /// Full-charge capacity vs. new, the "Maximum Capacity" figure in System Settings.
    public var healthPercent: Int? {
        guard let nominal = nominalMAh, let design = designMAh, design > 0, nominal > 0 else { return nil }
        return min(100, Int((Double(nominal) / Double(design) * 100).rounded()))
    }

    /// Instantaneous whole-Mac draw in watts: the telemetry figure, else voltage × current
    /// (Intel Macs have no telemetry; there it is the battery's own draw).
    public var instantWatts: Double? {
        if let mW = systemLoadMW, mW > 0 { return Double(mW) / 1000 }
        guard let mV = voltageMV, let mA = amperageMA, mA != 0 else { return nil }
        return abs(Double(mV) * Double(mA)) / 1_000_000
    }
}

/// Registry keys `SmartBatteryReader` fetches (one property read each — far cheaper than
/// copying the whole property table).
let smartBatteryKeys = ["UpdateTime", "Voltage", "Amperage", "AppleRawCurrentCapacity",
                        "NominalChargeCapacity", "DesignCapacity", "CycleCount", "Temperature",
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
        nominalMAh: int(d["NominalChargeCapacity"]),
        designMAh: int(d["DesignCapacity"]),
        cycleCount: int(d["CycleCount"]),
        temperatureC: int(d["Temperature"]).map { Double($0) / 100 },   // centi-°C
        adapterWatts: int(adapter?["Watts"]).flatMap { $0 > 0 ? $0 : nil },
        systemLoadMW: int(telemetry?["SystemLoad"]),
        accumulatedSystemLoad: (telemetry?["AccumulatedSystemLoad"] as? NSNumber)?.uint64Value,
        systemLoadCount: (telemetry?["SystemLoadAccumulatorCount"] as? NSNumber)?.uint64Value)
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

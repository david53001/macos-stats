import Foundation

/// Which threshold was crossed.
public enum AlertKind: Equatable { case highCPU, memoryPressure }

/// One observation fed to the monitor.
public struct AlertSample: Equatable {
    public let cpuPercent: Double
    public let pressure: MemoryPressure
    public let time: Date
    public init(cpuPercent: Double, pressure: MemoryPressure, time: Date) {
        self.cpuPercent = cpuPercent; self.pressure = pressure; self.time = time
    }
}

/// Decides when to fire CPU / memory alerts. Pure: feed it samples, it returns the alerts
/// to fire now. Each metric fires once per episode — it must recover, then wait out a
/// cooldown, before it can fire again.
public final class AlertMonitor {
    public struct Config {
        public var cpuThreshold: Double = 85
        public var cpuSustain: TimeInterval = 30
        public var cooldown: TimeInterval = 300
        public init() {}
    }

    private let config: Config
    public init(config: Config = Config()) { self.config = config }

    private var cpuAboveSince: Date?
    private var cpuArmed = true
    private var cpuLastFired: Date?
    private var memArmed = true
    private var memLastFired: Date?

    public func ingest(_ s: AlertSample) -> [AlertKind] {
        var fired: [AlertKind] = []
        if checkCPU(s) { fired.append(.highCPU) }
        if checkMemory(s) { fired.append(.memoryPressure) }
        return fired
    }

    private func checkCPU(_ s: AlertSample) -> Bool {
        if s.cpuPercent > config.cpuThreshold {
            if cpuAboveSince == nil { cpuAboveSince = s.time }
            let sustained = s.time.timeIntervalSince(cpuAboveSince!) >= config.cpuSustain
            let cooled = cpuLastFired.map { s.time.timeIntervalSince($0) >= config.cooldown } ?? true
            if cpuArmed && sustained && cooled {
                cpuLastFired = s.time; cpuArmed = false
                return true
            }
        } else {
            cpuAboveSince = nil
            cpuArmed = true
        }
        return false
    }

    private func checkMemory(_ s: AlertSample) -> Bool {
        if s.pressure == .warning || s.pressure == .critical {
            let cooled = memLastFired.map { s.time.timeIntervalSince($0) >= config.cooldown } ?? true
            if memArmed && cooled {
                memLastFired = s.time; memArmed = false
                return true
            }
        } else {
            memArmed = true
        }
        return false
    }
}

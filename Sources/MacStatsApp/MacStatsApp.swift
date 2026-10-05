import AppKit
import Darwin
import IOKit.ps
import SwiftUI
import MacStatsCore

/// Owns the store, the syscall pipeline, and the adaptive refresh timers.
///
/// One sampling path (`sample`) serves both modes: while the popover is closed a 10s timer
/// runs it (alerts + a coarse history, so the graph isn't empty on open); while open a 0.5s
/// timer runs it plus the slower sensor tiers (temperature ~2s, battery ~10s).
@MainActor
final class AppModel: ObservableObject {
    let store = MetricsStore(historyWindow: 60)

    private var timer: Timer?                    // open-popover tick (one-shot, rescheduled)
    private var idleTimer: Timer?                // closed-popover sampler (repeating)
    private var reliefTimer: Timer?              // returns freed memory to the OS after close
    private var visibility: MacStatsCore.Visibility = .idle

    /// Dedicated per-process scan loop — exists only while a breakdown is open, so the
    /// expensive enumeration never runs otherwise. Kept separate from the sparkline `tick`.
    private var procTimer: Timer?
    /// Attribution caches + the previous scan, for the open breakdown only (nil otherwise).
    private var scanner: BreakdownScanner?

    /// Cumulative-counter snapshots, oldest→newest, covering ~`rateWindowSeconds` (just the
    /// last two while idle). Rates diff against the snapshot ~1s back (see `rateBaselineIndex`)
    /// so fast ticks still show a stable trailing average. Survives close/open, so the first
    /// sample after opening diffs against the idle sampler's last reading — real values on the
    /// first frame with no wait.
    private var snapshots: [Snapshot] = []
    private struct Snapshot {
        let time: Date
        let cpu: CPUTicks
        let net: NetCounters
    }

    private let thermal = CPUTemperatureReader()
    private var lastTempRead: Date?
    private var lastBatteryRead: Date?

    /// Battery time-left: the gauge's awake on-battery power readings feed a smoothed
    /// estimator whose long-run "typical drain" average is persisted across launches.
    /// Time to full: the measured charge current, to the charge limit when one is active.
    private let smartBattery = SmartBatteryReader()
    private var estimator = BatteryEstimator(
        typicalWatts: UserDefaults.standard.object(forKey: Keys.typicalWatts) as? Double,
        typicalSeconds: UserDefaults.standard.double(forKey: Keys.typicalSeconds))
    private var chargeCurrent = ChargeCurrent()
    private var learnedLimit = UserDefaults.standard.object(forKey: Keys.chargeLimit) as? Int
    private var powerdLimit = ChargeLimitHint.unknown
    private var powerdLimitReadFor: BatterySample?      // the reading it was last read for
    private var lastTelemetry: BatteryTelemetry?
    /// Health shows the peak full-charge capacity of the last ~10 gauge readings (it flickers).
    private var nominalPeak = RecentMax(capacity: 10)
    private var nominalPeakMAh: Int?
    private var lastBatteryState: BatteryState?
    private var lastEstimatorSave: Date?
    private var powerSourceObserver: CFRunLoopSource?
    private enum Keys {
        static let typicalWatts = "batteryDrainTypicalWatts"
        static let typicalSeconds = "batteryDrainTypicalSeconds"
        static let chargeLimit = "batteryLearnedChargeLimit"
        /// Before 2026-10-05: a "typical" learned from plugged-in and across-sleep readings
        /// (2.5 W on a Mac that drains 5.5 W). Dropped, not migrated.
        static let legacy = ["batteryTypicalWatts", "batteryTypicalSeconds"]
    }
    /// The typical-drain average is saved at most this often (and on plug/unplug).
    private let estimatorSaveInterval: TimeInterval = 10 * 60
    private let totalMemory = ProcessInfo.processInfo.physicalMemory

    private let alertMonitor = AlertMonitor()
    private let notifier = AlertNotifier()
    private let alertsEnabled = true            // no Settings UI yet; default on

    init() {
        LoginItem.registerOnce()
        notifier.requestAuthorization()
        Keys.legacy.forEach(UserDefaults.standard.removeObject(forKey:))
        sample(at: Date())   // just stores the first baseline; history starts at the next sample
        readSlowSensors()    // so even the first open has battery + temperature on frame one
        observePowerSource()
        startIdleSampler()
    }

    func setVisibility(_ newValue: MacStatsCore.Visibility) {
        guard newValue != visibility else { return }
        visibility = newValue
        switch newValue {
        case .popoverOpen:
            stopIdleSampler()
            reliefTimer?.invalidate()
            reliefTimer = nil
            // Force the slow tiers on this first tick, and run it synchronously so every value
            // is real before the first frame (rates diff against the idle sampler's snapshots).
            lastTempRead = nil
            lastBatteryRead = nil
            tick()
            refreshTrashSize()
        case .idle:
            timer?.invalidate()
            timer = nil
            exitBreakdown()   // stop per-process scanning + clear nav state
            startIdleSampler()
            scheduleMemoryRelief()
        }
    }

    private func scheduleNextTick() {
        timer?.invalidate()
        timer = makeTimer(after: refreshInterval(for: .popoverOpen),
                          tolerance: refreshTolerance(for: .popoverOpen)) { $0.tick() }
    }

    private func tick() {
        // A one-shot timer fired after `setVisibility(.idle)` could still be in flight;
        // bail rather than collect or reschedule.
        guard visibility == .popoverOpen else { return }
        let now = Date()
        sample(at: now)
        if isDue(last: lastTempRead, now: now, every: temperatureInterval) {
            store.setCPUTemperature(thermal.read())
            lastTempRead = now
        }
        if isDue(last: lastBatteryRead, now: now, every: batteryInterval) {
            refreshBattery()
            lastBatteryRead = now
        }
        scheduleNextTick()
    }

    /// The cheap every-tick read (CPU ticks, net counters, VM stats — microseconds): computes
    /// rates over the trailing window, records latest values + history, and feeds alerts.
    /// Only stores a baseline when there's no earlier snapshot to diff against.
    private func sample(at now: Date) {
        snapshots.append(Snapshot(time: now, cpu: readCPUTicks(), net: readNetCounters()))
        let base = rateBaselineIndex(times: snapshots.lazy.map { $0.time.timeIntervalSinceReferenceDate },
                                     now: now.timeIntervalSinceReferenceDate, window: rateWindowSeconds)
        if base > 0 { snapshots.removeFirst(base) }
        guard snapshots.count > 1, let current = snapshots.last else { return }
        let baseline = snapshots[0]

        let cpu = cpuBusyPercent(previous: baseline.cpu, current: current.cpu)
        let net = networkThroughput(previous: baseline.net, current: current.net,
                                    secondsElapsed: now.timeIntervalSince(baseline.time))
        let mem = memorySample(raw: readVMRaw(), totalBytes: totalMemory,
                               pressureLevel: readMemoryPressureLevel())
        store.record(cpuPercent: cpu, memory: mem, network: net,
                     time: now.timeIntervalSinceReferenceDate)
        fireAlerts(cpu: cpu, pressure: mem.pressure, at: now)
    }

    /// Called when the pointer hovers the menu-bar item, just before a likely click: take an
    /// idle-style sample now so the popover opens on current numbers. Rate-limited, and a
    /// no-op while open (the open tick is already live).
    func prewarm() {
        guard visibility == .idle else { return }
        let now = Date()
        if let last = snapshots.last?.time, now.timeIntervalSince(last) < prewarmMinInterval { return }
        sample(at: now)
        readSlowSensors()
    }

    /// Battery + temperature aren't sampled while closed, so refresh them ahead of an open
    /// (launch, hover); otherwise the first frame would show placeholders that then roll in.
    private func readSlowSensors() {
        refreshBattery()
        store.setCPUTemperature(thermal.read())
    }

    /// Reads the power source (state, %, macOS times) and the gauge (power, charge left),
    /// feeds each new gauge reading (every ~20–85 s while awake) to the estimators, and
    /// publishes their time left / time to full in place of macOS's jumpy ones. ~0.1 ms, so it
    /// also runs in the closed-popover sampler, keeping the estimate's history continuous.
    private func refreshBattery() {
        guard var sample = readBattery() else {
            store.setBattery(nil)
            store.setBatteryTelemetry(nil, averageWatts: nil)
            return
        }
        let state = sample.state
        let previousState = lastBatteryState
        if state != lastBatteryState {
            // Plug/unplug: never measure across it; a new session (or charge) starts.
            lastTelemetry = nil
            lastBatteryState = state
            estimator.endSession()
            chargeCurrent.reset()
            saveEstimator()
        }

        var telemetry = smartBattery.read()
        if let telemetry, telemetry.updateTime != lastTelemetry?.updateTime {
            nominalPeakMAh = telemetry.nominalMAh.map { nominalPeak.add($0) }
            // Only awake intervals count: one that spans sleep would average the sleep.
            let seconds = lastTelemetry.flatMap { gaugeInterval(from: $0, to: telemetry) }
            if state == .discharging, let seconds, let watts = averageWatts(from: lastTelemetry, to: telemetry) {
                estimator.ingest(watts: watts, seconds: seconds)
            }
            if state == .charging, let mA = telemetry.amperageMA {
                chargeCurrent.ingest(milliamps: mA, seconds: seconds ?? 0)   // the first reading seeds
            }
            lastTelemetry = telemetry
            if state == .discharging,
               lastEstimatorSave.map({ Date().timeIntervalSince($0) >= estimatorSaveInterval }) ?? true {
                saveEstimator()
            }
        }

        let limit = chargeLimit(for: sample, previousState: previousState)
        switch state {
        case .discharging:
            if let wh = telemetry?.remainingWh {
                sample.timeToEmptyMinutes = estimator.minutesLeft(remainingWh: wh,
                                                                  macOSMinutes: sample.timeToEmptyMinutes)
            }
        case .charging:
            let limit = limit.flatMap { $0 > sample.percent ? $0 : nil }   // still charging past it ⇒ not a limit
            sample.chargeLimitPercent = limit
            if let raw = telemetry?.currentMAh, let max = telemetry?.rawMaxMAh, let mA = chargeCurrent.milliamps,
               let minutes = minutesToTarget(currentMAh: raw, maxMAh: max, chargeMA: mA,
                                             targetPercent: limit ?? 100) {
                sample.timeToFullMinutes = minutes
            } else if limit != nil {
                sample.timeToFullMinutes = nil   // macOS's figure is to 100 %, not to the limit
            }
        case .charged, .notCharging:
            sample.chargeLimitPercent = limit
        }
        if let peak = nominalPeakMAh { telemetry?.nominalMAh = peak }
        store.setBattery(sample)
        store.setBatteryTelemetry(telemetry, averageWatts: state == .discharging ? estimator.sessionAverageWatts : nil)
    }

    /// The percent charging stops at (below 100), or nil. powerd's policy file is re-read only
    /// when the percent or state changes. Only an active policy in it counts: the file was
    /// seen with an empty policy list while unplugged on a Mac that holds at 85 % on AC, and
    /// it isn't known to be filled in at plug-in, so otherwise the level where charging was
    /// last seen to stop is used (forgotten once charging goes past it).
    private func chargeLimit(for sample: BatterySample, previousState: BatteryState?) -> Int? {
        let learned = learnedChargeLimit(previous: learnedLimit, previousState: previousState,
                                         state: sample.state, percent: sample.percent)
        if learned != learnedLimit {
            learnedLimit = learned
            UserDefaults.standard.set(learned, forKey: Keys.chargeLimit)
        }
        guard sample.state.isPluggedIn else { return nil }
        if powerdLimitReadFor?.percent != sample.percent || powerdLimitReadFor?.state != sample.state {
            powerdLimit = readPowerdChargeLimit()
            powerdLimitReadFor = sample
        }
        switch powerdLimit {
        case .limit(let percent): return percent
        case .noLimit, .unknown: return learnedLimit
        }
    }

    private func saveEstimator() {
        lastEstimatorSave = Date()
        guard let typical = estimator.typicalWatts else { return }
        UserDefaults.standard.set(typical, forKey: Keys.typicalWatts)
        UserDefaults.standard.set(estimator.typicalSeconds, forKey: Keys.typicalSeconds)
    }

    /// Re-reads the battery the moment macOS reports a power-source change (plug/unplug,
    /// a percent step), open or closed, instead of waiting for the next timed read.
    private func observePowerSource() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let model = Unmanaged<AppModel>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { model.refreshBattery() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSourceObserver = source   // AppModel lives as long as the app; never removed
    }

    func enterBreakdown(_ metric: MacStatsCore.BreakdownMetric) {
        store.beginBreakdown(metric: metric)
        scanner = BreakdownScanner()
        procScanTick()   // first scan establishes the CPU baseline (CPU stays "measuring")
        // Second scan soon after, so CPU leaves "Measuring…" quickly; then the steady cadence.
        procTimer?.invalidate()
        procTimer = makeTimer(after: breakdownFirstRescanDelay, tolerance: 0.03) { model in
            model.procScanTick()
            model.procTimer = model.makeTimer(after: breakdownScanInterval, tolerance: 0.1,
                                              repeats: true) { $0.procScanTick() }
        }
    }

    func exitBreakdown() {
        procTimer?.invalidate()
        procTimer = nil
        scanner = nil
        store.clearBreakdown()
    }

    /// Confirms, then empties the Trash. The confirmation and any error are shown with
    /// AppKit `NSAlert`, not SwiftUI's `.confirmationDialog`/`.alert`: those can't be
    /// presented from inside a `MenuBarExtra(.window)` panel — interacting with them shifts
    /// focus, which dismisses the whole menu-bar panel before the action can run. `NSAlert`
    /// runs its own modal window, independent of the panel.
    func confirmAndEmptyTrash() {
        let confirm = NSAlert()
        confirm.messageText = "Empty the Trash?"
        confirm.informativeText = "Items in the Trash will be permanently deleted."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Empty Trash")
        confirm.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let message = TrashActions.emptyTrash()
            let bytes = TrashActions.trashSize()   // reflect the new (usually empty) Trash
            Task { @MainActor in
                self.store.setTrashBytes(bytes)
                if let message { self.presentTrashError(message) }
            }
        }
    }

    private func presentTrashError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't empty the Trash"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Reads the Trash size via Finder off the main thread and publishes it. Run on popover
    /// open and after an Empty — not on the 1s tick, since Finder Apple Events are too heavy
    /// to issue every second.
    private func refreshTrashSize() {
        DispatchQueue.global(qos: .utility).async {
            let bytes = TrashActions.trashSize()
            Task { @MainActor in self.store.setTrashBytes(bytes) }
        }
    }

    /// Background sampler while the popover is closed: CPU%, memory and network every ~10s
    /// plus the battery (no per-app scan, no temperature). Feeds alerts, keeps the history
    /// warm, and keeps the battery estimate learning while the popover is closed.
    private func startIdleSampler() {
        idleTimer?.invalidate()
        idleTimer = makeTimer(after: refreshInterval(for: .idle), tolerance: refreshTolerance(for: .idle),
                              repeats: true) { model in
            model.sample(at: Date())
            model.refreshBattery()
        }
    }

    private func stopIdleSampler() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    /// After the popover closes SwiftUI frees the view's memory, but malloc keeps those pages
    /// for reuse (measured: ~24MB held that way). Once teardown has settled, hand them back.
    private func scheduleMemoryRelief() {
        reliefTimer?.invalidate()
        reliefTimer = makeTimer(after: 1.5, tolerance: 0.5) { model in
            model.reliefTimer = nil
            guard model.visibility == .idle else { return }
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    /// A main-run-loop timer with coalescing tolerance. `.common` mode so it keeps firing while
    /// a scroll view is tracking (default-mode timers pause then). Timers on the main run loop
    /// fire on the main thread, hence `assumeIsolated` instead of allocating a `Task` per tick.
    private func makeTimer(after interval: TimeInterval, tolerance: TimeInterval, repeats: Bool = false,
                           _ action: @escaping @MainActor (AppModel) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Feeds the monitor and posts whatever it returns. Shared by every sample (idle, prewarm,
    /// open), so alerts fire regardless of visibility. The monitor is time-based, so the
    /// irregular cadence doesn't change when an alert fires.
    private func fireAlerts(cpu: Double, pressure: MemoryPressure, at time: Date) {
        guard alertsEnabled else { return }
        let alerts = alertMonitor.ingest(AlertSample(cpuPercent: cpu, pressure: pressure, time: time))
        for alert in alerts { notifier.post(alert) }
    }

    private func procScanTick() {
        guard let metric = store.activeBreakdownMetric, let scanner else { return }
        // Clocks first, then the processes, so the CPU header and the rows cover one interval.
        let time = Date().timeIntervalSinceReferenceDate
        let absTime = mach_absolute_time()
        let ticks = readCPUTicks()
        let raw = readRawProcesses(includeEnergy: metric == .energy)

        // GUI apps the user is running = the grouping anchors. Processes no app is responsible
        // for land in "Other processes", so the rows cover all of the user's processes.
        let appPIDs = Set(NSWorkspace.shared.runningApplications.compactMap { app -> Int32? in
            app.processIdentifier > 0 ? Int32(app.processIdentifier) : nil
        })
        let result = scanner.scan(raw, appPIDs: appPIDs, metric: metric, time: time,
                                  absTime: absTime, cpuTicks: ticks)
        // CPU and energy have no real values until the second scan ("Measuring…" until then).
        store.setBreakdown(result.apps, measuring: result.measuring, totalCPU: result.totalCPUPercent)
    }
}

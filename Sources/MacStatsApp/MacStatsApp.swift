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
    /// The welcome card, guided tour and their persistence (`TourController`).
    private(set) lazy var tour = TourController(hasBattery: { [store] in store.battery != nil })

    private var timer: Timer?                    // open-popover tick (one-shot, rescheduled)
    private var idleTimer: Timer?                // closed-popover sampler (repeating)
    private var reliefTimer: Timer?              // returns freed memory to the OS after close
    private var visibility: MacStatsCore.Visibility = .idle
    /// Open = SwiftUI showed the panel's content (`onAppear`, not yet `onDisappear`) AND its
    /// window is on screen. `MenuBarExtra` can take the window off screen without `onDisappear`
    /// (seen live on v1.1.0: the 0.5 s tick and the sparkline slides kept running at ~28 % of a
    /// core with the panel ordered out for hours), so the window has the last word.
    private var panelAppeared = false
    private var panelWindowVisible = true
    /// The window is ordered in (`isVisible`), covered or not. A covered panel (screen locked, display
    /// asleep) pauses the timers but isn't a close: the breakdown and the tour stay where they are.
    private var panelWindowOrderedIn = true
    /// SwiftUI shows the content and the window is ordered in: the panel is open, maybe covered.
    private var panelShown = false
    private weak var panelWindow: NSWindow?

    /// Dedicated per-process scan loop — exists only while a breakdown is open, so the
    /// expensive enumeration never runs otherwise. Kept separate from the sparkline `tick`.
    private var procTimer: Timer?
    /// Attribution caches + the previous scan, for the open breakdown only (nil otherwise).
    /// Used only on `scanQueue`.
    private var scanSession: BreakdownScanSession?
    /// Breakdown scans run here, one at a time, off the main thread (see `procScanTick`).
    private let scanQueue = DispatchQueue(label: "MacStats.breakdownScan", qos: .userInitiated)
    /// Counts drill-ins, so a scan that finishes after its breakdown closed is dropped.
    private var scanGeneration = 0
    /// The generation whose scan is running on `scanQueue`, so a slow scan is skipped, not queued.
    private var scanInFlight: Int?

    /// Cumulative-counter snapshots, oldest→newest, covering ~`rateWindowSeconds` (just the
    /// last two while idle). Rates diff against the snapshot ~2s back (see `rateBaselineIndex`)
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
    private var chargeLimits = ChargeLimitResolver(
        remembered: UserDefaults.standard.object(forKey: Keys.powerdChargeLimit) as? Int,
        rememberedAt: UserDefaults.standard.object(forKey: Keys.powerdChargeLimitDate) as? Date,
        observed: UserDefaults.standard.object(forKey: Keys.chargeLimit) as? Int)
    private var savedRememberedLimit = UserDefaults.standard.object(forKey: Keys.powerdChargeLimit) as? Int
    private var savedRememberedAt = UserDefaults.standard.object(forKey: Keys.powerdChargeLimitDate) as? Date
        ?? .distantPast
    private var pluggedInSince: Date?                   // nil: plugged in when MacStats launched
    private var powerdPolicy = PowerdChargePolicy(limit: .unknown)
    private var powerdLimitReadFor: BatterySample?      // the reading it was last read for
    private var lastTelemetry: BatteryTelemetry?
    /// Whole-Mac draw over the last gauge interval (the drill-in's "Power"), W.
    private var lastIntervalWatts: Double?
    /// The on-battery session began at an unplug MacStats saw (else at launch).
    private var sessionStartedAtUnplug = false
    /// Health shows the peak full-charge capacity of the last ~10 gauge readings (it flickers),
    /// carried over from the last launch so the first reading alone doesn't set it.
    private var nominalPeak = RecentMax(
        capacity: 10, values: UserDefaults.standard.array(forKey: Keys.nominalRecent) as? [Int] ?? [])
    private var nominalPeakMAh: Int?
    private var savedNominalValues: [Int] = []
    /// macOS's own "Maximum Capacity" (System Settings' health figure), read off the main
    /// thread at launch and then hourly; health falls back to the gauge peak until it's known.
    private var macOSHealthPercent: Int?
    private var lastHealthRead: Date?
    private let healthReadInterval: TimeInterval = 60 * 60
    private var lastBatteryState: BatteryState?
    private var lastEstimatorSave: Date?
    /// `typicalSeconds` as last written (or loaded), so unchanged values aren't rewritten.
    private var savedTypicalSeconds = UserDefaults.standard.double(forKey: Keys.typicalSeconds)
    private var terminationSource: DispatchSourceSignal?
    private var powerSourceObserver: CFRunLoopSource?
    private enum Keys {
        static let typicalWatts = "batteryDrainTypicalWatts"
        static let typicalSeconds = "batteryDrainTypicalSeconds"
        static let chargeLimit = "batteryLearnedChargeLimit"
        /// powerd's last believed charge limit (100 = none) and when it said so.
        static let powerdChargeLimit = "batteryPowerdChargeLimit"
        static let powerdChargeLimitDate = "batteryPowerdChargeLimitDate"
        static let nominalRecent = "batteryNominalCapacityRecent"
        /// Before 2026-10-05: a "typical" learned from plugged-in and across-sleep readings
        /// (2.5 W on a Mac that drains 5.5 W). Dropped, not migrated.
        static let legacy = ["batteryTypicalWatts", "batteryTypicalSeconds"]
    }
    /// The typical-drain average is saved at its first on-battery gauge update (~1 min after
    /// launch or unplug), then at most this often, and on plug/unplug and quit.
    private let estimatorSaveInterval: TimeInterval = 10 * 60
    private let totalMemory = ProcessInfo.processInfo.physicalMemory

    private let alertMonitor = AlertMonitor()
    private let notifier = AlertNotifier()
    private let alertsEnabled = true            // no Settings UI yet; default on

    init() {
        LoginItem.registerOnce()
        if tour.defersPermissionPrompts {
            // A new user: the welcome card explains both prompts first, then they fire.
            tour.onIntroFinished = { [weak self] in
                self?.notifier.requestAuthorization()
                self?.refreshTrashSize()
            }
        } else {
            notifier.requestAuthorization()
        }
        Keys.legacy.forEach(UserDefaults.standard.removeObject(forKey:))
        store.pausePublishing()   // closed: record without re-rendering (see setVisibility)
        sample(at: Date())   // just stores the first baseline; history starts at the next sample
        readSlowSensors()    // so even the first open has battery + temperature on frame one
        observePowerSource()
        saveEstimatorOnQuit()
        startIdleSampler()
    }

    /// SwiftUI showed (true) or hid (false) the panel's content. Showing counts the window as on
    /// screen too, so the first tick runs before the first frame, as before.
    func setPanelAppeared(_ appeared: Bool) {
        panelAppeared = appeared
        if appeared { panelWindowVisible = true; panelWindowOrderedIn = true }
        updateVisibility()
    }

    /// The panel's window (`PanelWindowObserver`) was shown, hidden or covered: re-read it.
    func panelWindowChanged(_ window: NSWindow) {
        panelWindow = window
        panelWindowVisible = Self.isOnScreen(window)
        panelWindowOrderedIn = window.isVisible
        updateVisibility()
    }

    private static func isOnScreen(_ window: NSWindow) -> Bool {
        window.isVisible && window.occlusionState.contains(.visible)
    }

    private func updateVisibility() {
        let shown = panelAppeared && panelWindowOrderedIn
        if shown != panelShown {
            panelShown = shown
            if shown {
                tour.panelOpened()
            } else {
                tour.panelClosed()
                exitBreakdown()   // stop per-process scanning + clear nav state
            }
        }
        setVisibility(shown && panelWindowVisible ? .popoverOpen : .idle)
    }

    private func setVisibility(_ newValue: MacStatsCore.Visibility) {
        guard newValue != visibility else { return }
        visibility = newValue
        switch newValue {
        case .popoverOpen:
            stopIdleSampler()
            reliefTimer?.invalidate()
            reliefTimer = nil
            // Publish what the closed sampler recorded, then force the slow tiers on this first
            // tick and run it synchronously, so every value is real before the first frame
            // (rates diff against the idle sampler's snapshots).
            store.resumePublishing()
            lastTempRead = nil
            lastBatteryRead = nil
            tick()
            if !tour.defersPermissionPrompts { refreshTrashSize() }   // Finder asks on the first read
            // Uncovered again with a breakdown still open: scan afresh (the old window spans the gap).
            if procTimer == nil, let metric = store.activeBreakdownMetric { enterBreakdown(metric) }
        case .idle:
            timer?.invalidate()
            timer = nil
            procTimer?.invalidate()   // a covered panel keeps its breakdown, without scanning
            procTimer = nil
            // MenuBarExtra keeps the closed popover's views alive, so a published sample
            // re-renders them (~0.7–1.3 % of a core): record without publishing until reopened.
            store.pausePublishing()
            startIdleSampler()
            scheduleMemoryRelief()
        }
    }

    private func scheduleNextTick() {
        timer?.invalidate()
        timer = makeTimer(after: refreshInterval(for: .popoverOpen),
                          tolerance: refreshTolerance(for: .popoverOpen)) { model in
            // Belt and braces for a hide no notification reported: never tick an unseen panel.
            if let window = model.panelWindow, !Self.isOnScreen(window) {
                model.panelWindowChanged(window)
                return
            }
            model.tick()
        }
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
            store.setBatteryTelemetry(nil, powerWatts: nil, averageWatts: nil)
            return
        }
        let state = sample.state
        let previousState = lastBatteryState
        if state != lastBatteryState {
            // Plug/unplug: never measure across it; a new session (or charge) starts.
            lastTelemetry = nil
            lastIntervalWatts = nil
            sessionStartedAtUnplug = previousState != nil   // else MacStats just launched
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
            lastIntervalWatts = intervalWatts(from: lastTelemetry, to: telemetry)
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

        let target = chargeTarget(for: sample, previousState: previousState)
        let stop = chargeStop(end: target, hold: powerdPolicy.hold, state: state, percent: sample.percent)
        sample.chargeLimitPercent = stop.limit
        sample.chargeHoldPercent = stop.hold
        sample.chargeTargetAssumed = stop.assumed   // labelled "to 100%", not "to full"
        switch state {
        case .discharging:
            if let wh = telemetry?.remainingWh {
                sample.timeToEmptyMinutes = estimator.minutesLeft(remainingWh: wh,
                                                                  macOSMinutes: sample.timeToEmptyMinutes)
            }
        case .charging:
            // At the limit (shown 85 % at raw 84.0 %) charging stops within the minute: no
            // estimate ("Almost done").
            if let raw = telemetry?.currentMAh, let max = telemetry?.rawMaxMAh, let mA = chargeCurrent.milliamps,
               let minutes = minutesToTarget(currentMAh: raw, maxMAh: max, chargeMA: mA,
                                             targetPercent: stop.targetPercent) {
                sample.timeToFullMinutes = minutes
            } else if stop.targetPercent < 100 || chargeCurrent.milliamps != nil {
                // macOS's figure is to 100 %, not to the limit; with a measured current, nil
                // here means the last trickle ("Almost full" from 90 %) or too little current.
                sample.timeToFullMinutes = nil
            }
        case .charged, .notCharging:
            break
        }
        if let peak = nominalPeakMAh { telemetry?.nominalMAh = peak }
        if telemetry != nil { readMacOSHealthIfDue() }
        telemetry?.reportedHealthPercent = macOSHealthPercent
        store.setBattery(sample)
        store.setBatteryTelemetry(telemetry, powerWatts: lastIntervalWatts,
                                  averageWatts: state == .discharging ? estimator.sessionAverageWatts : nil,
                                  averageSinceUnplug: sessionStartedAtUnplug)
    }

    /// Starts a background read of macOS's "Maximum Capacity" when the last one is an hour old;
    /// the next battery refresh shows it.
    private func readMacOSHealthIfDue() {
        let now = Date()
        if let last = lastHealthRead, now.timeIntervalSince(last) < healthReadInterval { return }
        lastHealthRead = now
        DispatchQueue.global(qos: .utility).async {
            let percent = readMaximumCapacityPercent()
            DispatchQueue.main.async { [weak self] in
                if let percent { self?.macOSHealthPercent = percent }
            }
        }
    }

    /// Where charging stops (`ChargeLimitResolver`), nil on battery. powerd's policy file
    /// (filled in within ~20 s of plug-in) is re-read when the percent or state changes, and on
    /// every refresh for the first two minutes after plug-in. What it said is remembered across
    /// launches, as is where charging was last seen to stop (the fallback without the file).
    private func chargeTarget(for sample: BatterySample, previousState: BatteryState?) -> ChargeTarget? {
        let now = Date()
        guard sample.state.isPluggedIn else { return nil }
        if previousState == .discharging { pluggedInSince = now }
        let pluggedInFor = now.timeIntervalSince(pluggedInSince ?? .distantPast)
        if powerdLimitReadFor?.percent != sample.percent || powerdLimitReadFor?.state != sample.state
            || pluggedInFor < 2 * ChargeLimitResolver.powerdSettleSeconds {
            powerdPolicy = readPowerdChargePolicy()
            powerdLimitReadFor = sample
        }
        // Learned only plugged in (on battery it never changes); a stop at powerd's hold isn't a limit.
        let observed = learnedChargeLimit(previous: chargeLimits.observed, previousState: previousState,
                                          state: sample.state, percent: sample.percent, hold: powerdPolicy.hold)
        if observed != chargeLimits.observed {
            chargeLimits.observed = observed
            UserDefaults.standard.set(observed, forKey: Keys.chargeLimit)
        }
        let target = chargeLimits.resolve(powerd: powerdPolicy.limit, pluggedInFor: pluggedInFor, now: now)
        if let remembered = chargeLimits.remembered, let at = chargeLimits.rememberedAt,
           remembered != savedRememberedLimit || at.timeIntervalSince(savedRememberedAt) > 24 * 3600 {
            UserDefaults.standard.set(remembered, forKey: Keys.powerdChargeLimit)
            UserDefaults.standard.set(at, forKey: Keys.powerdChargeLimitDate)
            savedRememberedLimit = remembered
            savedRememberedAt = at
        }
        return target
    }

    /// Writes the recent full-charge readings (health) when they changed, and the typical drain
    /// if it learned anything since the last write. Only a real write of the drain starts the
    /// next save interval: the launch-time call used to start it with nothing to save, so the
    /// first save came ~10 min in and a relaunch before that lost what was learned.
    private func saveEstimator() {
        if nominalPeak.values != savedNominalValues {
            UserDefaults.standard.set(nominalPeak.values, forKey: Keys.nominalRecent)
            savedNominalValues = nominalPeak.values
        }
        guard let typical = estimator.typicalWatts, estimator.typicalSeconds != savedTypicalSeconds else { return }
        UserDefaults.standard.set(typical, forKey: Keys.typicalWatts)
        UserDefaults.standard.set(estimator.typicalSeconds, forKey: Keys.typicalSeconds)
        savedTypicalSeconds = estimator.typicalSeconds
        lastEstimatorSave = Date()
    }

    /// Saves the learned drain when MacStats quits: the Quit button and logout post
    /// `willTerminateNotification`; `pkill` (how `install.sh` and `bundle.sh` stop the running
    /// copy for an update) sends SIGTERM, which would otherwise end the process without it.
    private func saveEstimatorOnQuit() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveEstimator() }
        }
        signal(SIGTERM, SIG_IGN)   // handled by the dispatch source instead of killing at once
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.saveEstimator() }
            exit(0)
        }
        source.resume()
        terminationSource = source
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
        scanSession = BreakdownScanSession()
        scanGeneration &+= 1
        procScanTick(waitForResult: true)   // first scan: the CPU baseline (CPU stays "measuring")
        procTimer?.invalidate()
        procTimer = makeTimer(after: breakdownScanInterval, tolerance: 0.1, repeats: true) { $0.procScanTick() }
    }

    func exitBreakdown() {
        procTimer?.invalidate()
        procTimer = nil
        scanSession = nil
        scanGeneration &+= 1
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
            let reading = TrashActions.trashSize()   // reflect the new (usually empty) Trash
            Task { @MainActor in
                self.publishTrash(reading)
                if let message { self.presentTrashError(message) }
            }
        }
    }

    private func presentTrashError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn\u{2019}t empty the Trash"
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
            let reading = TrashActions.trashSize()
            Task { @MainActor in self.publishTrash(reading) }
        }
    }

    private func publishTrash(_ reading: TrashReading) {
        if case .bytes(let bytes) = reading { store.setTrashBytes(bytes) } else { store.setTrashBytes(nil) }
        store.setTrashNeedsPermission(reading == .notPermitted)
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

    /// One breakdown scan, run on `scanQueue` (the running-apps list, the process reads and the
    /// arithmetic: ~3–10 ms a second while drilled in), with the result published back on the
    /// main thread. `waitForResult` waits for it, so the first frame of a drill-in has its rows.
    private func procScanTick(waitForResult: Bool = false) {
        guard let metric = store.activeBreakdownMetric, let session = scanSession else { return }
        let id = scanGeneration
        guard scanInFlight != id else { return }   // the previous scan is still running: skip
        if waitForResult {
            let result = scanQueue.sync { session.scan(metric: metric) }
            store.setBreakdown(result.apps, measuring: result.measuring, totalCPU: result.totalCPUPercent)
            return
        }
        scanInFlight = id
        scanQueue.async { [weak self] in
            let result = session.scan(metric: metric)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.scanInFlight == id { self.scanInFlight = nil }
                    // Dropped if the breakdown closed (or another one opened) meanwhile.
                    guard self.scanGeneration == id, self.scanSession != nil else { return }
                    self.store.setBreakdown(result.apps, measuring: result.measuring,
                                            totalCPU: result.totalCPUPercent)
                }
            }
        }
    }
}

/// One open breakdown's scan state. Used only on `AppModel`'s serial scan queue, so it is
/// never touched by two threads at once (hence `@unchecked Sendable`).
///
/// Off the main thread because most of a scan is the running-apps list: reading
/// `NSRunningApplication` properties asks LaunchServices again after each main run-loop turn,
/// ~150 µs per app (9 ms for 60 apps here). `NSWorkspace.runningApplications` and
/// `NSRunningApplication` are documented as safe to read from background threads; the
/// properties used here (pid, bundle id and URL, activation policy) don't change while an app runs.
private final class BreakdownScanSession: @unchecked Sendable {
    private let scanner = BreakdownScanner()
    /// Running app pid → whether it has a bundle id (`bundleIdentifier` costs ~40 µs per app) and
    /// is one of macOS's own agents (`isMacOSAgent`), pruned to the running apps each scan.
    private var appTraits: [Int32: (hasBundleID: Bool, macOSAgent: Bool)] = [:]

    func scan(metric: MacStatsCore.BreakdownMetric) -> BreakdownScanner.Result {
        // GUI apps the user is running = the grouping anchors. Processes no app is responsible
        // for land in "Other processes", so the rows cover all of the user's processes.
        var traits: [Int32: (hasBundleID: Bool, macOSAgent: Bool)] = [:]
        let anchors = attributionAnchors(NSWorkspace.shared.runningApplications.map { app in
            let pid = Int32(app.processIdentifier)
            let policy = app.activationPolicy
            let known = appTraits[pid] ?? (app.bundleIdentifier != nil,
                                           isMacOSAgent(path: (app.bundleURL ?? app.executableURL)?.path,
                                                        isRegularApp: policy == .regular))
            traits[pid] = known
            return RunningAppInfo(pid: pid, hasBundleIdentifier: known.hasBundleID,
                                  isBackgroundOnly: policy == .prohibited, isMacOSAgent: known.macOSAgent)
        })
        appTraits = traits

        // Clocks first, then the processes, so the CPU header and the rows cover one interval.
        let time = Date().timeIntervalSinceReferenceDate
        let absTime = mach_absolute_time()
        let ticks = readCPUTicks()
        let raw = readRawProcesses(includeEnergy: metric == .energy)
        // CPU and energy have no real values until the second scan ("Measuring…" until then).
        return scanner.scan(raw, appPIDs: anchors.apps, fallbackAppPIDs: anchors.fallbacks,
                            metric: metric, time: time, absTime: absTime, cpuTicks: ticks)
    }
}

import AppKit
import SwiftUI
import MacStatsCore

/// Owns the store, the syscall pipeline, and the adaptive refresh timer.
@MainActor
final class AppModel: ObservableObject {
    let store = MetricsStore(historyCapacity: 60)

    private var timer: Timer?
    private var visibility: MacStatsCore.Visibility = .idle
    private var samplesSinceOpen = 0

    /// Dedicated per-process scan loop — exists only while a breakdown is open, so the
    /// expensive enumeration never runs otherwise. Kept separate from the sparkline `tick`.
    private var procTimer: Timer?
    private var previousProcCPU: [Int32: UInt64] = [:]   // pid → last cumulative CPU ns
    private var lastProcScan: Date?

    /// Cumulative-counter snapshots, oldest→newest, covering ~`rateWindowSeconds`. Rates are
    /// diffed against the snapshot ~1s back (see `rateBaselineIndex`) so they stay a stable
    /// trailing average and the fast opening fill doesn't inflate them.
    private var snapshots: [Snapshot] = []
    private struct Snapshot {
        let time: Date
        let cpu: CPUTicks
        let net: NetCounters
    }

    private let alertMonitor = AlertMonitor()
    private let notifier = AlertNotifier()
    private let alertsEnabled = true            // no Settings UI yet; default on
    private var alertTimer: Timer?
    private var alertBaselineCPU: CPUTicks?      // baseline for the slow idle CPU sample

    init() {
        LoginItem.registerOnce()
        notifier.requestAuthorization()
        startAlertSampler()
    }

    func setVisibility(_ newValue: MacStatsCore.Visibility) {
        guard newValue != visibility else { return }
        visibility = newValue
        switch newValue {
        case .popoverOpen:
            stopAlertSampler()
            // Seed the trailing-window baseline now so rates measure from when the popover
            // opened, not from however long it sat closed. Then start the fill from sample 0.
            samplesSinceOpen = 0
            snapshots = [Snapshot(time: Date(), cpu: readCPUTicks(), net: readNetCounters())]
            scheduleNextTick()
            refreshTrashSize()
        case .idle:
            timer?.invalidate()
            timer = nil
            exitBreakdown()   // stop per-process scanning + clear nav state
            store.reset() // each open session starts with a fresh sparkline
            startAlertSampler()
        }
    }

    /// Schedules the next sample as a one-shot timer. The interval is short during the
    /// opening burst (fills the sparkline with real data fast) and settles to the steady
    /// cadence afterward — see `openPhaseInterval`.
    private func scheduleNextTick() {
        timer?.invalidate()
        let interval = openPhaseInterval(samplesSinceOpen: samplesSinceOpen)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        // A one-shot timer fired after `setVisibility(.idle)` could still be in flight;
        // bail rather than collect or reschedule.
        guard visibility == .popoverOpen else { return }

        let now = Date()
        let curCPU = readCPUTicks()
        let curNet = readNetCounters()
        snapshots.append(Snapshot(time: now, cpu: curCPU, net: curNet))

        // Diff against the snapshot ~`rateWindowSeconds` back so rates are a stable trailing
        // average independent of the (ramping) sample cadence; drop anything older than that.
        let base = rateBaselineIndex(times: snapshots.map { $0.time.timeIntervalSinceReferenceDate },
                                     now: now.timeIntervalSinceReferenceDate, window: rateWindowSeconds)
        if base > 0 { snapshots.removeFirst(base) }
        let baseline = snapshots[0]

        let cpu = cpuBusyPercent(previous: baseline.cpu, current: curCPU)
        let net = networkThroughput(previous: baseline.net, current: curNet,
                                    secondsElapsed: now.timeIntervalSince(baseline.time))
        let mem = memorySample(raw: readVMRaw(),
                               totalBytes: ProcessInfo.processInfo.physicalMemory,
                               pressureLevel: readMemoryPressureLevel())
        let bat = readBattery()

        let temp = cpuTemperature(from: readAppleThermalSensors())
        store.update(cpuPercent: cpu, memory: mem, network: net, battery: bat,
                     cpuTemp: temp)
        fireAlerts(cpu: cpu, pressure: mem.pressure)

        samplesSinceOpen += 1
        scheduleNextTick()
    }

    func enterBreakdown(_ metric: MacStatsCore.BreakdownMetric) {
        store.beginBreakdown(metric: metric)
        previousProcCPU = [:]
        lastProcScan = nil
        procScanTick()   // first scan establishes the CPU baseline (CPU stays "measuring")
        procTimer?.invalidate()
        procTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.procScanTick() }
        }
    }

    func exitBreakdown() {
        procTimer?.invalidate()
        procTimer = nil
        previousProcCPU = [:]
        lastProcScan = nil
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

    /// Slow background sampler: reads only system-wide CPU% + memory pressure (no per-app
    /// scan, no sparkline writes) and feeds the alert monitor. Runs while the popover is closed.
    private func startAlertSampler() {
        guard alertsEnabled else { return }
        alertTimer?.invalidate()
        alertBaselineCPU = readCPUTicks()
        alertTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval(for: .idle),
                                          repeats: true) { [weak self] _ in
            Task { @MainActor in self?.alertSampleTick() }
        }
    }

    private func stopAlertSampler() {
        alertTimer?.invalidate()
        alertTimer = nil
        alertBaselineCPU = nil
    }

    private func alertSampleTick() {
        let current = readCPUTicks()
        defer { alertBaselineCPU = current }
        guard let baseline = alertBaselineCPU else { return }   // need two samples
        let cpu = cpuBusyPercent(previous: baseline, current: current)
        let pressure = memoryPressure(fromLevel: readMemoryPressureLevel())
        fireAlerts(cpu: cpu, pressure: pressure)
    }

    /// Feeds the monitor and posts whatever it returns. Shared by the idle sampler and the
    /// open-popover tick, so alerts fire regardless of visibility.
    private func fireAlerts(cpu: Double, pressure: MemoryPressure) {
        guard alertsEnabled else { return }
        let alerts = alertMonitor.ingest(AlertSample(cpuPercent: cpu, pressure: pressure, time: Date()))
        for alert in alerts { notifier.post(alert) }
    }

    private func procScanTick() {
        guard let metric = store.activeBreakdownMetric else { return }
        let now = Date()
        let raw = readRawProcesses()

        // GUI apps the user is running = our "user apps only" universe + the grouping anchors.
        let appPIDs = Set(NSWorkspace.shared.runningApplications.compactMap { app -> Int32? in
            app.processIdentifier > 0 ? Int32(app.processIdentifier) : nil
        })
        let ppidMap = Dictionary(raw.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
        let cpuByPID = Dictionary(raw.map { ($0.pid, $0.cpuTimeNs) }, uniquingKeysWith: { a, _ in a })

        let haveBaseline = lastProcScan != nil
        let elapsed = lastProcScan.map { now.timeIntervalSince($0) } ?? 0

        var usages: [ProcessUsage] = []
        for p in raw {
            guard let appPID = owningAppPID(for: p.pid, ppid: ppidMap, appPIDs: appPIDs) else { continue }
            let cpu = haveBaseline
                ? processCPUPercent(previousCPUTimeNs: previousProcCPU[p.pid] ?? p.cpuTimeNs,
                                    currentCPUTimeNs: p.cpuTimeNs, elapsedSeconds: elapsed)
                : 0
            usages.append(ProcessUsage(pid: p.pid, appPID: appPID, cpuPercent: cpu, memoryBytes: p.memoryBytes))
        }

        previousProcCPU = cpuByPID
        lastProcScan = now

        // CPU has no real values until the second scan; keep showing "Measuring…" until then.
        let measuring = (metric == .cpu && !haveBaseline)
        store.setBreakdown(aggregate(usages, by: metric), measuring: measuring)
    }
}

@main
struct MacStatsApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            RootView(model: model, store: model.store)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

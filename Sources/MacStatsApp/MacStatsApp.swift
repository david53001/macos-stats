import SwiftUI
import MacStatsCore

/// Owns the store, the syscall pipeline, and the adaptive refresh timer.
@MainActor
final class AppModel: ObservableObject {
    let store = MetricsStore(historyCapacity: 60)

    private var timer: Timer?
    private var visibility: MacStatsCore.Visibility = .idle
    private var samplesSinceOpen = 0

    /// Cumulative-counter snapshots, oldest→newest, covering ~`rateWindowSeconds`. Rates are
    /// diffed against the snapshot ~1s back (see `rateBaselineIndex`) so they stay a stable
    /// trailing average and the fast opening fill doesn't inflate them.
    private var snapshots: [Snapshot] = []
    private struct Snapshot {
        let time: Date
        let cpu: CPUTicks
        let net: NetCounters
    }

    func setVisibility(_ newValue: MacStatsCore.Visibility) {
        guard newValue != visibility else { return }
        visibility = newValue
        switch newValue {
        case .popoverOpen:
            // Seed the trailing-window baseline now so rates measure from when the popover
            // opened, not from however long it sat closed. Then start the fill from sample 0.
            samplesSinceOpen = 0
            snapshots = [Snapshot(time: Date(), cpu: readCPUTicks(), net: readNetCounters())]
            scheduleNextTick()
        case .idle:
            timer?.invalidate()
            timer = nil
            store.reset() // each open session starts with a fresh sparkline
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
        let mem = memorySample(raw: readVMRaw(), totalBytes: ProcessInfo.processInfo.physicalMemory)
        let bat = readBattery()

        store.update(cpuPercent: cpu, memory: mem, network: net, battery: bat)

        samplesSinceOpen += 1
        scheduleNextTick()
    }
}

@main
struct MacStatsApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            OverviewView(store: model.store)
                .onAppear { model.setVisibility(.popoverOpen) }
                .onDisappear { model.setVisibility(.idle) }
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

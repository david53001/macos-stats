import SwiftUI
import MacStatsCore

/// Owns the store, the syscall pipeline, and the adaptive refresh timer.
@MainActor
final class AppModel: ObservableObject {
    let store = MetricsStore(historyCapacity: 60)

    private var timer: Timer?
    private var visibility: MacStatsCore.Visibility = .idle
    private var samplesSinceOpen = 0
    private var prevCPU = readCPUTicks()
    private var prevNet = readNetCounters()
    private var prevTime = Date()

    func setVisibility(_ newValue: MacStatsCore.Visibility) {
        guard newValue != visibility else { return }
        visibility = newValue
        switch newValue {
        case .popoverOpen:
            // Re-baseline now so the first sample is an accurate short-window delta rather
            // than an average over however long the popover sat closed. Then start the
            // priming burst from sample 0.
            samplesSinceOpen = 0
            prevCPU = readCPUTicks()
            prevNet = readNetCounters()
            prevTime = Date()
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
        let elapsed = now.timeIntervalSince(prevTime)
        let curCPU = readCPUTicks()
        let curNet = readNetCounters()

        let cpu = cpuBusyPercent(previous: prevCPU, current: curCPU)
        let net = networkThroughput(previous: prevNet, current: curNet, secondsElapsed: elapsed)
        let mem = memorySample(raw: readVMRaw(), totalBytes: ProcessInfo.processInfo.physicalMemory)
        let bat = readBattery()

        store.update(cpuPercent: cpu, memory: mem, network: net, battery: bat)
        prevCPU = curCPU
        prevNet = curNet
        prevTime = now

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

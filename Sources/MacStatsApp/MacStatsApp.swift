import SwiftUI
import MacStatsCore

/// Owns the store, the syscall pipeline, and the adaptive refresh timer.
@MainActor
final class AppModel: ObservableObject {
    let store = MetricsStore(historyCapacity: 60)

    private var timer: Timer?
    private var visibility: MacStatsCore.Visibility = .idle
    private var prevCPU = readCPUTicks()
    private var prevNet = readNetCounters()
    private var prevTime = Date()

    init() {
        tick()           // seed an immediate sample
        scheduleTimer()
    }

    func setVisibility(_ newValue: MacStatsCore.Visibility) {
        guard newValue != visibility else { return }
        visibility = newValue
        scheduleTimer()
        if newValue == .popoverOpen { tick() } // refresh right away on open
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = refreshInterval(for: visibility)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
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
            MenuBarLabel(store: model.store)
        }
        .menuBarExtraStyle(.window)
    }
}

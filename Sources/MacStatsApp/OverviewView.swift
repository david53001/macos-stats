import SwiftUI
import MacStatsCore

/// The popover content: header, a card per stat, footer.
struct OverviewView: View {
    @ObservedObject var store: MetricsStore
    /// Drill into a category's per-app breakdown. Only CPU & Memory pass this in.
    var onSelect: (BreakdownMetric) -> Void
    var onEmptyTrash: () -> Void

    @State private var showEmptyConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MacStats").font(.headline)
                Spacer()
                Text("every 1s").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 6)

            StatCard(label: "CPU",
                     value: "\(Int(store.cpuPercent.rounded()))%",
                     meta: cpuMeta,
                     color: .green,
                     history: store.cpuHistory,
                     maxValue: 100,
                     onTap: { onSelect(.cpu) })

            Divider()
            StatCard(label: "Memory",
                     value: memoryValue,
                     meta: memoryMeta,
                     color: .blue,
                     history: store.memHistory,
                     maxValue: 1.0,
                     onTap: { onSelect(.memory) })

            Divider()
            StatCard(label: "Network",
                     value: networkValue,
                     meta: networkMeta,
                     color: .purple,
                     history: store.netDownHistory,
                     maxValue: 0)

            Divider()
            StatCard(label: "Battery",
                     value: batteryValue,
                     meta: batteryMeta,
                     color: .yellow,
                     history: [],
                     maxValue: 1.0)

            Divider()
            HStack(spacing: 11) {
                Image(systemName: "trash")
                    .font(.callout).foregroundStyle(.secondary).frame(width: 24)
                Text("Trash").font(.callout)
                Spacer()
                Text(trashValue).font(.callout).fontWeight(.semibold).monospacedDigit()
                Button("Empty") { showEmptyConfirm = true }
                    .disabled((store.trashBytes ?? 0) == 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            HStack {
                Button("Quit") { NSApplication.shared.terminate(nil) }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
        .frame(width: 320)
        .confirmationDialog("Empty the Trash?", isPresented: $showEmptyConfirm, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { onEmptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items in the Trash will be permanently deleted.")
        }
        .alert("Couldn't empty the Trash",
               isPresented: Binding(get: { store.trashMessage != nil },
                                    set: { if !$0 { store.trashMessage = nil } })) {
            Button("OK", role: .cancel) { store.trashMessage = nil }
        } message: {
            Text(store.trashMessage ?? "")
        }
    }

    private func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }
    private func rate(_ bps: Double) -> String {
        bps >= 1_048_576 ? String(format: "%.1f MB/s", bps / 1_048_576)
                         : String(format: "%.0f KB/s", bps / 1024)
    }

    private var memoryValue: String {
        guard let m = store.memory else { return "—" }
        return "\(gb(m.usedBytes)) / \(gb(m.totalBytes)) GB"
    }
    private var trashValue: String {
        guard let bytes = store.trashBytes else { return "—" }   // still reading / unknown
        guard bytes > 0 else { return "empty" }
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
    private var cpuMeta: String {
        guard let t = store.cpuTempCelsius else { return "live" }
        return "\(Int(t))°C"
    }
    private var memoryMeta: String {
        switch store.memory?.pressure {
        case .normal: return "🟢 normal"
        case .warning: return "🟡 warning"
        case .critical: return "🔴 critical"
        case nil: return ""
        }
    }
    private var networkValue: String {
        guard let n = store.network else { return "—" }
        return "↓ \(rate(n.downBytesPerSec))"
    }
    private var networkMeta: String {
        guard let n = store.network else { return "" }
        return "↑ \(rate(n.upBytesPerSec))"
    }
    private var batteryValue: String {
        guard let b = store.battery else { return "—" }
        return "\(b.percent)%"
    }
    private var batteryMeta: String {
        guard let b = store.battery else { return "no battery" }
        if b.isCharging { return "charging" }
        if let t = b.timeToEmptyMinutes { return "\(t / 60)h \(t % 60)m left" }
        return "on battery"
    }
}

import SwiftUI
import MacStatsCore

/// The popover content: header, a card per stat, footer.
struct OverviewView: View {
    @ObservedObject var store: MetricsStore

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
                     meta: "live",
                     color: .green,
                     history: store.cpuHistory,
                     maxValue: 100)

            Divider()
            StatCard(label: "Memory",
                     value: memoryValue,
                     meta: memoryMeta,
                     color: .blue,
                     history: store.memHistory,
                     maxValue: 1.0)

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
            HStack {
                Button("Quit") { NSApplication.shared.terminate(nil) }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
        .frame(width: 320)
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

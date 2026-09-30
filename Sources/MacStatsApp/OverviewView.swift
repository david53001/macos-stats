import SwiftUI
import MacStatsCore

/// The popover content: header, an inset card per stat, the Trash card, footer.
struct OverviewView: View {
    @ObservedObject var store: MetricsStore
    /// Drill into a category's per-app breakdown. Only CPU & Memory pass this in.
    var onSelect: (BreakdownMetric) -> Void
    var onEmptyTrash: () -> Void
    var onSettings: () -> Void

    var body: some View {
        VStack(spacing: Design.cardSpacing) {
            PanelHeader { Text("MacStats") }

            StatCard(label: "CPU", value: "\(Int(store.cpuPercent.rounded()))%",
                     number: store.cpuPercent.rounded(), meta: cpuMeta,
                     onTap: { onSelect(.cpu) }) {
                Sparkline(points: store.cpuHistory, color: .green, maxValue: 100)
            }
            StatCard(label: "Memory", value: memoryValue,
                     number: Double(store.memory?.usedBytes ?? 0), meta: memoryMeta,
                     metaDot: pressureColor, onTap: { onSelect(.memory) }) {
                Sparkline(points: store.memHistory, color: .blue, maxValue: 1.0)
            }
            StatCard(label: "Network", value: networkValue,
                     number: store.network?.downBytesPerSec ?? 0, meta: networkMeta) {
                // Dynamic scale with a 10 KB/s floor, so an idle link draws flat.
                Sparkline(points: store.netDownHistory, color: .purple, maxValue: 0,
                          dynamicMinimum: 10_000)
            }
            StatCard(label: "Battery", value: batteryValue,
                     number: Double(store.battery?.percent ?? 0), meta: batteryMeta) {
                BatteryGauge(battery: store.battery)
            }

            trashCard
            PanelFooter { SettingsButton(action: onSettings) }
        }
        .padding([.horizontal, .bottom], Design.panelInset)
        .frame(width: Design.panelWidth, height: Design.panelHeight, alignment: .top)
    }

    private var trashCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .font(.callout).foregroundStyle(.secondary).frame(width: 18)
            Text("Trash").font(.callout)
            Spacer()
            Text(trashValue)
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Button("Empty") { onEmptyTrash() }
                .buttonStyle(SubtleButtonStyle())
                .disabled((store.trashBytes ?? 0) == 0)
        }
        .padding(.horizontal, Design.cardPadding)
        .padding(.vertical, 7)
        .background(CardBackground())
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
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        case nil: return ""
        }
    }
    /// Activity Monitor's memory-pressure colours.
    private var pressureColor: Color? {
        switch store.memory?.pressure {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        case nil: return nil
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

/// Horizontal battery level in the battery card's graph slot, like the level bar in the
/// macOS battery menu: green while charging, red at 20 % or below, otherwise the card's
/// yellow. Hidden (space kept) on Macs without a battery.
private struct BatteryGauge: View {
    let battery: BatterySample?

    var body: some View {
        let fraction = min(max(Double(battery?.percent ?? 0) / 100, 0), 1)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                if fraction > 0 {
                    Capsule().fill(tint)
                        .frame(width: max(geo.size.height, geo.size.width * fraction))
                }
            }
        }
        .frame(height: 8)
        .animation(.smooth(duration: 0.4), value: fraction)
        .opacity(battery == nil ? 0 : 1)
        .frame(height: 38)   // the same slot height as a sparkline
    }

    private var tint: Color {
        guard let battery else { return .yellow }
        if battery.isCharging { return .green }
        return battery.percent <= 20 ? .red : .yellow
    }
}

/// The title row shared by the overview and the breakdown, so both titles sit at the same
/// height and inset (aligned with the cards' content) and the push between them lines up.
struct PanelHeader<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .font(.headline)
            .padding(.horizontal, Design.cardPadding)
            .frame(maxWidth: .infinity, minHeight: Design.headerHeight,
                   maxHeight: Design.headerHeight, alignment: .bottomLeading)
    }
}

/// The bottom row shared by both screens: Quit on the left, optional trailing content.
struct PanelFooter<Trailing: View>: View {
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(SubtleButtonStyle())
            Spacer()
            trailing
        }
    }
}

extension PanelFooter where Trailing == EmptyView {
    init() { self.init { EmptyView() } }
}

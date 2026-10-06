import SwiftUI
import MacStatsCore

/// The popover content: header, an inset card per stat, the Trash card, footer.
struct OverviewView: View {
    @ObservedObject var store: MetricsStore
    /// Drill into a category's per-app breakdown (CPU, Memory, Battery).
    var onSelect: (BreakdownMetric) -> Void
    var onEmptyTrash: () -> Void
    var onSettings: () -> Void
    /// The existing-user "Take the Tour" chip (`TourController.offersTour`), passed in so this
    /// view never observes the tour.
    var offersTour = false
    var onTour: () -> Void = {}
    var onDismissOffer: () -> Void = {}

    var body: some View {
        VStack(spacing: Design.cardSpacing) {
            PanelHeader { Text("MacStats") }
                // On the title's baseline, as an overlay so the title never moves.
                .overlay(alignment: Alignment(horizontal: .trailing, vertical: .lastTextBaseline)) {
                    if offersTour {
                        TourOfferChip(onStart: onTour, onDismiss: onDismissOffer)
                            .padding(.trailing, Design.cardPadding)
                    }
                }

            // The cards read the store's held values (`cardCPUPercent`…), which change only when
            // a reading moves clearly; the graphs keep the exact history.
            StatCard(label: "CPU", value: "\(Int(store.cardCPUPercent.rounded()))%",
                     number: store.cardCPUPercent, meta: cpuMeta,
                     onTap: { onSelect(.cpu) }) {
                Sparkline(points: store.cpuHistory, color: .green, maxValue: 100)
            }
            .help(store.cpuTempCelsius == nil ? "Click to see which apps use the CPU"
                  : "Click to see which apps use the CPU \u{00B7} \u{00B0}C is its temperature")
            .tourAnchor("overview.cpu", radius: Design.cardCornerRadius)
            StatCard(label: "Memory", value: memoryValue,
                     number: Double(store.cardMemory?.usedBytes ?? 0), meta: memoryMeta,
                     metaDot: pressureColor, onTap: { onSelect(.memory) }) {
                Sparkline(points: store.memHistory, color: .blue, maxValue: 1.0)
            }
            .help("Click to see which apps use memory \u{00B7} The dot turns yellow when your Mac runs low, "
                  + "red when very low (macOS\u{2019}s memory pressure)")
            .tourAnchor("overview.memory", radius: Design.cardCornerRadius)
            StatCard(label: "Network", value: networkValue,
                     number: store.cardNetwork?.downBytesPerSec ?? 0, meta: networkMeta) {
                // Dynamic scale with a 10 KB/s floor, so an idle link draws flat.
                Sparkline(points: store.netDownHistory, color: .purple, maxValue: 0,
                          dynamicMinimum: 10_000)
            }
            .help("↓ download and ↑ upload speed, right now")
            .tourAnchor("overview.network", radius: Design.cardCornerRadius)
            StatCard(label: "Battery", value: batteryValue,
                     number: Double(store.battery?.percent ?? 0), meta: batteryMeta,
                     onTap: store.battery == nil ? nil : { onSelect(.energy) }) {
                BatteryGauge(battery: store.battery)
            }
            .tourAnchor("overview.battery", radius: Design.cardCornerRadius)

            trashCard
            PanelFooter {
                HStack(spacing: Design.cardSpacing) {
                    HelpButton(action: onTour)
                    SettingsButton(action: onSettings)
                }
                .tourAnchor("overview.footer", radius: Design.cardCornerRadius)
            }
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
            if store.trashNeedsPermission {
                // Finder access was refused: macOS won't ask again, so say where to allow it.
                Button("Allow\u{2026}") { TrashActions.openAutomationSettings() }
                    .buttonStyle(SubtleButtonStyle())
                    .help("Opens System Settings → Privacy & Security → Automation")
            } else {
                Button("Empty") { onEmptyTrash() }
                    .buttonStyle(SubtleButtonStyle())
                    .disabled((store.trashBytes ?? 0) == 0)
            }
        }
        .padding(.horizontal, Design.cardPadding)
        .padding(.vertical, 7)
        .background(CardBackground())
    }

    private func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }
    private func rate(_ bps: Double) -> String { formattedRate(bytesPerSecond: bps) }

    private var memoryValue: String {
        guard let m = store.cardMemory else { return "—" }
        return "\(gb(m.usedBytes)) / \(gb(m.totalBytes)) GB"
    }
    private var trashValue: String {
        if store.trashNeedsPermission { return "Needs permission" }
        guard let bytes = store.trashBytes else { return "—" }   // still reading / unknown
        guard bytes > 0 else { return "Nothing in it" }   // not "empty" beside the Empty button
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
    private var cpuMeta: String {
        guard let t = store.cpuTempCelsius else { return "" }   // no usable sensor on this chip
        return "\(Int(t)) °C"   // the Battery screen's format
    }
    /// macOS's memory pressure in plain words (the tooltip names the term).
    private var memoryMeta: String {
        switch store.cardMemory?.pressure {
        case .normal: return "OK"
        case .warning: return "running low"
        case .critical: return "very low"
        case nil: return ""
        }
    }
    /// Activity Monitor's memory-pressure colours.
    private var pressureColor: Color? {
        switch store.cardMemory?.pressure {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        case nil: return nil
        }
    }
    private var networkValue: String {
        guard let n = store.cardNetwork else { return "—" }
        return "↓ \(rate(n.downBytesPerSec))"
    }
    private var networkMeta: String {
        guard let n = store.cardNetwork else { return "" }
        return "↑ \(rate(n.upBytesPerSec))"
    }
    private var batteryValue: String {
        guard let b = store.battery else { return "—" }
        return "\(b.percent)%"
    }
    private var batteryMeta: String {
        store.battery?.cardMeta ?? "no battery"
    }
}

/// Horizontal battery level in the battery card's graph slot, like the level bar in the
/// macOS battery menu: green while plugged in, red at 20 % or below, otherwise the card's
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
        if battery.state.isPluggedIn { return .green }
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
            Button("Quit MacStats") { NSApplication.shared.terminate(nil) }
                .buttonStyle(SubtleButtonStyle(cornerRadius: Design.cardCornerRadius))
            Spacer()
            trailing
        }
    }
}

extension PanelFooter where Trailing == EmptyView {
    init() { self.init { EmptyView() } }
}

import SwiftUI
import AppKit
import MacStatsCore

/// The drill-in: a back header with the live total, then the ranked app list.
/// Right-click a row for Quit / Force Quit (Force Quit confirms first).
struct BreakdownView: View {
    @ObservedObject var store: MetricsStore
    let metric: BreakdownMetric
    let onBack: () -> Void

    @State private var forceQuitTarget: AppUsage?

    private var title: String { metric == .cpu ? "CPU" : "Memory" }

    private var liveTotal: String {
        switch metric {
        case .cpu:
            return "\(Int(store.cpuPercent.rounded()))% used"
        case .memory:
            guard let m = store.memory else { return "—" }
            return "\(gb(m.usedBytes)) / \(gb(m.totalBytes)) GB"
        }
    }

    /// Top app's value — used to scale the usage bars (sorted desc, so it's the first row).
    private var maxValue: Double { store.breakdown.first?.value(for: metric) ?? 1 }

    var body: some View {
        VStack(spacing: 0) {
            // header
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").fontWeight(.bold)
                        Text(title).fontWeight(.bold)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Text(liveTotal).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 8)
            Divider()

            if store.breakdownMeasuring {
                measuring
            } else if store.breakdown.isEmpty {
                Text("No apps").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.breakdown) { app in
                            AppRow(app: app, metric: metric, maxValue: maxValue)
                                .contextMenu {
                                    Button(appName(app.appPID)) {}.disabled(true)   // faint header
                                    Divider()
                                    Button("Quit") { ProcessActions.quit(appPID: app.appPID) }
                                    Divider()
                                    Button("Force Quit", role: .destructive) { forceQuitTarget = app }
                                }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 300)   // ~8 rows visible, scroll for the rest
                if store.breakdown.count > 8 {
                    Text("⌄ scroll for \(store.breakdown.count - 8) more")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                }
            }

            Divider()
            HStack {
                Button("Quit") { NSApplication.shared.terminate(nil) }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
        .frame(width: 320)
        .alert("Force quit \u{201C}\(appName(forceQuitTarget?.appPID))\u{201D}?",
               isPresented: Binding(get: { forceQuitTarget != nil },
                                    set: { if !$0 { forceQuitTarget = nil } })) {
            Button("Cancel", role: .cancel) { forceQuitTarget = nil }
            Button("Force Quit", role: .destructive) {
                if let t = forceQuitTarget { ProcessActions.forceQuit(appPID: t.appPID) }
                forceQuitTarget = nil
            }
        } message: {
            Text("The app will quit immediately and you\u{2019}ll lose any unsaved changes.")
        }
    }

    private var measuring: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Measuring\u{2026}").font(.callout).fontWeight(.semibold)
            Text("Sampling CPU usage").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 44)
    }

    private func appName(_ appPID: Int32?) -> String {
        guard let appPID else { return "this app" }
        return NSRunningApplication(processIdentifier: pid_t(appPID))?.localizedName ?? "PID \(appPID)"
    }

    private func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }
}

/// One app row: icon, name, usage bar, value. Name/icon resolved from the live app list.
private struct AppRow: View {
    let app: AppUsage
    let metric: BreakdownMetric
    let maxValue: Double

    var body: some View {
        let running = NSRunningApplication(processIdentifier: pid_t(app.appPID))
        let name = running?.localizedName ?? "PID \(app.appPID)"
        let color: Color = metric == .cpu ? .green : .blue

        HStack(spacing: 11) {
            icon(for: running)
                .resizable().frame(width: 24, height: 24).cornerRadius(6)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.callout).lineLimit(1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(color)
                            .frame(width: max(2, geo.size.width * fraction))
                    }
                }
                .frame(height: 4)
            }
            Spacer(minLength: 8)
            Text(valueText).font(.callout).fontWeight(.semibold)
                .monospacedDigit().foregroundStyle(.primary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var fraction: Double {
        guard maxValue > 0 else { return 0 }
        return min(1, app.value(for: metric) / maxValue)
    }

    private var valueText: String {
        switch metric {
        case .cpu:
            return "\(Int(app.cpuPercent.rounded()))%"
        case .memory:
            let mb = Double(app.memoryBytes) / 1_048_576
            return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
        }
    }

    private func icon(for running: NSRunningApplication?) -> Image {
        if let ns = running?.icon { return Image(nsImage: ns) }
        return Image(systemName: "app.dashed")
    }
}

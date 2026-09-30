import SwiftUI
import AppKit
import MacStatsCore

/// The drill-in: a back header with the live total, then the ranked app list in one inset
/// card that fills the fixed panel height (the list scrolls inside it).
/// Right-click a row for Quit / Force Quit (Force Quit confirms first).
struct BreakdownView: View {
    @ObservedObject var store: MetricsStore
    let metric: BreakdownMetric
    let onBack: () -> Void

    /// Names + small icons, resolved once per app and freed when the breakdown closes.
    @StateObject private var apps = AppInfoCache()

    private var title: String {
        switch metric {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .energy: return "Battery"
        }
    }

    private var liveTotal: String {
        switch metric {
        case .cpu:
            return "\(Int(store.cpuPercent.rounded()))% used"
        case .memory:
            guard let m = store.memory else { return "—" }
            return "\(gb(m.usedBytes)) / \(gb(m.totalBytes)) GB"
        case .energy:
            guard let b = store.battery else { return "—" }
            return "\(b.percent)%"
        }
    }

    private var liveTotalNumber: Double {
        switch metric {
        case .cpu: return store.cpuPercent.rounded()
        case .memory: return Double(store.memory?.usedBytes ?? 0)
        case .energy: return Double(store.battery?.percent ?? 0)
        }
    }

    /// Top app's value — used to scale the usage bars (sorted desc, so it's the first row).
    private var maxValue: Double { store.breakdown.first?.value(for: metric) ?? 1 }

    var body: some View {
        VStack(spacing: Design.cardSpacing) {
            PanelHeader {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(title)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text(liveTotal)
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .contentTransition(.interpolate)
                    .animation(.easeInOut(duration: 0.25), value: liveTotalNumber)
            }

            if metric == .energy { BatteryDetailsCard(store: store) }

            list
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CardBackground())
                .clipShape(RoundedRectangle(cornerRadius: Design.cardCornerRadius, style: .continuous))

            PanelFooter {
                if metric == .energy {
                    Text("App power counts CPU only")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else if store.breakdown.count > 8 && !store.breakdownMeasuring {
                    Text("\(store.breakdown.count) apps \u{2014} scroll for more")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding([.horizontal, .bottom], Design.panelInset)
        .frame(width: Design.panelWidth, height: Design.panelHeight, alignment: .top)
    }

    @ViewBuilder private var list: some View {
        if store.breakdownMeasuring {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Measuring\u{2026}").font(.callout).fontWeight(.semibold)
                Text(metric == .energy ? "Sampling energy use" : "Sampling CPU usage")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if store.breakdown.isEmpty {
            Text("No apps").font(.callout).foregroundStyle(.secondary)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.breakdown) { app in
                        let info = apps.info(for: app.appPID)
                        AppRow(app: app, info: info, metric: metric, maxValue: maxValue)
                            .contextMenu {
                                Button(info.name) {}.disabled(true)   // faint header
                                Divider()
                                Button("Quit") { ProcessActions.quit(appPID: app.appPID) }
                                Divider()
                                Button("Force Quit\u{2026}", role: .destructive) {
                                    ProcessActions.confirmForceQuit(appPID: app.appPID, name: info.name)
                                }
                            }
                    }
                }
                .padding(4)
            }
        }
    }

    private func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }
}

/// One app row: icon, name, usage bar, value. Highlights on hover like a native list row.
private struct AppRow: View {
    let app: AppUsage
    let info: AppInfoCache.Info
    let metric: BreakdownMetric
    let maxValue: Double

    @State private var hovering = false

    var body: some View {
        let color: Color = switch metric {
        case .cpu: .green
        case .memory: .blue
        case .energy: .yellow
        }

        HStack(spacing: 10) {
            Group {
                if let icon = info.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(info.name).font(.callout).lineLimit(1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(color)
                            .frame(width: max(4, geo.size.width * fraction))
                    }
                }
                .frame(height: 4)
                .animation(.smooth(duration: 0.3), value: fraction)
            }
            Spacer(minLength: 8)
            Text(valueText)
                .font(.callout).fontWeight(.semibold).monospacedDigit()
                .contentTransition(.interpolate)
                .animation(.easeInOut(duration: 0.25), value: app.value(for: metric))
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Design.cardCornerRadius - 4, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
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
        case .energy:
            // Most apps idle well under a watt; two decimals keep them from all reading 0.0.
            return app.watts < 1 ? String(format: "%.2f W", app.watts) : formatWatts(app.watts)
        }
    }
}

/// Per-breakdown cache of each app's display name and icon, keyed by app pid. Looking up
/// `NSRunningApplication` and its full-size, multi-resolution `icon` for every row on every
/// refresh is slow and holds large images; this resolves each app once and keeps only a
/// 24 pt @2x bitmap. Owned by `BreakdownView` as a `@StateObject`, so it's freed on back.
@MainActor
final class AppInfoCache: ObservableObject {
    struct Info {
        let name: String
        let icon: NSImage?
    }

    private var cache: [Int32: Info] = [:]

    func info(for appPID: Int32) -> Info {
        if let hit = cache[appPID] { return hit }
        let app = NSRunningApplication(processIdentifier: pid_t(appPID))
        let info = Info(name: app?.localizedName ?? "PID \(appPID)",
                        icon: app?.icon.flatMap { Self.thumbnail($0) })
        cache[appPID] = info
        return info
    }

    /// Renders `image` once into a small fixed bitmap (24 pt at 2x), dropping the source's
    /// large representations.
    private static func thumbnail(_ image: NSImage) -> NSImage? {
        let points: CGFloat = 24, pixels = Int(points * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: points, height: points)   // before the context: sets 2x scale
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: points, height: points))
        NSGraphicsContext.restoreGraphicsState()
        let thumb = NSImage(size: rep.size)
        thumb.addRepresentation(rep)
        return thumb
    }
}

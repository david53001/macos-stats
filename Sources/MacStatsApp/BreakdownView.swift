import SwiftUI
import AppKit
import MacStatsCore

/// The drill-in: a back header with the live total, then the ranked app list in one inset
/// card that fills the fixed panel height (the list scrolls inside it).
/// Click an app with several processes to expand it into its processes (one app at a time).
/// Right-click a row for Quit / Force Quit (Force Quit confirms first); on a process row
/// they act on that process only.
struct BreakdownView: View {
    @ObservedObject var store: MetricsStore
    let metric: BreakdownMetric
    let onBack: () -> Void

    /// Names + small icons, resolved once per app/process and freed when the breakdown closes.
    @StateObject private var apps: AppInfoCache
    /// The expanded app row (accordion: one at a time) and how many of its processes show.
    @State private var expanded: Int32?
    @State private var visibleChildren = BreakdownList.initialChildren

    private static let cores = ProcessInfo.processInfo.activeProcessorCount

    init(store: MetricsStore, metric: BreakdownMetric, onBack: @escaping () -> Void) {
        _store = ObservedObject(wrappedValue: store)
        self.metric = metric
        self.onBack = onBack
        _apps = StateObject(wrappedValue: AppInfoCache())
    }

    private var title: String {
        switch metric {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .energy: return "Battery"
        }
    }

    /// CPU: the whole machine over the same interval as the rows (the rows, including Other
    /// and System, add up to it); falls back to the card's value until that's measured.
    private var cpuTotal: Double { store.breakdownTotalCPU ?? store.cpuPercent }

    private var liveTotal: String {
        switch metric {
        case .cpu:
            return "\(Int(cpuTotal.rounded()))% used"
        case .memory:
            guard let m = store.memory else { return "—" }
            return "\(gb(m.usedBytes)) / \(gb(m.totalBytes)) GB used"
        case .energy:
            guard let b = store.battery else { return "—" }
            return "\(b.percent)%"
        }
    }

    private var liveTotalNumber: Double {
        switch metric {
        case .cpu: return cpuTotal.rounded()
        case .memory: return Double(store.memory?.usedBytes ?? 0)
        case .energy: return Double(store.battery?.percent ?? 0)
        }
    }

    /// The value a full bar stands for. CPU: the whole machine (100 %), the card's scale, so
    /// a bar is a true share of the Mac. Memory: all of the Mac's RAM, like the header.
    /// Energy has no natural ceiling, so its bars are relative to the top row.
    private var barScale: Double {
        switch metric {
        case .cpu: return 100
        case .memory: return Double(store.memory?.totalBytes ?? ProcessInfo.processInfo.physicalMemory)
        case .energy: return store.breakdown.first?.value(for: metric) ?? 1
        }
    }

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
            if metric == .memory { MemoryPartsCard(store: store) }

            list
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CardBackground())
                .clipShape(RoundedRectangle(cornerRadius: Design.cardCornerRadius, style: .continuous))

            PanelFooter {
                Text(footnote)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(metric == .memory ? 2 : 1).minimumScaleFactor(0.8)
            }
        }
        .padding([.horizontal, .bottom], Design.panelInset)
        .frame(width: Design.panelWidth, height: Design.panelHeight, alignment: .top)
    }

    /// One line that says what the numbers are measured against.
    private var footnote: String {
        switch metric {
        case .cpu: return "Share of the whole Mac (all \(Self.cores) cores)"
        // Like Activity Monitor's Memory column (footprints). They don't reconcile with Memory
        // Used either way: compressed memory counts at full size (more), and macOS's own and
        // other users' processes aren't listed (less).
        case .memory: return "Rows are each app's footprint (as in Activity Monitor); they don't add up to Memory Used"
        case .energy: return "App power counts CPU only"
        }
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
                    ForEach(BreakdownList.rows(store.breakdown, expanded: expanded, visible: visibleChildren)) { row in
                        switch row.kind {
                        case .app(let app): appRow(app)
                        case .process(let process, let app): processRow(process, in: app)
                        case .more(let remaining): moreRow(remaining)
                        }
                    }
                }
                .padding(4)
            }
        }
    }

    private func appRow(_ app: AppUsage) -> some View {
        let info = apps.info(for: app.appPID)
        let expandable = app.processes.count > 1
        return AppRow(app: app, info: info, metric: metric, barScale: barScale,
                      perCore: metric == .cpu ? oneCore(app.cpuPercent) : nil,
                      disclosure: expandable ? (expanded == app.appPID) : nil)
            .onTapGesture {
                guard expandable else { return }
                withAnimation(.snappy(duration: 0.25)) {
                    expanded = expanded == app.appPID ? nil : app.appPID
                    visibleChildren = BreakdownList.initialChildren
                }
            }
            .contextMenu {
                if app.isApp {
                    Button(info.name) {}.disabled(true)   // faint header
                    if metric == .cpu { oneCoreLine(app.cpuPercent) }
                    Divider()
                    Button("Quit") { ProcessActions.quit(appPID: app.appPID) }
                    Divider()
                    Button("Force Quit\u{2026}", role: .destructive) {
                        ProcessActions.confirmForceQuit(appPID: app.appPID, name: info.name)
                    }
                } else {
                    Button(info.detail ?? info.name) {}.disabled(true)
                    if metric == .cpu { oneCoreLine(app.cpuPercent) }
                }
            }
            .tooltip(rowTooltip(app, info))
    }

    /// Activity Monitor's scale (100 % = one core), for comparing with it.
    private func oneCore(_ cpuPercent: Double) -> String {
        "\(Int((cpuPercent * Double(Self.cores)).rounded()))% of one core"
    }

    private func oneCoreLine(_ cpuPercent: Double) -> some View {
        Button(oneCore(cpuPercent)) {}.disabled(true)
    }

    /// A group row's explanation; on CPU rows also Activity Monitor's figure (100 % = one core).
    private func rowTooltip(_ app: AppUsage, _ info: AppInfoCache.Info) -> String? {
        guard metric == .cpu else { return info.detail }
        return [info.detail, oneCore(app.cpuPercent)].compactMap { $0 }.joined(separator: "\n")
    }

    @ViewBuilder private func processRow(_ process: ProcessUsage, in app: AppUsage) -> some View {
        if process.pid == BreakdownGroup.exitedProcesses {
            exitedRow(process)
        } else {
            liveProcessRow(process, in: app)
        }
    }

    /// The app's CPU credited for processes that exited between scans: no process to act on.
    private func exitedRow(_ process: ProcessUsage) -> some View {
        ProcessRow(process: process, name: "Exited processes", metric: metric, barScale: barScale,
                   perCore: metric == .cpu ? oneCore(process.cpuPercent) : nil)
            .transition(.opacity)
            .contextMenu {
                Button("Exited processes") {}.disabled(true)
                if metric == .cpu { oneCoreLine(process.cpuPercent) }
            }
            .help("Work by this app's processes that ended since the last update")
    }

    private func liveProcessRow(_ process: ProcessUsage, in app: AppUsage) -> some View {
        let isAppItself = app.isApp && process.pid == app.appPID
        let name = isAppItself ? apps.info(for: app.appPID).name
                               : apps.name(ofProcess: process.pid, startTime: process.startTime)
        return ProcessRow(process: process, name: name, metric: metric, barScale: barScale,
                          perCore: metric == .cpu ? oneCore(process.cpuPercent) : nil)
            .transition(.opacity)
            .contextMenu {
                Button("\(name) \u{2014} pid \(process.pid)") {}.disabled(true)
                if metric == .cpu { oneCoreLine(process.cpuPercent) }
                Divider()
                Button("Quit") {
                    if isAppItself { ProcessActions.quit(appPID: app.appPID) }
                    else { ProcessActions.quit(pid: process.pid, startTime: process.startTime) }
                }
                Divider()
                Button("Force Quit\u{2026}", role: .destructive) {
                    if isAppItself { ProcessActions.confirmForceQuit(appPID: app.appPID, name: name) }
                    else { ProcessActions.confirmForceQuit(pid: process.pid, startTime: process.startTime, name: name) }
                }
            }
    }

    private func moreRow(_ remaining: Int) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { visibleChildren += BreakdownList.moreChildren }
        } label: {
            Text("\(remaining) more\u{2026}")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, BreakdownList.childIndent)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transition(.opacity)
    }

    private func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }
}

/// Flattens the ranked apps plus the expanded app's processes into one list, so the
/// `LazyVStack` builds only the rows on screen (an app can have hundreds of processes).
enum BreakdownList {
    static let initialChildren = 5
    static let moreChildren = 25
    /// Child rows line up with the app name column (24 pt icon + 10 pt spacing).
    static let childIndent: CGFloat = 34

    struct Row: Identifiable {
        enum Kind {
            case app(AppUsage)
            case process(ProcessUsage, AppUsage)
            case more(Int)
        }
        let id: String
        let kind: Kind
    }

    static func rows(_ apps: [AppUsage], expanded: Int32?, visible: Int) -> [Row] {
        var rows: [Row] = []
        rows.reserveCapacity(apps.count + visible + 1)
        for app in apps {
            rows.append(Row(id: "a\(app.appPID)", kind: .app(app)))
            guard app.appPID == expanded, app.processes.count > 1 else { continue }
            for p in app.processes.prefix(visible) {
                rows.append(Row(id: "p\(p.pid)", kind: .process(p, app)))
            }
            if app.processes.count > visible {
                rows.append(Row(id: "m\(app.appPID)", kind: .more(app.processes.count - visible)))
            }
        }
        return rows
    }
}

private extension View {
    /// A tooltip only when there is something to say.
    @ViewBuilder func tooltip(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}

private func barColor(_ metric: BreakdownMetric) -> Color {
    switch metric {
    case .cpu: .green
    case .memory: .blue
    case .energy: .yellow
    }
}

/// One app row: icon, name, usage bar, value, and a disclosure chevron when the app has
/// several processes. Highlights on hover like a native list row.
private struct AppRow: View {
    let app: AppUsage
    let info: AppInfoCache.Info
    let metric: BreakdownMetric
    let barScale: Double
    /// CPU only: Activity Monitor's figure for the app ("415% of one core"), beside the bar.
    let perCore: String?
    /// nil = not expandable; else whether it is expanded.
    let disclosure: Bool?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = info.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: info.symbol).resizable().scaledToFit()
                        .padding(info.symbol == "app.dashed" ? 0 : 3)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))

            VStack(alignment: .leading, spacing: perCore == nil ? 4 : 1) {
                Text(info.name).font(.callout).lineLimit(1)
                HStack(spacing: 6) {
                    UsageBar(fraction: fraction, color: barColor(metric), height: 4)
                    if let perCore {
                        // A fixed column ("800% of one core" fits) keeps every row's bar the same length.
                        Text(perCore)
                            .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .frame(width: 88, alignment: .leading)
                    }
                }
            }
            Spacer(minLength: 8)
            Text(breakdownValueText(metric, app.value(for: metric)))
                .font(.callout).fontWeight(.semibold).monospacedDigit()
                .contentTransition(.interpolate)
                .animation(.easeInOut(duration: 0.25), value: app.value(for: metric))
                .frame(width: 58, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(disclosure == true ? 90 : 0))
                .opacity(disclosure == nil ? 0 : 1)
                .frame(width: 8)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Design.cardCornerRadius - 4, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.snappy(duration: 0.25), value: disclosure)
        .onHover { hovering = $0 }
    }

    private var fraction: Double {
        guard barScale > 0 else { return 0 }
        return min(1, app.value(for: metric) / barScale)
    }
}

/// One process inside an expanded app: indented to the name column, smaller type, its own
/// value on the same scale, and a thin bar.
private struct ProcessRow: View {
    let process: ProcessUsage
    let name: String
    let metric: BreakdownMetric
    let barScale: Double
    /// CPU only: Activity Monitor's figure for this process ("100% of one core"), under the name.
    let perCore: String?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: perCore == nil ? 3 : 1) {
                HStack(spacing: 4) {
                    Text(name).lineLimit(1).truncationMode(.middle)
                    if process.pid > 0 {
                        Text(verbatim: String(process.pid)).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                .font(.caption)
                HStack(spacing: 6) {
                    UsageBar(fraction: fraction, color: barColor(metric).opacity(0.7), height: 2)
                    if let perCore {
                        Text(perCore)
                            .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                            .fixedSize()
                    }
                }
            }
            Spacer(minLength: 8)
            Text(breakdownValueText(metric, process.value(for: metric)))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .contentTransition(.interpolate)
                .animation(.easeInOut(duration: 0.25), value: process.value(for: metric))
                .frame(width: 58, alignment: .trailing)
            Color.clear.frame(width: 8, height: 1)   // the app rows' chevron column
        }
        .padding(.leading, BreakdownList.childIndent)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Design.cardCornerRadius - 4, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }

    private var fraction: Double {
        guard barScale > 0 else { return 0 }
        return min(1, process.value(for: metric) / barScale)
    }
}

private struct UsageBar: View {
    let fraction: Double
    let color: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color)
                    .frame(width: max(height, geo.size.width * fraction))
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.3), value: fraction)
    }
}

/// Per-breakdown cache of each app's display name and icon, keyed by app pid, and of process
/// names, keyed by pid + start time. Looking up `NSRunningApplication` and its full-size,
/// multi-resolution `icon` for every row on every refresh is slow and holds large images;
/// this resolves each app once and keeps only a 24 pt @2x bitmap. Process names are read
/// only for rows actually shown. Owned by `BreakdownView` as a `@StateObject`, so it's freed
/// on back.
@MainActor
final class AppInfoCache: ObservableObject {
    struct Info {
        let name: String
        let icon: NSImage?
        /// SF Symbol shown when there's no icon.
        var symbol: String = "app.dashed"
        /// What a group row stands for (tooltip / context-menu header).
        var detail: String? = nil
    }

    private var cache: [Int32: Info] = [:]
    private var processNames: [Int32: (startTime: UInt64, name: String)] = [:]

    func info(for appPID: Int32) -> Info {
        if let hit = cache[appPID] { return hit }
        let info: Info
        switch appPID {
        case BreakdownGroup.otherProcesses:
            info = Info(name: "Other processes", icon: nil, symbol: "gearshape.2",
                        detail: "Your background processes that no app is responsible for")
        case BreakdownGroup.system:
            info = Info(name: "System", icon: nil, symbol: "apple.logo",
                        detail: "The kernel, WindowServer, other users' processes, commands run with sudo, "
                            + "and processes that exited before they could be traced to an app")
        default:
            let app = NSRunningApplication(processIdentifier: pid_t(appPID))
            info = Info(name: app?.localizedName ?? "PID \(appPID)",
                        icon: app?.icon.flatMap { Self.thumbnail($0) })
        }
        cache[appPID] = info
        return info
    }

    func name(ofProcess pid: Int32, startTime: UInt64) -> String {
        if let hit = processNames[pid], hit.startTime == startTime { return hit.name }
        let name = processName(pid) ?? "Process"
        processNames[pid] = (startTime, name)
        return name
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

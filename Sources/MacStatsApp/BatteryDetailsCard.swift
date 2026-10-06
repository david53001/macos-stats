import SwiftUI
import MacStatsCore

/// The top card of the Battery drill-in: status, time left / to full, power, health.
/// Label on the left, value on the right, in the card language of the rest of the popover.
struct BatteryDetailsCard: View {
    @ObservedObject var store: MetricsStore

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(rows, id: \.label) { row in
                GridRow {
                    Text(row.label).foregroundStyle(.secondary)
                        .rowHelp(row.help)
                    Text(row.value)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .contentTransition(.interpolate)
                        .animation(.easeInOut(duration: 0.25), value: row.value)
                        .rowHelp(row.help)
                }
            }
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, Design.cardPadding)
        .padding(.vertical, 9)
        .background(CardBackground())
    }

    private struct Row {
        let label: String
        let value: String
        var help: String? = nil
    }

    private var rows: [Row] {
        guard let b = store.battery else { return [Row(label: "Status", value: "No battery")] }
        let t = store.batteryTelemetry
        var rows = [Row(label: "Status", value: b.statusText)]

        switch b.state {
        case .discharging:
            rows.append(Row(label: "Time left", value: b.timeToEmptyMinutes.map(aboutTimeLeft) ?? "Calculating…"))
        case .charging:
            rows.append(Row(label: b.chargeTargetLabel, value: b.timeToFullMinutes.map(formatTimeToFull)
                            ?? (b.atChargeLimit ? "Almost done" : b.percent >= 90 ? "Almost full" : "Calculating…")))
        case .charged, .notCharging:
            // Optimized Charging's pause is not the user's limit: show both.
            if let hold = b.chargeHoldPercent { rows.append(Row(label: "Optimized Charging", value: "Held at \(hold)%")) }
            if let limit = b.chargeLimitPercent { rows.append(Row(label: "Charge limit", value: "\(limit)%")) }
        }

        // The gauge updates about once a minute; "Power" is that minute's average draw.
        if let power = store.batteryPowerWatts {
            rows.append(Row(label: "Power now", value: formatWatts(power), help: "Average over the last minute"))
        }
        // Awake time only: intervals that span sleep are left out (see `gaugeInterval`).
        if let avg = store.batteryAverageWatts {
            rows.append(Row(label: store.batteryAverageSinceUnplug ? "Average since unplugged" : "Average this session",
                            value: formatWatts(avg), help: "Counts only time the Mac was awake"))
        }
        if b.state.isPluggedIn, let adapter = t?.adapterWatts {
            rows.append(Row(label: "Adapter", value: "\(adapter) W"))
        }
        if let health = t?.healthPercent {
            let cycles = t?.cycleCount.map { " · \($0) cycles" } ?? ""
            rows.append(Row(label: "Health", value: "\(health)%\(cycles)"))
        }
        if let temp = t?.temperatureC {
            rows.append(Row(label: "Temperature", value: "\(Int(temp.rounded())) °C"))
        }
        return rows
    }

    /// "About 4h": the estimate is rounded about as coarsely as it is uncertain, so say so
    /// (`formatTimeLeft` already says "about 6h" from six hours up).
    private func aboutTimeLeft(_ minutes: Int) -> String {
        let text = formatTimeLeft(minutes)
        return text.hasPrefix("about ") ? "A" + text.dropFirst() : "About \(text)"
    }
}

private extension View {
    /// A tooltip only when the row has one.
    @ViewBuilder func rowHelp(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}

extension BatterySample {
    /// Full status, as the macOS battery menu words it.
    var statusText: String {
        switch state {
        case .charging: return "Charging"
        case .charged: return "Fully charged"
        case .notCharging: return "Plugged in, not charging"
        case .discharging: return "On battery"
        }
    }

    /// "Time to full", "Time to 85%" when charging stops at a limit, or "Time to 100%" when
    /// MacStats can't tell whether a limit will stop it sooner.
    var chargeTargetLabel: String { "Time to \(chargeTargetName)" }

    /// Charging, and already showing the percent it stops at (the last minute before it does).
    var atChargeLimit: Bool { chargeStopPercent.map { percent >= $0 } ?? false }

    private var chargeTargetName: String {
        if let stop = chargeStopPercent { return "\(stop)%" }
        return chargeTargetAssumed ? "100%" : "full"
    }

    /// The Battery card's short secondary line (the card's text column is ~120 pt).
    var cardMeta: String {
        switch state {
        case .charging:
            return timeToFullMinutes.map { "\(formatTimeToFull($0)) to \(chargeTargetName)" }
                ?? (atChargeLimit ? "almost done" : percent >= 90 ? "almost full" : "charging")   // no estimate in the last trickle
        case .charged: return "fully charged"
        case .notCharging: return "not charging"
        case .discharging: return timeToEmptyMinutes.map { "\(formatTimeLeft($0)) left" } ?? "calculating…"
        }
    }
}

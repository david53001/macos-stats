import SwiftUI
import MacStatsCore

/// The top card of the Battery drill-in: time left / to full, power, health. Two label-value
/// pairs per line, so the app list below keeps room for 4-5 rows; the status is in the header.
/// In the card language of the rest of the popover.
struct BatteryDetailsCard: View {
    @ObservedObject var store: MetricsStore

    var body: some View {
        let items = rows
        VStack(spacing: 4) {
            ForEach(0..<(items.count + 1) / 2, id: \.self) { line in
                HStack(spacing: 16) {
                    pair(items[2 * line])
                    if 2 * line + 1 < items.count {
                        pair(items[2 * line + 1])
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
            }
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, Design.cardPadding)
        .padding(.vertical, 9)
        .background(CardBackground())
    }

    private func pair(_ row: Row) -> some View {
        HStack(spacing: 4) {
            Text(row.label).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(row.value)
                .monospacedDigit()
                .contentTransition(.interpolate)
                .animation(.easeInOut(duration: 0.25), value: row.value)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .tooltip(row.help)
    }

    private struct Row {
        let label: String
        let value: String
        var help: String? = nil
    }

    private var rows: [Row] {
        guard let b = store.battery else { return [Row(label: "Status", value: "No battery")] }
        let t = store.batteryTelemetry
        var rows: [Row] = []

        switch b.state {
        case .discharging:
            rows.append(Row(label: "Time left", value: b.timeToEmptyMinutes.map(timeLeft) ?? "Calculating…",
                            help: b.macOSTimeToEmptyMinutes.map {
                                "macOS's own estimate: \(formatDuration($0)) (it follows the last minute's use)"
                            }))
        case .charging:
            rows.append(Row(label: b.chargeTargetLabel, value: b.timeToFullMinutes.map(formatTimeToFull)
                            ?? (b.atChargeLimit ? "Almost done" : b.percent >= 90 ? "Almost full" : "Calculating…"),
                            help: b.macOSTimeToFullMinutes.map { minutes in
                                let text = "macOS's own estimate: \(formatDuration(minutes)) to 100%"
                                return b.chargeStopPercent.map { "\(text) (it doesn't count your \($0)% stop)" } ?? text
                            }))
        case .charged, .notCharging:
            // Optimized Charging's pause is not the user's limit: show both.
            if let hold = b.chargeHoldPercent {
                rows.append(Row(label: "Paused at", value: "\(hold)%",
                                help: "Optimized Charging is holding the charge here for now"))
            }
            if let limit = b.chargeLimitPercent { rows.append(Row(label: "Charge limit", value: "\(limit)%")) }
        }

        // The gauge updates about once a minute; "Power" is that minute's average draw.
        if let power = store.batteryPowerWatts {
            rows.append(Row(label: "Power now", value: formatWatts(power), help: "Average over the last minute"))
        }
        // Awake time only: intervals that span sleep are left out (see `gaugeInterval`).
        if let avg = store.batteryAverageWatts {
            rows.append(Row(label: "Average", value: formatWatts(avg),
                            help: (store.batteryAverageSinceUnplug ? "Since you unplugged" : "Since MacStats started")
                                + ", counting only time the Mac was awake"))
        }
        if b.state.isPluggedIn, let adapter = t?.adapterWatts {
            rows.append(Row(label: "Adapter", value: "\(adapter) W"))
        }
        if let health = t?.healthPercent {
            rows.append(Row(label: "Health", value: "\(health)%", help: "Capacity left compared with when new"))
        }
        if let cycles = t?.cycleCount {
            rows.append(Row(label: "Cycles", value: "\(cycles)", help: "Full charges used so far"))
        }
        if let temp = t?.temperatureC {
            rows.append(Row(label: "Temperature", value: "\(Int(temp.rounded())) °C"))
        }
        return rows
    }

    /// The card's wording ("5h 15m", "About 6h"), so both screens read the same estimate the same way.
    private func timeLeft(_ minutes: Int) -> String {
        let text = formatTimeLeft(minutes)
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

extension BatterySample {
    /// Full status, as the macOS battery menu words it.
    var statusText: String {
        switch state {
        case .charging: return "Charging"
        case .charged: return "Fully charged"
        case .notCharging:
            return heldAtLimitPercent.map { "Charged to \($0)% limit" } ?? "Plugged in, not charging"
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
        case .notCharging: return heldAtLimitPercent.map { "at \($0)% limit" } ?? "not charging"
        case .discharging: return timeToEmptyMinutes.map { "\(formatTimeLeft($0)) left" } ?? "calculating…"
        }
    }
}

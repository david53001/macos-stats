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
                    Text(row.value)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .contentTransition(.interpolate)
                        .animation(.easeInOut(duration: 0.25), value: row.value)
                }
            }
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, Design.cardPadding)
        .padding(.vertical, 9)
        .background(CardBackground())
    }

    private var rows: [(label: String, value: String)] {
        guard let b = store.battery else { return [("Status", "No battery")] }
        let t = store.batteryTelemetry
        var rows: [(label: String, value: String)] = [("Status", b.statusText)]

        switch b.state {
        case .discharging:
            rows.append(("Time left", b.timeToEmptyMinutes.map(formatDuration) ?? "Calculating…"))
        case .charging:
            rows.append(("Time to full", b.timeToFullMinutes.map(formatDuration) ?? "Calculating…"))
        case .charged, .notCharging:
            break
        }

        if let now = t?.instantWatts {
            var power = formatWatts(now)
            if let avg = store.batteryExpectedWatts { power += " now · \(formatWatts(avg)) avg" }
            rows.append(("Power", power))
        }
        if b.state.isPluggedIn, let adapter = t?.adapterWatts {
            rows.append(("Adapter", "\(adapter) W"))
        }
        if let health = t?.healthPercent {
            let cycles = t?.cycleCount.map { " · \($0) cycles" } ?? ""
            rows.append(("Health", "\(health)%\(cycles)"))
        }
        if let temp = t?.temperatureC {
            rows.append(("Temperature", "\(Int(temp.rounded())) °C"))
        }
        return rows
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

    /// The Battery card's short secondary line (the card's text column is ~120 pt).
    var cardMeta: String {
        switch state {
        case .charging: return timeToFullMinutes.map { "\(formatDuration($0)) to full" } ?? "charging"
        case .charged: return "fully charged"
        case .notCharging: return "not charging"
        case .discharging: return timeToEmptyMinutes.map { "\(formatDuration($0)) left" } ?? "calculating…"
        }
    }
}

/// "6h 40m", or "45m" under an hour.
func formatDuration(_ minutes: Int) -> String {
    minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
}

func formatWatts(_ watts: Double) -> String {
    String(format: watts < 10 ? "%.1f W" : "%.0f W", watts)
}

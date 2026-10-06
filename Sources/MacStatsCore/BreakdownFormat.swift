import Foundation

/// How a breakdown value reads, shared by the view, the store's display holds and the stability
/// probe so all three agree on what one printed step is. CPU is a share of the whole machine:
/// one decimal under 10 % so light apps don't all read "0%".
public func breakdownValueText(_ metric: BreakdownMetric, _ value: Double) -> String {
    switch metric {
    case .cpu:
        return value < 9.95 ? String(format: "%.1f%%", value) : String(format: "%.0f%%", value)
    case .memory:
        let mb = value / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    case .energy:
        // Most apps idle well under a watt; two decimals keep them from all reading 0.0, and
        // what rounds to 0.00 says so honestly.
        if value < 0.005 { return "<0.01 W" }
        return value < 1 ? String(format: "%.2f W", value) : formatWatts(value)
    }
}

/// The printed precision of `breakdownValueText` at `value`: 0.1 or 1 (CPU %); 1 MiB, or 0.1 GiB
/// (memory, in bytes); 0.01, 0.1 or 1 W (energy).
public func breakdownValueStep(_ metric: BreakdownMetric, _ value: Double) -> Double {
    switch metric {
    case .cpu:
        return value < 9.95 ? 0.1 : 1
    case .memory:
        return value / 1_048_576 >= 1024 ? 1_073_741_824 / 10 : 1_048_576
    case .energy:
        return value < 1 ? 0.01 : value < 10 ? 0.1 : 1
    }
}

/// A process's name as its row under `app` shows it: without the app's own name in front
/// ("Google Chrome Helper (Renderer)" under Google Chrome reads "Helper (Renderer)"), so rows that
/// differ only at the end don't all truncate to the same text. Unchanged otherwise.
public func processDisplayName(_ name: String, inApp app: String) -> String {
    guard !app.isEmpty, name.count > app.count + 1, name.hasPrefix(app + " ") else { return name }
    return String(name.dropFirst(app.count + 1))
}

/// Watts as the Battery screens print them: one decimal under 10 W.
public func formatWatts(_ watts: Double) -> String {
    String(format: watts < 10 ? "%.1f W" : "%.0f W", watts)
}

import SwiftUI
import MacStatsCore

/// The top card of the Memory drill-in: the parts of Memory Used (the header), as Activity
/// Monitor's Memory tab lists them. They come from the same kernel reading as the header and
/// add up to it.
struct MemoryPartsCard: View {
    @ObservedObject var store: MetricsStore

    var body: some View {
        let m = store.cardMemory   // held as one unit, so the parts still add up to the header
        let gb = m.map { roundedParts([$0.appBytes, $0.wiredBytes, $0.compressedBytes], unit: 1_073_741_824) }
        HStack(spacing: 8) {
            // Plain-language tooltips; the labels stay Activity Monitor's.
            part("App Memory", gb?[0], help: "Memory apps and macOS are using right now")
            part("Wired", gb?[1], help: "Memory macOS keeps for itself. It can\u{2019}t be freed.")
            part("Compressed", gb?[2], help: compressedHelp(m))
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, Design.cardPadding)
        .padding(.vertical, 7)
        .background(CardBackground())
    }

    private func part(_ label: String, _ gb: Double?, help: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(gb.map { String(format: "%.1f GB", $0) } ?? "—")
                .monospacedDigit()
                .contentTransition(.interpolate)
                .animation(.easeInOut(duration: 0.25), value: gb)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(help)
    }

    private func compressedHelp(_ m: MemorySample?) -> String {
        let tail = "squeezed into less RAM to make room. Normal, not a problem."
        guard let m, m.compressedDataBytes > m.compressedBytes else { return "App data \(tail)" }
        let held = String(format: "%.1f", Double(m.compressedDataBytes) / 1_073_741_824)
        return "\(held) GB of app data \(tail)"
    }
}

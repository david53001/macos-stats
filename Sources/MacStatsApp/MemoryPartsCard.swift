import SwiftUI
import MacStatsCore

/// The top card of the Memory drill-in: the parts of Memory Used (the header), as Activity
/// Monitor's Memory tab lists them. They come from the same kernel reading as the header and
/// add up to it.
struct MemoryPartsCard: View {
    @ObservedObject var store: MetricsStore

    var body: some View {
        let m = store.memory
        let gb = m.map { roundedParts([$0.appBytes, $0.wiredBytes, $0.compressedBytes], unit: 1_073_741_824) }
        HStack(spacing: 8) {
            part("App Memory", gb?[0], help: "Memory in use by every process (yours, macOS's and "
                    + "other users'), not counting what is compressed")
            part("Wired", gb?[1], help: "Memory the kernel and drivers keep in RAM; "
                    + "it can't be compressed or freed")
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
        guard let m, m.compressedDataBytes > m.compressedBytes else {
            return "RAM holding compressed app data. The rows below count that data at full size."
        }
        let held = String(format: "%.1f", Double(m.compressedDataBytes) / 1_073_741_824)
        return "RAM holding \(held) GB of compressed app data. The rows below count that data at full size."
    }
}

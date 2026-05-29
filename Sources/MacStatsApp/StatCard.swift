import SwiftUI

/// One row in the overview popover: label + big value + secondary line + sparkline.
/// When `onTap` is set, the whole row is clickable and shows a trailing chevron
/// (used for the CPU and Memory cards, which drill into a per-app breakdown).
struct StatCard: View {
    let label: String
    let value: String
    let meta: String
    let color: Color
    let history: [Double]
    let maxValue: Double
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(.caption2).fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3).fontWeight(.semibold)
                    .monospacedDigit()
                Text(meta)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(width: 118, alignment: .leading)

            Sparkline(values: history, color: color, maxValue: maxValue)

            if onTap != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}

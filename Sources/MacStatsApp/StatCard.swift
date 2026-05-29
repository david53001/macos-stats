import SwiftUI

/// One row in the overview popover: label + big value + secondary line + sparkline.
struct StatCard: View {
    let label: String
    let value: String
    let meta: String
    let color: Color
    let history: [Double]
    let maxValue: Double

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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

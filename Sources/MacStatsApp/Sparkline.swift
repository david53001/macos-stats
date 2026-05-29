import SwiftUI
import Charts

/// A compact area+line chart for a metric's recent history.
struct Sparkline: View {
    let values: [Double]
    let color: Color
    let maxValue: Double   // upper bound for the Y scale (0 if dynamic)

    var body: some View {
        let upper = max(maxValue, values.max() ?? 1, 1)
        Chart(Array(values.enumerated()), id: \.offset) { index, value in
            AreaMark(x: .value("i", index), y: .value("v", value))
                .foregroundStyle(
                    LinearGradient(colors: [color.opacity(0.45), color.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                )
            LineMark(x: .value("i", index), y: .value("v", value))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.6))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...upper)
        .frame(height: 36)
    }
}

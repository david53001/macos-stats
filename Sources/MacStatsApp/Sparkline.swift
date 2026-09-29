import SwiftUI
import MacStatsCore

/// A compact line chart of a metric's recent history on a fixed time axis: the newest
/// point sits at the right edge and `window` seconds span the full width.
/// (Placeholder polyline — replaced by the Apple-style chart in the polish work.)
struct Sparkline: View {
    let points: [SamplePoint]
    let color: Color
    let maxValue: Double   // upper bound for the Y scale (0 if dynamic)
    var window: TimeInterval = 60

    var body: some View {
        let upper = max(maxValue, points.map(\.value).max() ?? 1, 1)
        let end = points.last?.time ?? 0
        GeometryReader { geo in
            Path { path in
                for (i, p) in points.enumerated() {
                    let pt = CGPoint(x: geo.size.width * (1 - (end - p.time) / window),
                                     y: geo.size.height * (1 - p.value / upper))
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
            }
            .stroke(color, lineWidth: 1.6)
        }
        .frame(height: 36)
    }
}

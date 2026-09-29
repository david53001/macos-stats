import SwiftUI

/// One inset card in the overview: label + big value + secondary line on the left, a
/// graph (sparkline or gauge) on the right. When `onTap` is set the whole card is a button
/// with hover/pressed feedback and a trailing chevron (CPU and Memory drill into a per-app
/// breakdown); other cards reserve the chevron's space so all graphs line up.
struct StatCard<Graph: View>: View {
    let label: String
    let value: String
    /// Numeric form of `value`, which drives the rolling-digit transition.
    let number: Double
    let meta: String
    /// Optional status dot before `meta` (memory pressure).
    var metaDot: Color? = nil
    var onTap: (() -> Void)? = nil
    @ViewBuilder let graph: Graph

    /// Fixed so a changing value (or the "—" placeholder) never shifts the graph.
    private static var valueColumnWidth: CGFloat { 120 }

    var body: some View {
        if let onTap {
            Button(action: onTap) { content(showsChevron: true) }
                .buttonStyle(CardButtonStyle())
        } else {
            content(showsChevron: false)
                .background(CardBackground())
        }
    }

    private func content(showsChevron: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(.caption2).fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3).fontWeight(.semibold)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: number))
                    .animation(.snappy(duration: 0.3), value: number)
                HStack(spacing: 4) {
                    if let metaDot {
                        Circle().fill(metaDot).frame(width: 6, height: 6)
                    }
                    Text(meta.isEmpty ? " " : meta)   // a space keeps the line's height
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.3), value: meta)
                }
            }
            .lineLimit(1)
            .frame(width: Self.valueColumnWidth, alignment: .leading)

            graph

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .opacity(showsChevron ? 1 : 0)
        }
        .padding(.horizontal, Design.cardPadding)
        .padding(.vertical, 9)
        .contentShape(RoundedRectangle(cornerRadius: Design.cardCornerRadius, style: .continuous))
    }
}

/// The inset card surface: a faint fill (the blurred window shows through) and a hairline,
/// with continuous (squircle) corners concentric with the panel.
struct CardBackground: View {
    var fill: Double = Design.cardFill

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Design.cardCornerRadius, style: .continuous)
        shape.fill(Color.primary.opacity(fill))
            .overlay(shape.strokeBorder(Color.primary.opacity(Design.cardHairline), lineWidth: 0.5))
    }
}

/// A whole card as a button: the fill strengthens on hover and again while pressed.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverCard(isPressed: configuration.isPressed) { configuration.label }
    }

    private struct HoverCard<Label: View>: View {
        let isPressed: Bool
        @ViewBuilder let label: Label
        @State private var hovering = false

        var body: some View {
            label
                .background(CardBackground(fill: isPressed ? Design.cardPressedFill
                                            : hovering ? Design.cardHoverFill : Design.cardFill))
                .scaleEffect(isPressed ? 0.985 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// Small secondary button (Empty, Quit) drawn in the same material language as the cards:
/// a continuous-corner tinted surface that brightens on hover and dims when disabled.
struct SubtleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SubtleButton(configuration: configuration)
    }

    private struct SubtleButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let fill = configuration.isPressed ? 0.16 : hovering && isEnabled ? 0.12 : 0.08
            configuration.label
                .font(.callout.weight(.medium))
                .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(fill)))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

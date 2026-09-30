import SwiftUI
import MacStatsCore

/// The in-popover Settings screen, pushed from the overview's footer gear. Same fixed size,
/// header and card styling as the per-app breakdown. Changes apply live to the popover itself.
struct SettingsView: View {
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: Design.cardSpacing) {
            PanelHeader {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Settings")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
            }

            AppearanceCard()

            Spacer(minLength: 0)
            PanelFooter()
        }
        .padding([.horizontal, .bottom], Design.panelInset)
        .frame(width: Design.panelWidth, height: Design.panelHeight, alignment: .top)
    }
}

/// "Appearance" → Opacity: a continuous slider (Transparent … Opaque) with a Default reset.
/// Shared layout across MacStats, JVoice and BetterScreenshot (`opacity-setting.md` §2).
private struct AppearanceCard: View {
    @AppStorage(UIOpacity.key) private var opacity = UIOpacity.defaultValue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("APPEARANCE")
                .font(.caption2).fontWeight(.semibold)
                .foregroundStyle(.secondary)

            HStack {
                Text("Opacity").font(.callout)
                Spacer()
                Button("Default") { opacity = UIOpacity.defaultValue }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(UIOpacity.isDefault(opacity))
            }

            HStack(spacing: 8) {
                Text("Transparent")
                Slider(value: $opacity, in: 0...1) { Text("Opacity") }
                    .labelsHidden()
                    .controlSize(.small)
                Text("Opaque")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("How much of what's behind shows through the panel.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Design.cardPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }
}

/// The footer button that opens Settings (a small gear in the card-button language).
struct SettingsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .accessibilityLabel("Settings")
        }
        .buttonStyle(SubtleButtonStyle())
        .help("Settings")
    }
}

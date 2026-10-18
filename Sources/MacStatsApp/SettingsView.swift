import SwiftUI
import ServiceManagement
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

            GeneralCard()
            AppearanceCard()

            Spacer(minLength: 0)
            PanelFooter()
        }
        .padding([.horizontal, .bottom], Design.panelInset)
        .frame(width: Design.panelWidth, height: Design.panelHeight, alignment: .top)
    }
}

/// "General" → Launch at login: a switch backed directly by `SMAppService.mainApp.status`
/// (`LoginItem.swift`, shared with the one-time prompt card). Re-read each time Settings opens,
/// since the user may have changed it in System Settings. Only when macOS needs the user's
/// approval do we offer a jump to Login Items.
private struct GeneralCard: View {
    @ObservedObject private var login = LaunchAtLogin.shared
    private var status: SMAppService.Status { login.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GENERAL")
                .font(.caption2).fontWeight(.semibold)
                .foregroundStyle(.secondary)

            HStack {
                Text("Launch at login").font(.callout)
                Spacer()
                Toggle("Launch at login", isOn: Binding(
                    get: { status == .enabled },
                    set: { login.setEnabled($0) }   // re-reads, so a failure reverts
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if status == .requiresApproval {
                HStack {
                    Text("Needs your approval in Login Items.")
                    Spacer()
                    Button("Open") { login.openLoginItems() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Open MacStats automatically when you log in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Design.cardPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
        .onAppear { login.refresh() }
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

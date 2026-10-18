import SwiftUI
import ServiceManagement
import MacStatsCore

/// The in-popover Settings screen, pushed from the overview's footer gear. Same fixed size,
/// header and card styling as the per-app breakdown. Changes apply live to the popover itself.
struct SettingsView: View {
    var onTour: () -> Void = {}
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
                .keyboardShortcut(.cancelAction)   // Esc goes back
                Spacer()
            }

            // Four cards and the footer fill the fixed 404 pt exactly, so Take the Tour (the
            // stability-tour branch's own HELP card) is a row of GENERAL here.
            GeneralCard(onTour: onTour)
            UpdatesCard()
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
/// approval do we offer a jump to Login Items. Its last row is Take the Tour, where a skipped
/// tour can always be found again.
private struct GeneralCard: View {
    let onTour: () -> Void
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
                        .buttonStyle(SubtleButtonStyle())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Open MacStats automatically when you log in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text(TourCatalog.helpRow).font(.callout)
                Spacer()
                Button(TourCatalog.takeTheTour, action: onTour)
                    .buttonStyle(SubtleButtonStyle())
            }
        }
        .padding(.horizontal, Design.cardPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
        .onAppear { login.refresh() }
    }
}

/// "Updates" → Sparkle (`Updates.swift`): the automatic daily check and "Check for Updates…".
/// MacStats has no menu bar menu of its own, so this card is where the menu item lives.
private struct UpdatesCard: View {
    @ObservedObject private var updates = Updates.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("UPDATES")
                .font(.caption2).fontWeight(.semibold)
                .foregroundStyle(.secondary)

            HStack {
                Text("Check automatically").font(.callout)
                Spacer()
                Toggle("Check automatically", isOn: Binding(
                    get: { updates.automaticallyChecks },
                    set: { updates.automaticallyChecks = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            HStack {
                // Found, not downloaded yet (Sparkle downloads once the user says Install).
                Group {
                    if let version = updates.pendingVersion {
                        Text("Version \(version) is available.").foregroundStyle(.primary)
                    } else {
                        Text("You have MacStats \(updates.currentVersion).").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Button(updates.pendingVersion == nil ? "Check for Updates…" : "Show Update…") {
                    updates.checkForUpdates()
                }
                .buttonStyle(SubtleButtonStyle())   // like Default and Take the Tour (squircle pass)
                .fixedSize()                        // the version line gives way, never the button
                .disabled(!updates.canCheck && updates.pendingVersion == nil)
            }
        }
        .padding(.horizontal, Design.cardPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
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
                    .buttonStyle(SubtleButtonStyle())
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

            Text("How much of what\u{2019}s behind shows through the panel.")
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

/// The footer button that opens Settings (a small gear in the card-button language). While a
/// found update waits for the user, it carries a small accent dot (a status indicator, design
/// language principle 5), so the update isn't hidden behind other windows unnoticed.
struct SettingsButton: View {
    let action: () -> Void
    @ObservedObject private var updates = Updates.shared

    var body: some View {
        let updateWaiting = updates.pendingVersion != nil
        Button(action: action) {
            Image(systemName: "gearshape")
                .frame(width: Design.footerIconWidth)
                .overlay(alignment: .topTrailing) {
                    if updateWaiting {
                        Circle().fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .offset(x: 3, y: -2)
                    }
                }
                .accessibilityLabel(updateWaiting ? "Settings, update available" : "Settings")
        }
        .buttonStyle(SubtleButtonStyle(cornerRadius: Design.cardCornerRadius))   // concentric, like Quit
        .help(updateWaiting ? "Settings · An update is available" : "Settings")
    }
}

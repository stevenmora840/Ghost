import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // The mode toggle — one switch, same spot always, per
                // docs/vpn-development-recommendations.md.
                VStack(alignment: .leading, spacing: 10) {
                    StatLabel(text: "INTERFACE")
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Mode", selection: Binding(
                                get: { app.mode },
                                set: { app.mode = $0 }
                            )) {
                                Text("Simple").tag(AppMode.simple)
                                Text("Advanced").tag(AppMode.advanced)
                            }
                            .pickerStyle(.segmented)
                            Text(app.mode == .simple
                                ? "One-tap protection. The essentials, nothing else."
                                : "Full dashboard: protocol, ping, load, and tunnel controls.")
                                .font(.caption)
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    StatLabel(text: "ACCOUNT")
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            if let account = app.account {
                                if !account.email.isEmpty {
                                    row("Email", account.email)
                                    Divider().overlay(Theme.border)
                                }
                                row("Devices", "\(account.deviceCount) of \(account.deviceLimit)")
                            } else {
                                Text("Loading account…")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.textMuted)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    StatLabel(text: "PRIVACY")
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            row("Logging", "None — by design")
                            Divider().overlay(Theme.border)
                            row("Kill switch", app.killSwitchEnabled ? "On" : "Off")
                        }
                    }
                }

                Button {
                    Task { await app.signOut() }
                } label: {
                    Text("Sign out")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Theme.border))
                }
            }
            .padding(20)
        }
        .background(Theme.background)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

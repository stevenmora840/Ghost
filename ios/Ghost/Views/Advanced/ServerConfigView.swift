import SwiftUI

/// Advanced-mode server & protocol configuration: inline controls, no nested
/// modals. Multi-hop and obfuscation are surfaced here; both are client
/// plumbing ahead of PoP-side support in v1 (the toggles configure intent).
struct ServerConfigView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var multiHopEnabled = false
    @State private var excludedApps: Set<String> = []

    // Per-app split tunneling on iOS is constrained by NetworkExtension —
    // real enforcement uses includedApps rules in the tunnel provider. This
    // list drives that config; entries are illustrative until wired to
    // installed-app discovery.
    private let sampleApps = ["Mail", "Browser", "Banking"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // Protocol
                    VStack(alignment: .leading, spacing: 10) {
                        StatLabel(text: "PROTOCOL")
                        Picker("Protocol", selection: $app.tunnelProtocol) {
                            ForEach(TunnelProtocol.allCases) { p in
                                Text(p.rawValue).tag(p)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    // Split tunneling
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            StatLabel(text: "SPLIT TUNNELING")
                            Spacer()
                            Toggle("", isOn: $app.splitTunnelingEnabled)
                                .labelsHidden()
                                .tint(Theme.accent)
                        }
                        Text("Choose which apps skip the VPN tunnel.")
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)

                        if app.splitTunnelingEnabled {
                            Card(padding: 0) {
                                VStack(spacing: 0) {
                                    ForEach(sampleApps, id: \.self) { name in
                                        HStack(spacing: 12) {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Theme.surfaceRaised)
                                                .frame(width: 30, height: 30)
                                                .overlay(
                                                    Text(String(name.prefix(1)))
                                                        .font(.system(size: 12, weight: .bold))
                                                        .foregroundStyle(Theme.accentBlue)
                                                )
                                            Text(name)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(Theme.textPrimary)
                                            Spacer()
                                            Toggle("", isOn: Binding(
                                                get: { excludedApps.contains(name) },
                                                set: { on in
                                                    if on { excludedApps.insert(name) } else { excludedApps.remove(name) }
                                                }
                                            ))
                                            .labelsHidden()
                                            .tint(Theme.accent)
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 11)
                                        if name != sampleApps.last {
                                            Divider().overlay(Theme.border).padding(.horizontal, 14)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Multi-hop
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            StatLabel(text: "MULTI-HOP")
                            Spacer()
                            Toggle("", isOn: $multiHopEnabled)
                                .labelsHidden()
                                .tint(Theme.accent)
                        }
                        if multiHopEnabled {
                            HStack(spacing: 10) {
                                hopCard(label: "ENTRY", server: app.servers.first)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.textMuted)
                                hopCard(label: "EXIT", server: app.selectedServer)
                            }
                            Text("No single server sees both who you are and where you're going.")
                                .font(.caption)
                                .foregroundStyle(Theme.textMuted)
                        }
                    }

                    // Obfuscation
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Obfuscation")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Toggle("", isOn: $app.obfuscationEnabled)
                                    .labelsHidden()
                                    .tint(Theme.accent)
                            }
                            Text("Disguises VPN traffic as regular HTTPS. Useful on restrictive networks.")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }

                    // Nearby servers with the numbers this audience checks
                    VStack(alignment: .leading, spacing: 10) {
                        StatLabel(text: "SERVERS")
                        ForEach(app.servers) { server in
                            Button {
                                app.selectedServer = server
                            } label: {
                                Card(padding: 12) {
                                    HStack(spacing: 12) {
                                        Text(server.flagEmoji).font(.system(size: 20))
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("\(server.city) — \(server.id)")
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(Theme.textPrimary)
                                            if server.audited {
                                                Label("Audited", systemImage: "checkmark.shield.fill")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(Theme.textMuted)
                                            }
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 3) {
                                            Text("\(server.loadPct)% load")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(loadColor(server.loadPct))
                                            if server.id == app.selectedServer?.id {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 11, weight: .bold))
                                                    .foregroundStyle(Theme.accent)
                                            }
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("Server & Protocol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func hopCard(label: String, server: VPNServer?) -> some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                StatLabel(text: label)
                HStack(spacing: 8) {
                    Text(server?.flagEmoji ?? "🌐").font(.system(size: 16))
                    Text(server?.country ?? "—")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        }
    }

    private func loadColor(_ pct: Int) -> Color {
        switch pct {
        case ..<40: Theme.accent
        case ..<70: Theme.warning
        default: Theme.danger
        }
    }
}

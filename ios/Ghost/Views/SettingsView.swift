import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var showDedicatedIPPicker = false
    @State private var confirmPanicWipe = false
    @State private var confirmReleaseIP = false
    @State private var isWiping = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                tierCard

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

                threatProtectionSection
                dedicatedIPSection

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

                panicWipeSection

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
        .sheet(isPresented: $showDedicatedIPPicker) {
            DedicatedIPPicker()
        }
    }

    // MARK: Tier

    private var tierCard: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(app.tier.displayName)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(app.isPaid ? Theme.accentBlue : Theme.textPrimary)
                        if app.isPaid {
                            Image(systemName: "bolt.shield.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.accentBlue)
                        }
                    }
                    Text(app.isPaid
                        ? "Priority servers, custom multi-hop, and panic wipe."
                        : "Dedicated IP and threat blocking included.")
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
                if !app.isPaid {
                    Button("Upgrade") {
                        app.upgradePrompt = "Unlock priority servers, custom multi-hop, and panic wipe."
                    }
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.accent)
                    .foregroundStyle(Theme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    // MARK: Free tier — DNS threat & ad blocking

    private var threatProtectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatLabel(text: "THREAT PROTECTION")
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    filterToggle("Block ads", isOn: app.dnsFilter.blockAds) { newValue in
                        await app.updateDNSFilter(
                            ads: newValue,
                            malware: app.dnsFilter.blockMalware,
                            trackers: app.dnsFilter.blockTrackers
                        )
                    }
                    Divider().overlay(Theme.border)
                    filterToggle("Block trackers", isOn: app.dnsFilter.blockTrackers) { newValue in
                        await app.updateDNSFilter(
                            ads: app.dnsFilter.blockAds,
                            malware: app.dnsFilter.blockMalware,
                            trackers: newValue
                        )
                    }
                    Divider().overlay(Theme.border)
                    filterToggle("Block malware & phishing", isOn: app.dnsFilter.blockMalware) { newValue in
                        await app.updateDNSFilter(
                            ads: app.dnsFilter.blockAds,
                            malware: newValue,
                            trackers: app.dnsFilter.blockTrackers
                        )
                    }

                    Text("Blocking happens on Ghost's own DNS resolvers inside the tunnel. Nothing about your queries is recorded.")
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
    }

    private func filterToggle(_ label: String, isOn: Bool, action: @escaping (Bool) async -> Void) -> some View {
        Toggle(isOn: Binding(
            get: { isOn },
            set: { newValue in Task { await action(newValue) } }
        )) {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
        }
        .tint(Theme.accent)
    }

    // MARK: Free tier — dedicated static IP

    private var dedicatedIPSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatLabel(text: "DEDICATED IP")
            if let dedicated = app.dedicatedIP {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(dedicated.ip)
                                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(locationName(for: dedicated.serverID))
                                    .font(.caption)
                                    .foregroundStyle(Theme.textMuted)
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(Theme.accent)
                        }
                        Text("Yours alone — not shared with other Ghost users.")
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                        Divider().overlay(Theme.border)
                        Button("Release this address") { confirmReleaseIP = true }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.danger)
                    }
                }
                .confirmationDialog(
                    "Release \(dedicated.ip)?",
                    isPresented: $confirmReleaseIP,
                    titleVisibility: .visible
                ) {
                    Button("Release", role: .destructive) {
                        Task { await app.releaseDedicatedIP() }
                    }
                    Button("Keep it", role: .cancel) {}
                } message: {
                    Text("It returns to the pool and someone else may take it. You can claim a new one at any time.")
                }
            } else {
                Button { showDedicatedIPPicker = true } label: {
                    Card {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Claim a dedicated IP")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("An exit address used only by you. Included free.")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textMuted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Paid tier — panic wipe

    private var panicWipeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatLabel(text: "PANIC WIPE")
                PlusBadge()
            }
            Button {
                if app.isPaid {
                    confirmPanicWipe = true
                } else {
                    app.upgradePrompt = "Panic wipe is part of Ghost Plus."
                }
            } label: {
                Card {
                    HStack(spacing: 12) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.danger)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Wipe and start fresh")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Destroys your keys, devices, and sessions, then issues a brand-new identity.")
                                .font(.caption)
                                .foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        if isWiping {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: app.isPaid ? "chevron.right" : "lock.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isWiping)
            .confirmationDialog("Wipe this identity?", isPresented: $confirmPanicWipe, titleVisibility: .visible) {
                Button("Wipe everything", role: .destructive) {
                    Task {
                        isWiping = true
                        await app.panicWipe()
                        isWiping = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your VPN keys, every registered device, all other signed-in sessions, your dedicated IP, and your multi-hop chain are destroyed immediately. You stay signed in on this device with a new identity. This can't be undone.")
            }
        }
    }

    // MARK: Helpers

    private func locationName(for serverID: String) -> String {
        guard let server = app.servers.first(where: { $0.id == serverID }) else { return serverID }
        return "\(server.city), \(server.country)"
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

/// Location picker for claiming a dedicated exit address.
private struct DedicatedIPPicker: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var claiming: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pick where your dedicated address lives. You can release it and claim another later.")
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                        .padding(.bottom, 4)

                    ForEach(app.servers) { server in
                        Button {
                            guard claiming == nil else { return }
                            if server.locked {
                                app.upgradePrompt = "\(server.city) is a priority location, part of Ghost Plus."
                                return
                            }
                            Task {
                                claiming = server.id
                                await app.allocateDedicatedIP(serverID: server.id)
                                claiming = nil
                                if app.dedicatedIP != nil { dismiss() }
                            }
                        } label: {
                            Card(padding: 12) {
                                HStack(spacing: 12) {
                                    Text(server.flagEmoji).font(.system(size: 20))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(server.city)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(server.locked ? Theme.textSecondary : Theme.textPrimary)
                                        Text(server.country)
                                            .font(.caption)
                                            .foregroundStyle(Theme.textMuted)
                                    }
                                    Spacer()
                                    if claiming == server.id {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        ServerRowDetail(server: server, showsLoad: false)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("Dedicated IP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

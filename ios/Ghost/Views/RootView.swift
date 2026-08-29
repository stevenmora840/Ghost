import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Group {
            if app.isSignedIn {
                MainTabView()
            } else {
                SignInView()
            }
        }
        .preferredColorScheme(.dark)
        .alert("Something went wrong", isPresented: Binding(
            get: { app.errorMessage != nil },
            set: { if !$0 { app.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.errorMessage ?? "")
        }
        // A paid-feature refusal opens the upgrade sheet rather than an
        // error alert — it isn't a failure.
        .sheet(isPresented: Binding(
            get: { app.upgradePrompt != nil },
            set: { if !$0 { app.upgradePrompt = nil } }
        )) {
            UpgradeSheet(message: app.upgradePrompt ?? "")
        }
    }
}

private struct MainTabView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        TabView {
            NavigationStack {
                Group {
                    // Same tab, two densities — the toggle swaps presentation,
                    // never navigation structure.
                    if app.mode == .simple {
                        SimpleHomeView()
                    } else {
                        AdvancedDashboardView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
                .toolbar { brandToolbar }
            }
            .tabItem { Label("Home", systemImage: "house.fill") }

            NavigationStack {
                LocationsInlineView()
            }
            .tabItem { Label("Locations", systemImage: "mappin.and.ellipse") }

            NavigationStack {
                SettingsView()
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
        }
        .tint(Theme.accent)
        .task { await app.bootstrap() }
    }

    @ToolbarContentBuilder
    private var brandToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.accent)
                Text("Ghost")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            // The mode toggle also lives in Settings; this chip is the
            // always-visible affordance from the mockups.
            Button {
                app.mode = app.mode == .simple ? .advanced : .simple
            } label: {
                Text(app.mode == .simple ? "Simple" : "Advanced")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.accent.opacity(0.14))
                    .foregroundStyle(Theme.accent)
                    .clipShape(Capsule())
            }
            .accessibilityLabel("Switch to \(app.mode == .simple ? "Advanced" : "Simple") mode")
        }
    }
}

/// Locations as a tab (non-sheet) so the tab bar matches the mockups.
private struct LocationsInlineView: View {
    @EnvironmentObject var app: AppState
    @State private var search = ""

    var body: some View {
        LocationsListBody(search: $search)
            .searchable(text: $search, prompt: "Search country or city")
            .navigationTitle("Locations")
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct LocationsListBody: View {
    @EnvironmentObject var app: AppState
    @Binding var search: String

    private var filtered: [VPNServer] {
        guard !search.isEmpty else { return app.servers }
        return app.servers.filter {
            $0.country.localizedCaseInsensitiveContains(search)
                || $0.city.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List(filtered) { server in
            Button {
                guard !server.locked else {
                    app.upgradePrompt = "\(server.city) is a priority location, part of Ghost Plus."
                    return
                }
                app.selectedServer = server
                if app.connection.isConnected {
                    Task {
                        await app.disconnect()
                        await app.connect()
                    }
                }
            } label: {
                HStack(spacing: 14) {
                    Text(server.flagEmoji).font(.system(size: 24))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.country)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(server.locked ? Theme.textSecondary : Theme.textPrimary)
                        Text(server.city)
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                    // Simple mode keeps load numbers out of the way; the
                    // Plus lock still shows so the pool is discoverable.
                    ServerRowDetail(server: server, showsLoad: app.mode == .advanced)
                    if server.id == app.selectedServer?.id {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Theme.background)
            .listRowSeparatorTint(Theme.border)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .refreshable { try? await app.refreshServers() }
    }
}

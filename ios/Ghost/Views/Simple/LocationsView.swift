import SwiftUI

/// Location picker. In Simple mode this is country/city + flag only; Advanced
/// mode surfaces load, ping, and audit status on the same list.
struct LocationsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [VPNServer] {
        guard !search.isEmpty else { return app.servers }
        return app.servers.filter {
            $0.country.localizedCaseInsensitiveContains(search)
                || $0.city.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { server in
                    Button {
                        app.selectedServer = server
                        dismiss()
                        // Selecting while connected re-tunnels to the new exit.
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
                                    .foregroundStyle(Theme.textPrimary)
                                Text(server.city)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textMuted)
                            }
                            Spacer()

                            if app.mode == .advanced {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(server.loadPct)% load")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(loadColor(server.loadPct))
                                    if server.audited {
                                        Label("Audited", systemImage: "checkmark.shield.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Theme.textMuted)
                                    }
                                }
                            } else if server.id == app.servers.first?.id {
                                Text("FASTEST")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Theme.accent.opacity(0.12))
                                    .foregroundStyle(Theme.accent)
                                    .clipShape(Capsule())
                            }

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
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .searchable(text: $search, prompt: "Search country or city")
            .navigationTitle("Locations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.accent)
                }
            }
            .refreshable { try? await app.refreshServers() }
        }
        .preferredColorScheme(.dark)
    }

    private func loadColor(_ pct: Int) -> Color {
        switch pct {
        case ..<40: Theme.accent
        case ..<70: Theme.warning
        default: Theme.danger
        }
    }
}

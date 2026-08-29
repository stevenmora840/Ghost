import SwiftUI

/// Ghost Plus: build a custom 2–3 hop chain. No single server in the chain
/// sees both who you are and where you're going, and picking the hops
/// yourself is what separates this from a fixed double-VPN.
struct MultiHopBuilderView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var chain: [String] = []
    @State private var isSaving = false

    private let minHops = 2
    private let maxHops = 3

    private var chainServers: [VPNServer] {
        chain.compactMap { id in app.servers.first(where: { $0.id == id }) }
    }

    private var available: [VPNServer] {
        app.usableServers.filter { !chain.contains($0.id) }
    }

    private var isValid: Bool { chain.count >= minHops && chain.count <= maxHops }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Traffic passes through each hop in order. More hops means more privacy and more latency.")
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)

                    // Current chain
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            StatLabel(text: "YOUR CHAIN")
                            Spacer()
                            Text("\(chain.count) of \(maxHops) hops")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isValid ? Theme.accent : Theme.warning)
                        }

                        if chain.isEmpty {
                            Card {
                                Text("Add at least \(minHops) locations to build a chain.")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.textMuted)
                            }
                        } else {
                            VStack(spacing: 8) {
                                ForEach(Array(chainServers.enumerated()), id: \.element.id) { index, server in
                                    Card(padding: 12) {
                                        HStack(spacing: 12) {
                                            ZStack {
                                                Circle()
                                                    .fill(Theme.accentBlue.opacity(0.15))
                                                    .frame(width: 26, height: 26)
                                                Text("\(index + 1)")
                                                    .font(.system(size: 12, weight: .bold))
                                                    .foregroundStyle(Theme.accentBlue)
                                            }
                                            Text(server.flagEmoji).font(.system(size: 18))
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(server.city)
                                                    .font(.system(size: 14, weight: .semibold))
                                                    .foregroundStyle(Theme.textPrimary)
                                                Text(hopLabel(index))
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundStyle(Theme.textMuted)
                                            }
                                            Spacer()
                                            Button {
                                                chain.removeAll { $0 == server.id }
                                            } label: {
                                                Image(systemName: "minus.circle.fill")
                                                    .font(.system(size: 18))
                                                    .foregroundStyle(Theme.danger)
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel("Remove \(server.city) from chain")
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Add hops
                    if chain.count < maxHops {
                        VStack(alignment: .leading, spacing: 10) {
                            StatLabel(text: "ADD A HOP")
                            VStack(spacing: 8) {
                                ForEach(available) { server in
                                    Button {
                                        chain.append(server.id)
                                    } label: {
                                        Card(padding: 12) {
                                            HStack(spacing: 12) {
                                                Text(server.flagEmoji).font(.system(size: 18))
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(server.city)
                                                        .font(.system(size: 14, weight: .semibold))
                                                        .foregroundStyle(Theme.textPrimary)
                                                    Text(server.country)
                                                        .font(.caption)
                                                        .foregroundStyle(Theme.textMuted)
                                                }
                                                Spacer()
                                                ServerRowDetail(server: server)
                                                Image(systemName: "plus.circle.fill")
                                                    .font(.system(size: 18))
                                                    .foregroundStyle(Theme.accent)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("Multi-Hop Chain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            isSaving = true
                            await app.saveMultiHopChain(chain)
                            isSaving = false
                            dismiss()
                        }
                    } label: {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save").fontWeight(.semibold)
                        }
                    }
                    .disabled(!isValid || isSaving)
                    .foregroundStyle(isValid ? Theme.accent : Theme.textMuted)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { chain = app.multiHopChain }
    }

    private func hopLabel(_ index: Int) -> String {
        if index == 0 { return "ENTRY" }
        if index == chain.count - 1 { return "EXIT" }
        return "MIDDLE"
    }
}

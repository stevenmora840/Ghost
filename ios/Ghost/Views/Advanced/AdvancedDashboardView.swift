import SwiftUI

/// Advanced mode home: the bento-grid dashboard — status, protocol, kill
/// switch, ping, load, and usage all visible at once. Same tokens and type
/// scale as Simple mode, higher density.
struct AdvancedDashboardView: View {
    @EnvironmentObject var app: AppState
    @State private var showConfig = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                connectionCard

                LazyVGrid(columns: columns, spacing: 12) {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            StatLabel(text: "PROTOCOL")
                            HStack(spacing: 8) {
                                Image(systemName: "bolt.horizontal.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.accentBlue)
                                Text(app.tunnelProtocol.rawValue)
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .foregroundStyle(Theme.textPrimary)
                            }
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            StatLabel(text: "KILL SWITCH")
                            HStack {
                                Text(app.killSwitchEnabled ? "Active" : "Off")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Toggle("", isOn: $app.killSwitchEnabled)
                                    .labelsHidden()
                                    .tint(Theme.accent)
                                    .scaleEffect(0.8)
                            }
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            StatLabel(text: "PING")
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(app.connection.isConnected ? "\(app.stats.pingMs)" : "—")
                                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("ms")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                Circle()
                                    .fill(app.connection.isConnected ? Theme.accent : Theme.textMuted)
                                    .frame(width: 7, height: 7)
                            }
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            StatLabel(text: "SERVER LOAD")
                            Text("\(app.selectedServer?.loadPct ?? 0)%")
                                .font(.system(size: 22, weight: .heavy, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.surfaceRaised)
                                    Capsule()
                                        .fill(Theme.accent)
                                        .frame(width: geo.size.width * CGFloat(app.selectedServer?.loadPct ?? 0) / 100)
                                }
                            }
                            .frame(height: 5)
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        StatLabel(text: "DATA USAGE THIS SESSION")
                        HStack(spacing: 22) {
                            Label(app.stats.bytesUp.byteString, systemImage: "arrow.up")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Theme.accentBlue)
                            Label(app.stats.bytesDown.byteString, systemImage: "arrow.down")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Theme.accent)
                        }
                        .monospacedDigit()
                    }
                }

                Button {
                    showConfig = true
                } label: {
                    Card {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                StatLabel(text: "SERVER & PROTOCOL")
                                Text("Split tunneling, multi-hop, obfuscation")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
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
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        .sheet(isPresented: $showConfig) {
            ServerConfigView()
        }
    }

    private var connectionCard: some View {
        Card(padding: 16) {
            VStack(spacing: 14) {
                HStack {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(app.connection.isConnected ? Theme.accent : Theme.textMuted)
                            .frame(width: 9, height: 9)
                            .shadow(color: (app.connection.isConnected ? Theme.accent : .clear).opacity(0.4), radius: 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.connection.isConnected ? "Protected" : "Not protected")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(app.connection.isConnected ? Theme.accent : Theme.textPrimary)
                            if let s = app.selectedServer {
                                Text("\(s.city), \(s.countryCode) — \(s.id)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    Spacer()
                    Button {
                        Task { await app.toggleConnection() }
                    } label: {
                        Group {
                            if app.connection.isBusy {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(app.connection.isConnected ? "Disconnect" : "Connect")
                                    .font(.system(size: 12, weight: .bold))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                    .background(app.connection.isConnected ? Theme.surface : Theme.accent)
                    .foregroundStyle(app.connection.isConnected ? Theme.textPrimary : Theme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(app.connection.isConnected ? Theme.borderStrong : .clear)
                    )
                }

                Divider().overlay(Theme.border)

                HStack {
                    if case let .connected(since) = app.connection {
                        UptimeText(since: since)
                    } else {
                        Text("Tunnel down")
                            .font(.caption2)
                            .foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                    Text(app.connection.isConnected ? "Exit IP hidden" : "Real IP exposed")
                        .font(.caption2)
                        .foregroundStyle(app.connection.isConnected ? Theme.textMuted : Theme.warning)
                }
            }
        }
    }
}

private struct UptimeText: View {
    let since: Date
    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let s = Int(context.date.timeIntervalSince(since))
            Text("Uptime  \(String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60))")
                .font(.caption2)
                .foregroundStyle(Theme.textMuted)
                .monospacedDigit()
        }
    }
}

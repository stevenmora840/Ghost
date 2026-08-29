import SwiftUI

/// Simple mode home: one dominant action, plain-language status, no jargon.
struct SimpleHomeView: View {
    @EnvironmentObject var app: AppState
    @State private var showLocations = false

    var body: some View {
        VStack(spacing: 26) {
            Spacer()

            ConnectButton()

            VStack(spacing: 6) {
                Text(statusTitle)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(app.connection.isConnected ? Theme.accent : Theme.textPrimary)
                Text(statusSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            .animation(.easeInOut(duration: 0.2), value: app.connection)

            Button {
                showLocations = true
            } label: {
                Card {
                    HStack(spacing: 12) {
                        Text(app.selectedServer?.flagEmoji ?? "🌐")
                            .font(.system(size: 24))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(locationTitle)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Fastest available server")
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

            if case let .connected(since) = app.connection {
                SessionTicker(since: since, bytesDown: app.stats.bytesDown)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .sheet(isPresented: $showLocations) {
            LocationsView()
        }
    }

    private var statusTitle: String {
        switch app.connection {
        case .connected: "Protected"
        case .connecting: "Connecting…"
        case .disconnecting: "Disconnecting…"
        case .disconnected: "Not protected"
        }
    }

    private var statusSubtitle: String {
        app.connection.isConnected
            ? "Your connection is encrypted"
            : "Tap the button to secure your connection"
    }

    private var locationTitle: String {
        guard let s = app.selectedServer else { return "Choose a location" }
        return "\(s.city), \(s.country)"
    }
}

/// The big circular connect control — Simple mode's single primary action.
struct ConnectButton: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Button {
            Task { await app.toggleConnection() }
        } label: {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [ringColor.opacity(0.18), .clear],
                            center: .center, startRadius: 60, endRadius: 150
                        )
                    )
                    .frame(width: 300, height: 300)

                Circle()
                    .fill(Theme.surface)
                    .frame(width: 224, height: 224)
                    .overlay(Circle().stroke(ringColor, lineWidth: 2))
                    .shadow(color: ringColor.opacity(0.25), radius: 30, y: 12)

                Circle()
                    .fill(Theme.surfaceRaised)
                    .frame(width: 180, height: 180)

                if app.connection.isBusy {
                    ProgressView()
                        .controlSize(.large)
                        .tint(ringColor)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 46, weight: .medium))
                        .foregroundStyle(ringColor)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: 300, height: 260)
        .accessibilityLabel(app.connection.isConnected ? "Disconnect VPN" : "Connect VPN")
        .animation(.easeInOut(duration: 0.25), value: app.connection)
    }

    private var ringColor: Color {
        app.connection.isConnected || app.connection == .connecting ? Theme.accent : Theme.textMuted
    }
}

private struct SessionTicker: View {
    let since: Date
    let bytesDown: Int64

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let elapsed = Int(context.date.timeIntervalSince(since))
            Text("Session \(format(elapsed))  ·  \(bytesDown.byteString) used")
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
                .monospacedDigit()
        }
    }

    private func format(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}

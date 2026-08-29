import SwiftUI

/// Small "PLUS" chip marking paid-tier surfaces.
struct PlusBadge: View {
    var body: some View {
        Text("PLUS")
            .font(.system(size: 9, weight: .black))
            .tracking(0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Theme.accentBlue.opacity(0.16))
            .foregroundStyle(Theme.accentBlue)
            .clipShape(Capsule())
    }
}

/// Trailing detail for a server row: load, audit status, and the lock that
/// marks a priority location this account can't use.
struct ServerRowDetail: View {
    let server: VPNServer
    var showsLoad: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            if server.locked {
                PlusBadge()
                Image(systemName: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    if showsLoad {
                        Text("\(server.loadPct)% load")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(loadColor)
                    }
                    if server.priority {
                        Label("Priority", systemImage: "bolt.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.accentBlue)
                    } else if server.audited {
                        Label("Audited", systemImage: "checkmark.shield.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
    }

    private var loadColor: Color {
        switch server.loadPct {
        case ..<40: Theme.accent
        case ..<70: Theme.warning
        default: Theme.danger
        }
    }
}

/// Shown when a paid-only action is attempted. Billing isn't built yet, so
/// the action button flips the tier through the development endpoint —
/// replace with the purchase flow when StoreKit lands.
struct UpgradeSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let message: String

    private let perks = [
        ("bolt.fill", "Priority servers", "A low-load pool reserved for Plus members."),
        ("arrow.triangle.branch", "Custom multi-hop", "Route through 2–3 locations you pick yourself."),
        ("flame.fill", "Panic wipe", "Destroy your keys and identity in one tap."),
    ]

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Image(systemName: "bolt.shield.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.accentBlue)
                Text("Ghost Plus")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 32)

            VStack(spacing: 12) {
                ForEach(perks, id: \.1) { icon, title, detail in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: icon)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.accentBlue)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                    }
                }
            }

            Spacer()

            VStack(spacing: 10) {
                Button {
                    Task {
                        await app.setTier(.paid)
                        dismiss()
                    }
                } label: {
                    Text("Upgrade to Plus")
                        .font(.system(size: 16, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .background(Theme.accent)
                .foregroundStyle(Theme.background)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))

                Text("Development build — no payment is taken.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)

                Button("Not now") { dismiss() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(24)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }
}

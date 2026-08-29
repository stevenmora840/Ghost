import SwiftUI

/// Ghost's design tokens, matching the published UI mockups.
/// Dark-first: the app commits to the dark aesthetic in v1.
enum Theme {
    static let background = Color(hex: 0x0A0C10)
    static let surface = Color(hex: 0x14171D)
    static let surfaceRaised = Color(hex: 0x1C2027)
    static let border = Color(hex: 0x262B33)
    static let borderStrong = Color(hex: 0x333A45)

    static let accent = Color(hex: 0x35D0A0)      // teal — protected / on
    static let accentBlue = Color(hex: 0x4C9EEB)  // secondary — data / protocol
    static let warning = Color(hex: 0xD9A441)
    static let danger = Color(hex: 0xE05B5B)

    static let textPrimary = Color(hex: 0xF2F4F7)
    static let textSecondary = Color(hex: 0x939AA8)
    static let textMuted = Color(hex: 0x5B626F)

    static let cornerRadius: CGFloat = 14
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Card container used across both modes so Simple and Advanced read as one app.
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }
}

/// Small uppercase section label ("PROTOCOL", "KILL SWITCH", …).
struct StatLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Theme.textMuted)
    }
}

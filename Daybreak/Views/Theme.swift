import SwiftUI

/// Daybreak's visual language: deep night-sky ink with a warm dawn gradient.
enum Theme {
    // Palette
    static let ink        = Color(red: 0.043, green: 0.051, blue: 0.102)   // #0B0D1A night sky
    static let inkRaised  = Color(red: 0.082, green: 0.094, blue: 0.165)   // #15182A cards
    static let inkBorder  = Color.white.opacity(0.07)
    static let dawnAmber  = Color(red: 1.00, green: 0.72, blue: 0.30)      // #FFB84D
    static let dawnCoral  = Color(red: 1.00, green: 0.45, blue: 0.38)      // #FF7361
    static let dawnViolet = Color(red: 0.55, green: 0.42, blue: 0.95)      // #8C6BF2
    static let textDim    = Color.white.opacity(0.55)
    static let textFaint  = Color.white.opacity(0.35)

    static let dawn = LinearGradient(
        colors: [dawnAmber, dawnCoral],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let nightSky = LinearGradient(
        colors: [Color(red: 0.07, green: 0.06, blue: 0.16), ink],
        startPoint: .top, endPoint: .bottom
    )

    /// Big clock numerals — rounded for warmth.
    static func clock(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Theme.inkRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(Theme.inkBorder, lineWidth: 1)
                    )
            )
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

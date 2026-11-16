import SwiftUI
import UIKit

/// The Flutter app's fixed colours (`lib/theme/app_theme.dart`), light and dark.
enum Palette {
    static let background = Color(light: 0xF2F2F7, dark: 0x000000)
    static let surface = Color(light: 0xFFFFFF, dark: 0x121212)
    /// `AppTheme.lightCard` and `darkCard`: Home's and Search's media cards.
    static let card = Color(light: 0xFFFFFF, dark: 0x181818)
    static let secondaryText = Color(light: 0x8E8E93, dark: 0xB3B3B3)
    static let divider = Color(light: 0xE5E5EA, dark: 0x404040)
    /// The add-server form's filled fields.
    static let fieldFill = Color(light: 0xF3F4F6, dark: 0x222222)
    /// Hairline borders: black 6 % / white 10 %.
    static let hairline = Color(light: .black.withAlphaComponent(0.06), dark: .white.withAlphaComponent(0.10))
    /// The Red accent's colour, as a fixed red (errors, badges, the recap); not the default accent
    /// since C54 (D193).
    static let accentRed = Color(hex: 0xFA243C)
    /// The accent colour chosen in Settings → Display (purple unless changed, D193). Read inside a
    /// view's body, it redraws the view when the choice changes. Use it, not `Color.accentColor`,
    /// which stays the asset's default purple.
    static var accent: Color { AppearanceModel.shared.accent.color }
    static let green = Color(hex: 0x34C759)
    static let orange = Color(hex: 0xFF9500)
    /// The Subsonic server icon's gradient.
    static let serverGradient = LinearGradient(
        colors: [Color(hex: 0x6366F1), Color(hex: 0x8B5CF6)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension Color {
    nonisolated init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    init(light: UInt32, dark: UInt32) {
        self.init(light: UIColor(Color(hex: light)), dark: UIColor(Color(hex: dark)))
    }

    /// Nonisolated: the closure runs wherever SwiftUI resolves the colour, which during an animated
    /// render is off the main thread. Isolated to the main actor (this target's default), it crashes there.
    nonisolated init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

import Observation
import SwiftUI
import UIKit

/// Settings → Display → Appearance: the theme and the accent colour (Flutter `ThemeService`), kept
/// in `UserDefaults`. One model for the app (`shared`), so `Palette.accent` can read it anywhere and
/// every view that draws the accent redraws when it changes.
@Observable
final class AppearanceModel {
    static let shared = AppearanceModel()

    nonisolated enum Theme: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: Self { self }

        var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        var systemImage: String {
            switch self {
            case .system: "circle.lefthalf.filled"
            case .light: "sun.max.circle.fill"
            case .dark: "moon.circle.fill"
            }
        }

        var interfaceStyle: UIUserInterfaceStyle {
            switch self {
            case .system: .unspecified
            case .light: .light
            case .dark: .dark
            }
        }
    }

    /// Flutter `AccentColor`, without Material You, which on an iPhone is a fixed purple (D64).
    /// Purple is the default since C54 (D193): Flutter's red default is Apple Music's red.
    nonisolated enum Accent: String, CaseIterable, Identifiable {
        case red, pink, orange, yellow, green, blue, purple
        var id: Self { self }

        /// The accent of anyone who never chose one. A choice that was made is kept as it is.
        static let standard: Self = .purple

        var hex: UInt32 {
            switch self {
            case .red: 0xFA243C
            case .pink: 0xFC5C65
            case .orange: 0xFF9500
            case .yellow: 0xFFCC00
            case .green: 0x1DB954
            case .blue: 0x007AFF
            case .purple: 0x8B5CF6
            }
        }

        var color: Color { Color(hex: hex) }
        var title: String { rawValue.capitalized }
    }

    static let themeKey = "app_theme_mode"
    static let accentKey = "app_accent_color"

    var theme: Theme {
        didSet {
            defaults.set(theme.rawValue, forKey: Self.themeKey)
            applyToWindows()
        }
    }

    var accent: Accent {
        didSet {
            defaults.set(accent.rawValue, forKey: Self.accentKey)
            applyToWindows()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = defaults.string(forKey: Self.themeKey).flatMap(Theme.init) ?? .system
        accent = defaults.string(forKey: Self.accentKey).flatMap(Accent.init) ?? Accent.standard
    }

    /// The theme and the accent reach UIKit's own pieces too (alerts, menus, sheets), through the
    /// windows. Setting the windows' style, rather than `preferredColorScheme`, lets "System" follow
    /// the phone again straight away.
    func applyToWindows() {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows {
            window.overrideUserInterfaceStyle = theme.interfaceStyle
            window.tintColor = UIColor(accent.color)
        }
    }
}

extension View {
    /// The root's appearance: the accent as the tint, and the theme on the windows.
    func appAppearance(_ appearance: AppearanceModel) -> some View {
        tint(appearance.accent.color)
            .onAppear { appearance.applyToWindows() }
            .task { appearance.applyToWindows() }
    }
}

import Observation
import SwiftUI
import UIKit

/// Settings → Display → App Icon (C52, D186): the seven home screen icons, all the treble clef drawn
/// by `docs/art/make-icon.swift` on a different ground. Red left the choices in C54 (D192): it was
/// too close to another app's icon; `make-icon.swift` can still draw it. White and Black, plain and flat,
/// came in 1.0.1 (D235), and White became the primary icon (`AppIcon`; Indigo was until then); each
/// other one is the alternate icon `AppIcon-<title>`, listed in the build setting
/// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`. Its own choice: nothing here touches the accent.
nonisolated enum AppIconChoice: String, CaseIterable, Identifiable {
    case white, black, indigo, violet, teal, amber, graphite
    var id: Self { self }

    /// The primary icon, which iOS shows when no alternate is set.
    static let standard: Self = .white

    var title: String { rawValue.capitalized }

    /// The name `setAlternateIconName` takes: `nil` puts the primary icon back.
    var alternateIconName: String? { self == Self.standard ? nil : "AppIcon-\(title)" }

    /// The option's light and dark picture as an ordinary image set (an app can't draw an icon set),
    /// for the picker's tile. The in-app logo is the plain clef instead (`Logo`, D187).
    var previewImageName: String { "IconPreview-\(title)" }

    var accessibilityIdentifier: String { "appIcon-\(rawValue)" }

    /// The option iOS is showing, from `UIApplication.alternateIconName`: `nil`, or a name this
    /// build doesn't know, is the primary icon.
    static func matching(alternateIconName name: String?) -> Self {
        allCases.first { $0.alternateIconName == name } ?? standard
    }

    /// Whether a tap on this option has anything to ask iOS for, judged by what iOS shows now and not
    /// by what the picker last thought (C54 part 4): Indigo while an old Red still shows must go through.
    func needsChange(fromAlternateIconName name: String?) -> Bool {
        alternateIconName != name
    }

    /// Whether iOS is showing an alternate this build no longer has (an earlier build's Red, C54), so
    /// the primary icon must be put back: `nil` and every current option's name are fine.
    static func isRetired(alternateIconName name: String?) -> Bool {
        guard let name else { return false }
        return !allCases.contains { $0.alternateIconName == name }
    }
}

/// The icon the home screen shows. iOS keeps the choice (`alternateIconName`); this only mirrors it
/// for the views, so nothing goes into `UserDefaults`. The mirror is read again from iOS on every tap
/// and every return to the app, so it can't hold on to a choice iOS didn't make.
@Observable
final class AppIconModel {
    static let shared = AppIconModel()

    private(set) var current: AppIconChoice
    private(set) var isChanging = false

    /// Whether iOS lets this app change its icon at all. True on an iPhone, and on an iPad running the
    /// app now that `Config/Navinx-Info.plist` lists the `~ipad` alternates (C56); if iOS ever says no,
    /// Display hides the section rather than offer a choice that can only fail.
    let isAvailable: Bool

    private init() {
        current = AppIconChoice.matching(alternateIconName: UIApplication.shared.alternateIconName)
        isAvailable = UIApplication.shared.supportsAlternateIcons
    }

    /// Asks iOS for the new icon (it shows its own "You have changed the icon" alert). On failure the
    /// selection is what iOS still shows and the error goes to the caller.
    func choose(_ choice: AppIconChoice) async throws {
        guard !isChanging else { return }
        let showing = UIApplication.shared.alternateIconName
        current = AppIconChoice.matching(alternateIconName: showing)
        guard choice.needsChange(fromAlternateIconName: showing) else { return }
        isChanging = true
        defer {
            isChanging = false
            current = AppIconChoice.matching(alternateIconName: UIApplication.shared.alternateIconName)
        }
        try await UIApplication.shared.setAlternateIconName(choice.alternateIconName)
    }

    /// Each time the app becomes active: an icon an earlier build offered and this one doesn't (Red,
    /// C54) goes back to the primary icon. iOS can refuse it (at a cold launch, say), so it is tried
    /// again on the next return until it works; after that `alternateIconName` is `nil` and this only
    /// reads it.
    func retireRemovedIcon() async {
        guard !isChanging else { return }
        let showing = UIApplication.shared.alternateIconName
        current = AppIconChoice.matching(alternateIconName: showing)
        guard AppIconChoice.isRetired(alternateIconName: showing) else { return }
        isChanging = true
        defer {
            isChanging = false
            current = AppIconChoice.matching(alternateIconName: UIApplication.shared.alternateIconName)
        }
        try? await UIApplication.shared.setAlternateIconName(nil)
    }
}

/// An app icon's outline at any size: continuous corners at 22.5 % of the side.
nonisolated struct IconTileShape: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        return Path(roundedRect: r, cornerRadius: min(r.width, r.height) * 0.225, style: .continuous)
    }

    func inset(by amount: CGFloat) -> Self {
        var shape = self
        shape.inset += amount
        return shape
    }
}

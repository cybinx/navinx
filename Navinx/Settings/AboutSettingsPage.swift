import SwiftUI
import UIKit

/// Flutter `SettingsAboutTab`, cut to the app's version and platform, and a credit to the app it's
/// rewritten from (D54), not a link since C54. Upstream Musly's updates, links, tour and support rows
/// go; Navinx's own Privacy Policy and Support rows open its public pages instead (D181). Its Playback row
/// is here all year (C23, D92), with no seasonal screen, Test Mode or eight-tap unlock.
struct AboutSettingsPage: View {
    @Environment(\.openURL) private var openURL
    @State private var isPlaybackOpen = false

    var body: some View {
        VStack(spacing: 24) {
            SettingsSection(title: "INFORMATION") {
                SettingsRow(title: "Version") {
                    tintedIcon("tag", color: Palette.accent)
                } trailing: {
                    // Unsized, the title's priority squeezed it to nothing and the row grew tall (found in C23).
                    Text(Self.version).fixedSize().accessibilityIdentifier("aboutVersion")
                }
                SettingsRule()
                SettingsRow(title: "Platform") {
                    tintedIcon("iphone.gen3", color: Color(hex: 0x007AFF))
                } trailing: {
                    Text(Self.platform).fixedSize().accessibilityIdentifier("aboutPlatform")
                }
            }
            // Not in Flutter: Apple wants the policy linked in the app (D181). Opens in the browser.
            SettingsSection(title: "SUPPORT") {
                SettingsRow(
                    title: "Privacy Policy",
                    subtitle: "How Navinx handles your data",
                    action: { openURL(PublicPages.privacyPolicy) }
                ) {
                    SettingsGlyph("lock.shield", colors: gradient(0x34C759, 0x30D158))
                } trailing: {
                    Image(systemName: "arrow.up.forward").font(.system(size: 17))
                }
                .accessibilityIdentifier("aboutPrivacy")
                SettingsRule()
                SettingsRow(
                    title: "Support",
                    subtitle: "Help and contact",
                    action: { openURL(PublicPages.support) }
                ) {
                    SettingsGlyph("lifepreserver", colors: gradient(0x007AFF, 0x5AC8FA))
                } trailing: {
                    Image(systemName: "arrow.up.forward").font(.system(size: 17))
                }
                .accessibilityIdentifier("aboutSupport")
            }
            // A credit, not a link (C54, the second App Store check): nothing to tap.
            SettingsSection(title: "THANKS") {
                SettingsRow(title: "Thank you, dddevid", subtitle: "Author of Musly") {
                    SettingsGlyph("hands.clap.fill", colors: gradient(0x5856D6, 0xAF52DE))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("aboutMusly")
            }
            SettingsSection(title: "YEAR IN REVIEW") {
                SettingsRow(
                    title: "Navinx Playback",
                    subtitle: "Your annual Year in Review and listening insights",
                    action: { isPlaybackOpen = true }
                ) {
                    tintedIcon("calendar", color: Palette.accentRed)
                } trailing: {
                    Image(systemName: "chevron.forward").font(.system(size: 14, weight: .semibold))
                }
                .accessibilityIdentifier("aboutPlayback")
            }
        }
        .fullScreenCover(isPresented: $isPlaybackOpen) { RecapView() }
    }

    /// The bundle's version, with its build number when there is one: "1.0 (1)".
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return short }
        return "\(short) (\(build))"
    }

    /// "iOS 27.2" (Flutter showed "IOS").
    static var platform: String {
        "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    }

    /// Flutter's info tiles: the glyph on a pale square of its own colour.
    private func tintedIcon(_ systemImage: String, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(color.opacity(0.15))
            .frame(width: 32, height: 32)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(color)
            }
            .accessibilityHidden(true)
    }
}

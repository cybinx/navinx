import Foundation

/// Navinx's public pages (D181): the privacy policy Apple wants linked in the app, and help. About's
/// two rows and the sign-in screen's two links (C54) open the same addresses, in the browser.
nonisolated enum PublicPages {
    static let privacyPolicy = URL(string: "https://cybinx.github.io/navinx/privacy/")!
    static let support = URL(string: "https://cybinx.github.io/navinx/support/")!
}

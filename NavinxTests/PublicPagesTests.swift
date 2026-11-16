import Foundation
import Testing
@testable import Navinx

/// About's Privacy Policy and Support rows (D181), and the sign-in screen's links (C54), open Navinx's
/// public pages.
@MainActor @Suite struct PublicPagesTests {
    @Test func pageAddresses() {
        let pages = [
            (PublicPages.privacyPolicy, "/navinx/privacy/"),
            (PublicPages.support, "/navinx/support/"),
        ]
        for (url, path) in pages {
            #expect(url.scheme == "https")
            #expect(url.host() == "cybinx.github.io")
            #expect(url.path(percentEncoded: false) == path)
        }
    }
}

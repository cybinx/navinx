import CryptoKit
import Foundation
import SubsonicKit

/// Which account a saved login is: its profile ID, its main address and its username. Edit Server can
/// point a profile at another server or another username and keep its ID (the ID keeps the downloads
/// and the device's approval when a server only moved), so the ID alone can't tell that the account
/// changed. Everything that must start again for another account follows this instead: the tabs and
/// their models, the library's saved copy, the widgets, Spotlight and the intents' lists. A new
/// password or home-network address is the same account and changes nothing here.
nonisolated struct AccountKey: Hashable, Sendable {
    let profileID: UUID
    /// The main address (in its one form) and the username (as the sign-in compares it: no spaces
    /// around it, any case), hashed, so no address or username is written where this one is.
    let login: String

    init(profileID: UUID, serverURL: String, username: String) {
        self.profileID = profileID
        let address = ServerConfig.normalize(serverURL, defaultScheme: "https")
        let user = username.trimmingCharacters(in: .whitespaces).lowercased()
        let digest = SHA256.hash(data: Data("\(address)\u{0}\(user)".utf8))
        login = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// The key as text, for files and saved marks.
    var mark: String { "\(profileID.uuidString)-\(login)" }
}

extension ServerProfile {
    nonisolated var accountKey: AccountKey {
        AccountKey(profileID: id, serverURL: serverURL, username: username)
    }
}

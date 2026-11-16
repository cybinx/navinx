import Foundation
import SubsonicKit

/// One saved server login: the Flutter app's `ServerConfig` (`lib/models/server_config.dart`),
/// Subsonic only (D4), without the certificate options (D11). The password isn't here: it's in
/// the Keychain (`ProfileStore`).
nonisolated struct ServerProfile: Codable, Hashable, Identifiable, Sendable {
    /// Stable across renames. Flutter keys profiles by address, username and name, so a rename
    /// saved a second copy; Swift renames in place (the user's call, C2).
    var id: UUID
    var serverURL: String
    var homeNetworkURL: String?
    var username: String
    var sendsPlainPassword: Bool
    /// The optional "Profile Name".
    var name: String?
    /// From `ping` (`navidrome`, …), shown when there's no name.
    var serverType: String?
    var serverVersion: String?

    /// The keys of the saved logins (`server_profiles`, `server_config`), written out so that a renamed
    /// property never moves them: a moved key signs everyone out (D8). Kept as the earlier builds wrote
    /// them (C43); changing one needs a move at launch (C43's step 2).
    private enum CodingKeys: String, CodingKey {
        case id = "id"
        case serverURL = "serverURL"
        case homeNetworkURL = "lanURL"
        case username = "username"
        case sendsPlainPassword = "useLegacyAuth"
        case name = "name"
        case serverType = "serverType"
        case serverVersion = "serverVersion"
    }

    init(
        id: UUID = UUID(),
        serverURL: String,
        homeNetworkURL: String? = nil,
        username: String,
        sendsPlainPassword: Bool = false,
        name: String? = nil,
        serverType: String? = nil,
        serverVersion: String? = nil
    ) {
        self.id = id
        self.serverURL = serverURL
        self.homeNetworkURL = homeNetworkURL
        self.username = username
        self.sendsPlainPassword = sendsPlainPassword
        self.name = name
        self.serverType = serverType
        self.serverVersion = serverVersion
    }

    /// Flutter `displayServerName`: the profile name, else the server type, else a generic label.
    var shownServerName: String {
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        if let serverType, !serverType.isEmpty { return serverType }
        return "Navidrome / Subsonic"
    }

    /// Flutter `displayUrl`: the host, else the address as typed.
    var displayURL: String {
        if serverURL.isEmpty { return "Not configured" }
        if let host = URL(string: serverURL)?.host(), !host.isEmpty { return host }
        return serverURL
    }

    /// The login screen's saved-profile chip: the name, else `username@host`.
    var chipLabel: String {
        if let name, !name.isEmpty { return name }
        return "\(username)@\(URL(string: serverURL)?.host() ?? serverURL)"
    }

    /// The connection settings for `SubsonicKit`.
    func config(password: String) -> ServerConfig {
        ServerConfig(
            serverURL: serverURL,
            homeNetworkURL: homeNetworkURL,
            username: username,
            password: password,
            sendsPlainPassword: sendsPlainPassword
        )
    }

    /// Flutter `StorageService.saveProfile`'s match: logging in again with the same address,
    /// username and profile name updates that profile instead of adding another. Addresses compare
    /// in one form, so one saved before addresses were stored that way ("https://host/") still matches.
    func isSameLogin(as other: ServerProfile) -> Bool {
        ServerConfig.normalize(serverURL, defaultScheme: "https")
            == ServerConfig.normalize(other.serverURL, defaultScheme: "https")
            && username == other.username && (name ?? "") == (other.name ?? "")
    }
}

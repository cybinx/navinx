import Foundation

/// What the client needs to reach one Subsonic/Navidrome server: the connection half of the
/// Flutter app's `ServerConfig`. Profiles (name, server type, version) and where the password is
/// stored (the Keychain) are the app's job (C2).
public struct ServerConfig: Sendable, Hashable {
    /// The address as typed. With no scheme, `https://` is assumed (`normalizedURL`).
    public var serverURL: String
    /// An optional home-network address, tried first for 3 seconds on connect (the Flutter
    /// add-server screen's "LAN URL"). With no scheme, `http://` is assumed.
    public var homeNetworkURL: String?
    public var username: String
    public var password: String
    /// Flutter's "Legacy Authentication": send the password as `p=` instead of a token and salt.
    public var sendsPlainPassword: Bool

    public init(
        serverURL: String,
        homeNetworkURL: String? = nil,
        username: String,
        password: String,
        sendsPlainPassword: Bool = false
    ) {
        self.serverURL = serverURL
        self.homeNetworkURL = homeNetworkURL
        self.username = username
        self.password = password
        self.sendsPlainPassword = sendsPlainPassword
    }

    /// The server address with a scheme (`https://` by default) and no trailing slash.
    public var normalizedURL: String {
        Self.normalize(serverURL, defaultScheme: "https")
    }

    /// The LAN address with a scheme (`http://` by default) and no trailing slash, or nil if unset.
    public var normalizedHomeNetworkURL: String? {
        guard let homeNetworkURL, !homeNetworkURL.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return Self.normalize(homeNetworkURL, defaultScheme: "http")
    }

    /// True when the address, username and password are all filled in.
    public var isValid: Bool {
        !serverURL.isEmpty && !username.isEmpty && !password.isEmpty
    }

    /// One form per address, so the same server typed two ways is one profile: a scheme (either
    /// case), the scheme and host in lower case (never the path), and no query, fragment or trailing
    /// slashes, so a pasted web-page address like `https://host/app/#/login` keeps the API path out
    /// of the fragment. Already-normal addresses come back unchanged.
    public static func normalize(_ raw: String, defaultScheme: String) -> String {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = url.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            url = "\(defaultScheme)://\(url)"
        }
        if let cut = url.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            url = String(url[..<cut])
        }
        while url.hasSuffix("/") {
            url.removeLast()
        }
        guard let separator = url.range(of: "://") else { return url }
        let pathStart = url[separator.upperBound...].firstIndex(of: "/") ?? url.endIndex
        // A user and password before the host keep their case.
        var hostStart = separator.upperBound
        if let at = url[separator.upperBound..<pathStart].lastIndex(of: "@") {
            hostStart = url.index(after: at)
        }
        let scheme = String(url[..<separator.lowerBound]).lowercased()
        let user = String(url[separator.upperBound..<hostStart])
        let host = String(url[hostStart..<pathStart]).lowercased()
        let path = String(url[pathStart...])
        return scheme + "://" + user + host + path
    }

    /// True when the address has a user (and password) before the host, `https://me:pw@host`. A new
    /// sign-in refuses it: the username and password have their own fields, and in the address they'd
    /// be stored and shown with it. Up to the first `/`, so a `#` or `?` in that password still counts.
    public static func hasUserInfo(_ raw: String) -> Bool {
        var rest = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if let separator = rest.range(of: "://") { rest = rest[separator.upperBound...] }
        return rest.prefix { $0 != "/" }.contains("@")
    }
}

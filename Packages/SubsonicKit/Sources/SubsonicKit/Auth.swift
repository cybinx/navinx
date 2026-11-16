import CryptoKit
import Foundation

/// Subsonic authentication and URL building.
///
/// Token auth (the default): `t = md5(password + salt)` and `s = salt`, so the password never
/// travels. Legacy auth sends `p = password`. Like the Flutter app, API calls and stream/download
/// URLs get a fresh salt each time, while cover-art URLs use one stable salt so the same image
/// always has the same URL (and the image cache works).
enum Auth {
    /// The client name sent as `c` (D10, D123: "Navinx"; the Flutter app sends "Musly").
    static let clientName = "Navinx"
    /// The Subsonic API version sent as `v` (the Flutter app's).
    static let apiVersion = "1.16.1"

    static func token(password: String, salt: String) -> String {
        Insecure.MD5.hash(data: Data((password + salt).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// A random lowercase-hex salt.
    static func makeSalt(length: Int = 8) -> String {
        let hex = Array("0123456789abcdef")
        return String((0..<length).map { _ in hex[Int.random(in: 0..<16)] })
    }

    /// `v`, `c` and `f`: what every request says about the client, with no login in it. Alone,
    /// they are the home-network probe's whole query (`SubsonicClient.connect`).
    static let clientItems: [(String, String)] = [
        ("v", apiVersion),
        ("c", clientName),
        ("f", "json"),
    ]

    /// `u`, `v`, `c`, `f`, then `t` + `s` (or `p`), in the Flutter app's order.
    static func queryItems(for config: ServerConfig, salt: String) -> [(String, String)] {
        var items = [("u", config.username)] + clientItems
        if config.sendsPlainPassword {
            items.append(("p", config.password))
        } else {
            items.append(("t", token(password: config.password, salt: salt)))
            items.append(("s", salt))
        }
        return items
    }

    /// `<base>/rest/<endpoint>?<query>`, every key and value percent-encoded except RFC 3986's
    /// unreserved characters (so `&`, `+`, `=` and `%` in a password or search survive).
    static func url(base: URL, endpoint: String, items: [(String, String)]) -> URL {
        let query = items
            .map { "\(encode($0.0))=\(encode($0.1))" }
            .joined(separator: "&")
        let string = base.absoluteString + "/rest/" + endpoint + "?" + query
        guard let url = URL(string: string) else {
            preconditionFailure("unbuildable Subsonic URL for \(endpoint)")
        }
        return url
    }

    private static let unreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    static func encode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }
}

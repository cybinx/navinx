import Foundation
import SubsonicKit

/// The login screens' error texts, ported from Flutter: `AuthProvider._formatError` (the message),
/// `LoginScreen._categoriseError` (the icon, colour and hint) and `_isRemoteInsecureHttp`.
nonisolated enum SignInFailure {
    /// The message shown for a failed login or ping.
    static func message(for error: any Error) -> String {
        let raw = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return format(raw)
    }

    /// Flutter `_formatError`, matching the same phrases in the same order. Both certificate
    /// branches read alike here: Flutter's point to the dropped certificate options (D11).
    static func format(_ raw: String) -> String {
        func has(_ phrases: String...) -> Bool { phrases.contains { raw.contains($0) } }
        if has("Connection refused", "Connection failed", "connection errored", "Cannot connect") {
            return "Cannot connect to server. Check the URL and your internet connection."
        }
        if has("CERT_", "certificate", "Client Certificate",
               "CERTIFICATE_VERIFY_FAILED", "SSL certificate") {
            return "SSL certificate error. Check the server's certificate."
        }
        if has("timed out") {
            return "Connection timed out. Check your server URL."
        }
        if has("401", "Unauthorized", "Invalid username or password") {
            return "Invalid username or password."
        }
        if has("404", "Not Found", "Server not found") {
            return "Server not found. Check your URL path."
        }
        return raw
            .replacingOccurrences(of: "Exception:", with: "")
            .replacingOccurrences(of: "Network error:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum Kind: Equatable {
        case ssl, credentials, notFound, timeout, connection, format, generic

        /// SF Symbols for Flutter's Cupertino icons.
        var systemImage: String {
            switch self {
            case .ssl: "lock.slash"                       // lock_slash
            case .credentials: "person.crop.circle.badge.minus" // person_badge_minus
            case .notFound: "questionmark.circle"         // question_circle
            case .timeout: "timer"                        // timer
            case .connection: "wifi.slash"                // wifi_slash
            case .format: "link"                          // link
            case .generic: "exclamationmark.triangle"     // exclamationmark_triangle
            }
        }

        /// Red (the brand red) for credentials and anything unknown, orange for the rest.
        var isRed: Bool { self == .credentials || self == .generic }

        /// Flutter's hints. The certificate one ("Try enabling Allow Self-Signed…") is dropped
        /// with that option (D11).
        var hint: String? {
            switch self {
            case .ssl: nil
            case .credentials: "Check your username and password and try again."
            case .notFound: "Verify the server URL path (e.g. /navidrome, /airsonic)."
            case .timeout: "The server took too long to respond. Check your network."
            case .connection: nil
            case .format: "URL must start with http:// or https://"
            case .generic: nil
            }
        }
    }

    /// Flutter `_categoriseError`: sorts a message by the phrases in it. Unlike Flutter, Navidrome's
    /// "Wrong username or password" counts as credentials, and only an address message gets the
    /// address hint (Flutter's "http" caught "Request failed (HTTP 418)." too).
    static func kind(of message: String) -> Kind {
        let lower = message.lowercased()
        func has(_ phrases: String...) -> Bool { phrases.contains { lower.contains($0) } }
        if has("ssl", "certificate", "handshake", "tls", "secure connection") { return .ssl }
        if has("invalid username", "wrong username", "wrong password", "unauthorized", "401") { return .credentials }
        if has("not found", "404", "url path") { return .notFound }
        if has("timed out", "timeout") { return .timeout }
        if has("cannot connect", "connection refused", "network", "socket") { return .connection }
        if has("url format", "start with http") { return .format }
        return .generic
    }

    /// Flutter `_isRemoteInsecureHttp`: an `http://` address that isn't on the local network
    /// gets the "Insecure HTTP" warning. (The ranges are the standard private ones.)
    static func isPlainHTTPOffNetwork(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.hasPrefix("http://"),
              let host = URLComponents(string: trimmed)?.host, !host.isEmpty else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
            || host.hasPrefix("192.168.") || host.hasPrefix("10.") {
            return false
        }
        if host.hasPrefix("172."), let second = Int(host.split(separator: ".").dropFirst().first ?? ""),
           (16...31).contains(second) {
            return false
        }
        return true
    }
}

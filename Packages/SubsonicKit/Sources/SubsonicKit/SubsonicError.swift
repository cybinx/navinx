import Foundation

/// Why a request failed. The messages are the Flutter app's (`SubsonicService._request`).
public enum SubsonicError: Error, Sendable, Hashable, LocalizedError {
    /// The request timed out.
    case timedOut
    /// The TLS handshake failed (bad, expired or untrusted certificate).
    case certificate
    /// No secure connection could be made, though not for a certificate: often an `https://` address
    /// on a plain-HTTP port.
    case secureConnection
    /// No route to the server: wrong address, server down, or no network.
    case cannotConnect
    /// HTTP 401.
    case unauthorized
    /// HTTP 403: a proxy or firewall in front of the server, usually, not a wrong password.
    case forbidden
    /// HTTP 404: usually a wrong path in the server address.
    case notFound
    /// HTTP 5xx.
    case server(status: Int)
    /// Any other HTTP failure status.
    case http(status: Int)
    /// Any other transport failure.
    case network
    /// The server address can't be a URL (no host, or a space in it): Flutter's `FormatException`.
    case invalidURL
    /// The body wasn't a Subsonic JSON response.
    case invalidResponse
    /// The server answered `status: "failed"`. Codes are Subsonic's (40 = wrong username or
    /// password, 70 = not found, …); the message is the server's own.
    case api(code: Int, message: String?)

    public var errorDescription: String? {
        switch self {
        case .timedOut: "Connection timed out. Check your server URL."
        // Flutter adds 'Enable "Allow Self-Signed Certificates"…'; that option isn't in this app (D11).
        case .certificate: "SSL certificate error. Check the server's certificate."
        case .secureConnection: "Could not make a secure connection. Check whether the server uses https."
        case .cannotConnect: "Cannot connect to server. Check the URL and your internet connection."
        case .unauthorized: "Invalid username or password."
        case .forbidden: "Access denied (HTTP 403). The server or its proxy refused the request."
        case .notFound: "Server not found. Check your URL path."
        case .server(let status): "Server error (\(status)). The server failed to process the request."
        case .http(let status): "Request failed (HTTP \(status))."
        case .network: "Network error. Check your connection."
        case .invalidURL: "Invalid server URL format."
        case .invalidResponse: "Invalid response format"
        case .api(_, let message): message ?? "Unknown error"
        }
    }

    /// Subsonic's "wrong username or password" (40) and "token auth not supported" (41) codes,
    /// or an HTTP 401. Not a 403, which a proxy or firewall gives whatever the password.
    public var isAuthenticationFailure: Bool {
        switch self {
        case .unauthorized: true
        case .api(let code, _): code == 40 || code == 41
        default: false
        }
    }

    static func from(status: Int) -> SubsonicError? {
        switch status {
        case 200..<300: nil
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        case 500...: .server(status: status)
        default: .http(status: status)
        }
    }

    static func from(_ error: any Error) -> SubsonicError {
        if let error = error as? SubsonicError { return error }
        guard let urlError = error as? URLError else { return .network }
        switch urlError.code {
        case .timedOut:
            return .timedOut
        case .secureConnectionFailed:
            return .secureConnection
        case .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired:
            return .certificate
        case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .networkConnectionLost,
             .dnsLookupFailed, .appTransportSecurityRequiresSecureConnection:
            return .cannotConnect
        default:
            return .network
        }
    }
}

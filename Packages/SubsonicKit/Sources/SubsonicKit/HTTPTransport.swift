import DeviceIdentity
import Foundation

/// The one thing the client needs from the network: a GET that returns the body and status.
/// Tests swap in a fixture transport; the app uses `URLSessionTransport`.
public protocol HTTPTransport: Sendable {
    func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse)
    /// The same request as a POST, with `url`'s query sent as a form-encoded body: for requests
    /// whose address would be too long for a proxy (a playlist of hundreds of songs). By default
    /// it's the GET, so a fake that reads the URL's query still sees every parameter.
    func post(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse)
    /// The same transport over a sign-in check's own sessions, which present only that login's identity
    /// (the review after C56). By default the transport itself (a fake has no sessions).
    func using(_ sessions: LoginSessions) -> any HTTPTransport
}

extension HTTPTransport {
    public func post(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        try await get(url, timeout: timeout)
    }

    public func using(_ sessions: LoginSessions) -> any HTTPTransport { self }
}

/// `HTTPTransport` over a `URLSession`. HTTPS with a publicly trusted certificate (Let's Encrypt
/// through a reverse proxy, for example) needs nothing extra.
public struct URLSessionTransport: HTTPTransport {
    /// Read for every request: the API's session is replaced when the device's certificate changes. Nil:
    /// a check's sessions that have ended; nothing is sent.
    private let sessions: @Sendable () -> URLSession?
    /// Over the shared `apiSessions` (`init()`): `using` gives a check its own.
    private let shared: Bool

    /// The API's session: ephemeral, so no answer is cached on disk with its signed address. A server that
    /// asks for the device's certificate gets it from `DeviceCertificates` (C45); any other gets none, as before.
    /// A new session whenever that certificate is stored or removed (the re-check, item 1): it's asked for only
    /// in the TLS handshake, so a kept-alive connection from before would go on without it.
    public static let apiSessions = RenewableSession {
        URLSession(configuration: .ephemeral, delegate: DeviceChallengeAnswer.shared, delegateQueue: nil)
    }

    /// The API's session (`apiSessions`).
    public init() {
        sessions = { URLSessionTransport.apiSessions.session }
        shared = true
    }

    /// A session of the caller's own, used as it is.
    public init(session: URLSession) {
        sessions = { session }
        shared = false
    }

    /// Over a sign-in check's own API session (`LoginSessions.api`).
    public init(checking sessions: LoginSessions) {
        self.sessions = { sessions.api.openSession }
        shared = false
    }

    /// The shared transport over a check's own sessions; a caller's own session is kept.
    public func using(_ sessions: LoginSessions) -> any HTTPTransport {
        shared ? URLSessionTransport(checking: sessions) : self
    }

    public func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        return try await send(request)
    }

    public func post(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        try await send(Self.formRequest(url, timeout: timeout))
    }

    /// A POST to `url` without its query, the query (already percent-encoded) as the body.
    static func formRequest(_ url: URL, timeout: TimeInterval) -> URLRequest {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.percentEncodedQuery ?? ""
        components?.percentEncodedQuery = nil
        var request = URLRequest(url: components?.url ?? url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(query.utf8)
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let session = sessions() else { throw URLError(.cannotConnectToHost) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SubsonicError.invalidResponse }
        return (data, http)
    }
}

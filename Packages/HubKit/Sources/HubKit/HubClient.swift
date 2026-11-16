import DeviceIdentity
import Foundation

/// What the probe found.
public enum HubProbe: Sendable, Equatable {
    /// A 200 with a v1 screen that has a tab: show the tab with this screen.
    case shown(HubScreen)
    /// Any other answer (a refusal, a redirect, something unreadable): no tab.
    case absent
    /// No answer at all (no network, a timeout) or a server error (5xx, 429): keep whatever is shown.
    case unreachable
}

/// Why a call failed.
public enum HubError: Error, Sendable, Equatable {
    /// No answer (no network, a timeout, a bad address).
    case unreachable
    /// An answer other than 200 (a refusal is the music server's own answer to an unknown path:
    /// a 302 to its web app for a GET, a 405 otherwise; D115).
    case refused(status: Int)
    /// A 200 that isn't a screen or reply this build can read.
    case invalid
}

/// The server's hub, as the app sees it. `HubClient` is the real one; tests use stand-ins.
public protocol HubAPI: Sendable {
    /// `GET /panel`, deciding whether the tab shows.
    func probe() async -> HubProbe
    /// `GET /panel/s/<id>`: a screen again, for its refresh.
    func screen(_ id: String) async throws(HubError) -> HubScreen
    /// `POST /panel`: an action.
    func send(_ request: HubRequest) async throws(HubError) -> HubReply
}

/// The hub's HTTP calls (schema v1, `docs/log/C27.md`). Every call is signed with the account's session
/// (`HubSessions`), or carries the account's signed login in `X-Subsonic-Login` where the server has no
/// sessions; redirects are never followed (a refusal, like a direct address, is the music server's own
/// redirect); nothing is cached or stored.
public struct HubClient: HubAPI {
    public static let probeTimeout: TimeInterval = 10
    public static let timeout: TimeInterval = 30
    /// The login's header.
    public static let loginHeader = "X-Subsonic-Login"

    /// The account's address in use, keeping any path prefix.
    public let baseURL: URL
    private let auth: HubAuth

    /// The old way only: `login` (`SubsonicClient.signedLoginQuery(for:)` for this address) on every call.
    public init(baseURL: URL, login: String, session: URLSession = HubClient.session) {
        self.baseURL = baseURL
        auth = .login(login, session)
    }

    /// Signed with the account's session, signing in when needed.
    public init(account: HubAccount, sessions: HubSessions = .shared) {
        baseURL = account.baseURL
        auth = .account(account, sessions)
    }

    /// The hub's root address for an account's address.
    public static func rootURL(base: URL) -> URL { base.appending(path: "panel") }

    public func probe() async -> HubProbe {
        do {
            let screen = try await get(Self.rootURL(base: baseURL), timeout: Self.probeTimeout)
            return screen.tab == nil ? .absent : .shown(screen)
        } catch .unreachable {
            return .unreachable
        } catch .refused(let status) where status == 429 || (500...599).contains(status) {
            // A proxy's 502/503/504 during a restart, or a rate limit: not the music server's refusal.
            return .unreachable
        } catch {
            return .absent
        }
    }

    public func screen(_ id: String) async throws(HubError) -> HubScreen {
        try await get(Self.rootURL(base: baseURL).appending(path: "s").appending(component: id), timeout: Self.timeout)
    }

    public func send(_ request: HubRequest) async throws(HubError) -> HubReply {
        var urlRequest = makeRequest(Self.rootURL(base: baseURL), timeout: Self.timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try? JSONEncoder().encode(request)
        return try decode(HubReply.self, from: try await load(urlRequest))
    }

    // MARK: - The calls

    private func get(_ url: URL, timeout: TimeInterval) async throws(HubError) -> HubScreen {
        try decode(HubScreen.self, from: try await load(makeRequest(url, timeout: timeout)))
    }

    private func makeRequest(_ url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func load(_ request: URLRequest) async throws(HubError) -> Data {
        let (data, response) = try await auth.load(request) { response, _ in Self.isRefusal(response.statusCode) }
        guard response.statusCode == 200 else { throw .refused(status: response.statusCode) }
        return data
    }

    /// Any answer but a 200, a server error and a rate limit: what a session the server no longer
    /// takes gets back (the music server's own answer, D115).
    static func isRefusal(_ status: Int) -> Bool {
        status != 200 && status != 429 && !(500...599).contains(status)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws(HubError) -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw .invalid
        }
    }

    // MARK: - The session

    /// An ephemeral session that never follows a redirect, replaced by a new one whenever the device's
    /// certificate is stored, renewed or removed, so no connection opened before goes on without it.
    public static var session: URLSession { sessions.session }
    static let sessions = RenewableSession { makeSession(.ephemeral) }

    /// A session over `configuration` (tests add their stub protocol) that never follows a redirect.
    public static func makeSession(_ configuration: URLSessionConfiguration) -> URLSession {
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
}

/// Stops every redirect: the task finishes with the 3xx answer itself. A server that asks for the
/// device's certificate gets it from `DeviceCertificates` (C45).
final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        DeviceCertificates.shared.answer(challenge)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// How a client's requests are let in: the old way, the login on each, or the account's session.
enum HubAuth: Sendable {
    case login(String, URLSession)
    case account(HubAccount, HubSessions)

    func load(
        _ request: URLRequest, maxBytes: Int = HubTransport.maxBytes, isRefusal: @Sendable (HTTPURLResponse, Data) -> Bool
    ) async throws(HubError) -> (Data, HTTPURLResponse) {
        switch self {
        case .login(let login, let session):
            try await HubTransport.load(HubSessions.withLogin(request, login), session: session, maxBytes: maxBytes)
        case .account(let account, let sessions):
            try await sessions.send(request, as: account, maxBytes: maxBytes, isRefusal: isRefusal)
        }
    }
}

/// One request, with every transport failure mapped to `.unreachable`. Bounded whatever the server does:
/// the request's own timeout is how long it may sit idle, `deadline(for:)` how long it may take in all,
/// and an answer longer than `maxBytes` isn't read (`.invalid`, as an answer that isn't a screen).
enum HubTransport {
    /// The longest answer read: far more than any screen or reply needs.
    static let maxBytes = 4 * 1024 * 1024

    /// A request's whole time, from its idle timeout: twice that.
    static func deadline(for timeout: TimeInterval) -> Duration {
        .seconds(timeout.isFinite ? min(max(timeout, 1), 3600) * 2 : 60)
    }

    static func load(
        _ request: URLRequest, session: URLSession, maxBytes: Int = maxBytes, deadline: Duration? = nil
    ) async throws(HubError) -> (Data, HTTPURLResponse) {
        let limit = deadline ?? Self.deadline(for: request.timeoutInterval)
        let outcome = await withTaskGroup(of: Result<(Data, HTTPURLResponse), HubError>?.self) { group in
            group.addTask { await fetch(request, session: session, maxBytes: maxBytes) }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return try (outcome ?? .failure(.unreachable)).get()
    }

    private static func fetch(
        _ request: URLRequest, session: URLSession, maxBytes: Int
    ) async -> Result<(Data, HTTPURLResponse), HubError> {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.unreachable) }
            guard http.expectedContentLength <= Int64(maxBytes) else {
                bytes.task.cancel()
                return .failure(.invalid)
            }
            var data = Data()
            if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
            for try await byte in bytes {
                guard data.count < maxBytes else {
                    bytes.task.cancel()
                    return .failure(.invalid)
                }
                data.append(byte)
            }
            return .success((data, http))
        } catch {
            return .failure(.unreachable)
        }
    }
}

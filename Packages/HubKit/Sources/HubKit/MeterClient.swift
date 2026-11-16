import Foundation

/// A song's equalizer levels from the server (C20, D96; `GET <account address>/eq/<songId>`): the
/// server works them out from the song itself, asking the music server as this account, whose
/// session signs the request, or whose signed login goes in `X-Subsonic-Login` where the server has no
/// sessions (D100, D101). Any login the music server accepts may ask.
public struct MeterClient: Sendable {
    /// A song not worked out yet: the server fetches it and analyses it (up to 180 s) before it
    /// sends a byte, so this waits out the server's own budget.
    public static let timeout: TimeInterval = 210
    /// The longest levels file read: 90 bytes a second of song, so some 50 hours.
    public static let maxBytes = 16 * 1024 * 1024

    public enum Answer: Sendable, Equatable {
        /// The levels file.
        case levels(Data)
        /// The server has none for this song (its own 404, `{"error": "not_found"}`).
        case none
        /// Nowhere to ask: the login refused (400, 401, 403), no such route here (a 404 that isn't
        /// the server's own, a redirect: a direct address, or any refusal, which is the music
        /// server's own answer to an unknown path, D115; a 405). No song will do better.
        case unavailable
        /// The server failed on this song alone (500, 502, 422).
        case failed
    }

    public let baseURL: URL
    private let auth: HubAuth

    /// The old way only: `login` on every call.
    public init(baseURL: URL, login: String, session: URLSession = HubClient.session) {
        self.baseURL = baseURL
        auth = .login(login, session)
    }

    /// Signed with the account's session, signing in when needed.
    public init(account: HubAccount, sessions: HubSessions = .shared) {
        baseURL = account.baseURL
        auth = .account(account, sessions)
    }

    /// Where a song's levels are, for an account's address.
    public static func url(base: URL, songID: String) -> URL {
        base.appending(path: "eq").appending(component: songID)
    }

    /// Throws `HubError.unreachable` when there's no answer at all. An answer longer than `maxBytes` is
    /// this song's failure.
    public func levels(songID: String) async throws(HubError) -> Answer {
        var request = URLRequest(
            url: Self.url(base: baseURL, songID: songID), cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.timeout
        )
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await auth.load(request, maxBytes: Self.maxBytes) { response, data in
                Self.answer(status: response.statusCode, body: data) == .unavailable
            }
        } catch .invalid {
            return .failed
        }
        return Self.answer(status: response.statusCode, body: data)
    }

    static func answer(status: Int, body: Data) -> Answer {
        switch status {
        case 200..<300:
            return .levels(body)
        case 404:
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            return json?["error"] is String ? .none : .unavailable
        case 300..<400, 400, 401, 403, 405:
            return .unavailable
        default:
            return .failed
        }
    }
}

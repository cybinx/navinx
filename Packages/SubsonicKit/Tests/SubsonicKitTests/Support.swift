import Foundation
import Synchronization
@testable import SubsonicKit

/// Loads a fixture: `"getAlbum"` or `"Handwritten/getStarred2"`.
func fixture(_ name: String) throws -> Data {
    let parts = name.split(separator: "/").map(String.init)
    let subdirectory = (["Fixtures"] + parts.dropLast()).joined(separator: "/")
    guard let url = Bundle.module.url(forResource: parts.last, withExtension: "json", subdirectory: subdirectory) else {
        throw FixtureMissing(name: name)
    }
    return try Data(contentsOf: url)
}

struct FixtureMissing: Error {
    let name: String
}

/// What the fake server does for a request.
enum Reply: Sendable {
    case fixture(String)
    case body(String, status: Int = 200)
    case status(Int)
    case failure(URLError.Code)
}

/// An `HTTPTransport` that answers by endpoint (`getAlbum`, …) and records every URL.
final class FakeTransport: HTTPTransport {
    private let replies: [String: Reply]
    private let byHost: [String: Reply]
    private let log = Mutex<[URL]>([])
    private let postLog = Mutex<[URL]>([])

    /// `byHost` answers every request to that host, before `replies`.
    init(_ replies: [String: Reply] = [:], byHost: [String: Reply] = [:]) {
        self.replies = replies
        self.byHost = byHost
    }

    /// Every request, POSTs too (with their parameters in the URL's query).
    var requests: [URL] { log.withLock { $0 } }
    /// The requests sent as a POST.
    var posted: [URL] { postLog.withLock { $0 } }

    func post(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        postLog.withLock { $0.append(url) }
        return try await get(url, timeout: timeout)
    }

    func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        log.withLock { $0.append(url) }
        let endpoint = url.lastPathComponent
        guard let reply = url.host().flatMap({ byHost[$0] }) ?? replies[endpoint] else {
            throw URLError(.cannotFindHost)
        }
        func response(_ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        }
        switch reply {
        case .fixture(let name): return (try fixture(name), response(200))
        case .body(let body, let status): return (Data(body.utf8), response(status))
        case .status(let status): return (Data(), response(status))
        case .failure(let code): throw URLError(code)
        }
    }
}

extension URL {
    /// The query as a dictionary (last value wins), for assertions.
    var params: [String: String] {
        let items = URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }
}

let testConfig = ServerConfig(serverURL: "music.example.com", username: "demo", password: "demo")

func makeClient(
    _ replies: [String: Reply] = [:],
    config: ServerConfig = testConfig
) throws -> (SubsonicClient, FakeTransport) {
    let transport = FakeTransport(replies)
    let client = try SubsonicClient(config: config, coverArtSalt: "stablesalt123456", transport: transport)
    return (client, transport)
}

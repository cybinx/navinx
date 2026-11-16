import Foundation
import Testing
@testable import HubKit

/// A stub server: each test registers its own made-up host, since suites run in parallel (gotchas).
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Answer: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
        var fails = false
        /// Sends the status and the body, then never finishes.
        var hangs = false
    }

    struct Seen: Sendable {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data?
    }

    nonisolated(unsafe) private static var answers: [String: @Sendable (Seen) -> Answer] = [:]
    nonisolated(unsafe) private static var seen: [String: [Seen]] = [:]
    private static let lock = NSLock()

    static func register(_ host: String, _ answer: @escaping @Sendable (Seen) -> Answer) {
        lock.withLock {
            answers[host] = answer
            seen[host] = []
        }
    }

    static func requests(_ host: String) -> [Seen] { lock.withLock { seen[host] ?? [] } }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return HubClient.makeSession(configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return }
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        let request = Seen(
            method: request.httpMethod ?? "GET", url: url, headers: request.allHTTPHeaderFields ?? [:], body: body
        )
        let handler = Self.lock.withLock {
            Self.seen[host, default: []].append(request)
            return Self.answers[host]
        }
        guard let answer = handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        if answer.fails {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        if answer.hangs { return }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct HubClientTests {
    private func client(_ host: String, base: String? = nil) -> HubClient {
        HubClient(baseURL: URL(string: base ?? "http://\(host):4600")!, login: "u=api&t=tok&s=salt", session: StubProtocol.session)
    }

    private func screen(_ name: String) throws -> Data { try HubScreenTests.fixture(name) }

    @Test func aV1ScreenWithATabShowsTheTab() async throws {
        let body = try screen("main-paste-idle")
        StubProtocol.register("probe-ok") { _ in .init(status: 200, body: body) }
        guard case .shown(let screen) = await client("probe-ok").probe() else {
            Issue.record("not shown")
            return
        }
        #expect(screen.tab?.title == "Add")
        let seen = try #require(StubProtocol.requests("probe-ok").first)
        #expect(seen.method == "GET")
        #expect(seen.url.absoluteString == "http://probe-ok:4600/panel")
        #expect(seen.headers["X-Subsonic-Login"] == "u=api&t=tok&s=salt")
    }

    @Test func thePathPrefixIsKept() async throws {
        let body = try screen("main-paste-idle")
        StubProtocol.register("probe-prefix") { _ in .init(status: 200, body: body) }
        _ = await client("probe-prefix", base: "https://probe-prefix/music").probe()
        #expect(StubProtocol.requests("probe-prefix").first?.url.absoluteString == "https://probe-prefix/music/panel")
    }

    @Test(arguments: [
        (403, "Forbidden", "text/plain"), (404, "{\"detail\": \"Not Found\"}", "application/json"),
        (302, "<a href=\"/app/\">Found</a>.\n\n", "text/html; charset=utf-8"), (405, "", ""),
        (200, "<html>Navidrome</html>", "text/html"), (200, "{\"v\": 1", "application/json"),
        (200, "{\"v\": 1, \"id\": \"search\", \"title\": \"\", \"sections\": []}", "application/json"),
        (200, "{\"v\": 2, \"id\": \"main\", \"title\": \"\", \"tab\": {\"title\": \"X\", \"symbol\": \"circle\"}, \"sections\": []}", "application/json"),
    ])
    func everyOtherAnswerHidesTheTab(_ answer: (Int, String, String)) async {
        let host = "probe-hidden-\(answer.0)-\(abs(answer.1.hashValue))"
        StubProtocol.register(host) { _ in
            .init(status: answer.0, body: Data(answer.1.utf8), headers: ["Content-Type": answer.2, "Location": "/app/"])
        }
        #expect(await client(host).probe() == .absent)
    }

    @Test(arguments: [500, 502, 503, 504, 429])
    func aServerErrorKeepsWhatIsShown(_ status: Int) async {
        let host = "probe-error-\(status)"
        StubProtocol.register(host) { _ in .init(status: status, body: Data("Bad Gateway".utf8), headers: ["Content-Type": "text/html"]) }
        #expect(await client(host).probe() == .unreachable, "a proxy restarting isn't a refusal")
    }

    @Test func noAnswerKeepsWhatIsShown() async {
        StubProtocol.register("probe-offline") { _ in .init(status: 0, body: Data(), fails: true) }
        #expect(await client("probe-offline").probe() == .unreachable)
    }

    @Test func redirectsAreNeverFollowed() async throws {
        let delegate = NoRedirects()
        let task = URLSession.shared.dataTask(with: URL(string: "http://example.invalid/")!)
        let next = await delegate.urlSession(
            URLSession.shared, task: task,
            willPerformHTTPRedirection: HTTPURLResponse(url: URL(string: "http://h/panel")!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "/app/"])!,
            newRequest: URLRequest(url: URL(string: "http://h/app/")!)
        )
        #expect(next == nil)
    }

    @Test func aScreenIsFetchedByItsID() async throws {
        let body = try screen("search-results")
        StubProtocol.register("screen-get") { _ in .init(status: 200, body: body) }
        let screen = try await client("screen-get").screen("request-23")
        #expect(screen.id == "search")
        #expect(StubProtocol.requests("screen-get").first?.url.absoluteString == "http://screen-get:4600/panel/s/request-23")
    }

    @Test func anActionPostsItsBody() async throws {
        let body = try screen("reply-checking")
        StubProtocol.register("action-post") { _ in .init(status: 200, body: body) }
        let reply = try await client("action-post").send(
            HubRequest(screen: "main", action: "check", values: ["link": "https://example.com/x"])
        )
        #expect(reply.present == .replace && reply.screen?.refresh == 1)
        let seen = try #require(StubProtocol.requests("action-post").first)
        #expect(seen.method == "POST" && seen.url.absoluteString == "http://action-post:4600/panel")
        #expect(seen.headers["Content-Type"] == "application/json")
        #expect(seen.headers["X-Subsonic-Login"] == "u=api&t=tok&s=salt")
        let json = try #require(try JSONSerialization.jsonObject(with: seen.body ?? Data()) as? [String: Any])
        #expect(json["screen"] as? String == "main" && json["action"] as? String == "check")
        #expect(json["values"] as? [String: String] == ["link": "https://example.com/x"])
    }

    @Test func failedCallsSayWhy() async throws {
        // A refused POST gets what Navidrome answers for a POST to a path it doesn't know (D115).
        StubProtocol.register("action-refused") { _ in .init(status: 405, body: Data(), headers: ["Allow": "GET"]) }
        await #expect(throws: HubError.refused(status: 405)) {
            try await client("action-refused").send(HubRequest(screen: "main", action: "x"))
        }
        StubProtocol.register("action-bad") { _ in .init(status: 200, body: Data("nope".utf8)) }
        await #expect(throws: HubError.invalid) {
            try await client("action-bad").send(HubRequest(screen: "main", action: "x"))
        }
        StubProtocol.register("action-down") { _ in .init(status: 0, body: Data(), fails: true) }
        await #expect(throws: HubError.unreachable) {
            try await client("action-down").screen("main")
        }
    }

    // MARK: The bounds (T11)

    @Test func anAnswerLongerThanTheCapIsntRead() async throws {
        // A screen padded to the cap exactly is read; one byte more is refused like something unreadable.
        let base = try screen("main-paste-idle")
        let padded = base + Data(repeating: 0x20, count: HubTransport.maxBytes - base.count)
        StubProtocol.register("size-at-cap") { _ in .init(status: 200, body: padded) }
        guard case .shown = await client("size-at-cap").probe() else {
            Issue.record("an answer at the cap is read")
            return
        }
        let over = padded + Data(" ".utf8)
        StubProtocol.register("size-over-cap") { _ in .init(status: 200, body: over) }
        #expect(await client("size-over-cap").probe() == .absent)
        await #expect(throws: HubError.invalid) {
            try await client("size-over-cap").send(HubRequest(screen: "main", action: "x"))
        }
        // Said up front: not read at all.
        StubProtocol.register("size-said") { _ in
            .init(status: 200, body: Data("{}".utf8), headers: ["Content-Length": String(HubTransport.maxBytes + 1)])
        }
        let request = URLRequest(url: URL(string: "http://size-said:4600/panel")!)
        await #expect(throws: HubError.invalid) {
            try await HubTransport.load(request, session: StubProtocol.session, maxBytes: 100)
        }
    }

    @Test func anAnswerThatNeverEndsMeetsTheDeadline() async throws {
        // Bytes arrive, so the idle timeout never fires: the deadline ends it.
        StubProtocol.register("never-ends") { _ in .init(status: 200, body: Data("{".utf8), hangs: true) }
        let request = URLRequest(url: URL(string: "http://never-ends:4600/panel")!, timeoutInterval: 30)
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: HubError.unreachable) {
            try await HubTransport.load(request, session: StubProtocol.session, deadline: .milliseconds(300))
        }
        #expect(clock.now - start < .seconds(5))
        #expect(HubTransport.deadline(for: HubClient.probeTimeout) == .seconds(20))
        #expect(HubTransport.deadline(for: HubClient.timeout) == .seconds(60))
        #expect(HubTransport.deadline(for: .infinity) == .seconds(60))
    }
}

/// The levels' route (C20, moved by C27): the same answers as before, at `/eq/<songId>`.
struct MeterClientTests {
    private func meter(_ host: String) -> MeterClient {
        MeterClient(baseURL: URL(string: "http://\(host):4600")!, login: "u=api&t=tok&s=salt", session: StubProtocol.session)
    }

    @Test func levelsComeWithTheLoginAndNoToken() async throws {
        StubProtocol.register("eq-ok") { _ in .init(status: 200, body: Data("NXLV".utf8)) }
        #expect(try await meter("eq-ok").levels(songID: "a b/c") == .levels(Data("NXLV".utf8)))
        let seen = try #require(StubProtocol.requests("eq-ok").first)
        #expect(seen.url.absoluteString == "http://eq-ok:4600/eq/a%20b%2Fc")
        #expect(seen.headers["X-Subsonic-Login"] == "u=api&t=tok&s=salt")
        #expect(seen.headers["Authorization"] == nil)
    }

    @Test(arguments: [
        (404, #"{"error": "not_found"}"#, MeterClient.Answer.none),
        (404, #"{"detail": "Not Found"}"#, .unavailable),
        (404, "<html>nginx</html>", .unavailable),
        (302, "", .unavailable),
        (302, "<a href=\"/app/\">Found</a>.\n\n", .unavailable),
        (405, "", .unavailable),
        (400, #"{"error": "no_login"}"#, .unavailable),
        (401, "", .unavailable),
        (403, "Forbidden", .unavailable),
        (422, #"{"error": "invalid_id"}"#, .failed),
        (500, #"{"error": "analysis"}"#, .failed),
        (502, #"{"error": "navidrome"}"#, .failed),
    ])
    func answersMapAsBefore(_ answer: (Int, String, MeterClient.Answer)) async throws {
        let host = "eq-\(answer.0)-\(abs(answer.1.hashValue))"
        StubProtocol.register(host) { _ in .init(status: answer.0, body: Data(answer.1.utf8)) }
        #expect(try await meter(host).levels(songID: "s1") == answer.2)
    }

    @Test func noAnswerThrows() async {
        StubProtocol.register("eq-down") { _ in .init(status: 0, body: Data(), fails: true) }
        await #expect(throws: HubError.unreachable) { try await meter("eq-down").levels(songID: "s1") }
    }
}

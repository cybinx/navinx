import Foundation
import Synchronization
import Testing
@testable import HubKit

/// The session's sign-in and signing (protocol v1), against a stub server per made-up host.
struct HubSessionTests {
    static let secret = Data(0..<32)
    static let challenge = Data(32..<64)
    static let vectorHash = "19e940a1b111adcb958ec95f703e2b56acafd13ddc92f72994d346c07088b9b8"
    static let vectorTime: TimeInterval = 1_794_268_800

    // MARK: The stand-ins

    final class Clock: Sendable {
        private let value: Mutex<Date>
        init(_ seconds: TimeInterval) { value = Mutex(Date(timeIntervalSince1970: seconds)) }
        func now() -> Date { value.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
    }

    actor Keys: HubKeyProvider {
        private(set) var keyID: String?
        let fails: Bool
        private(set) var hashes: [Data] = []
        private(set) var attested = 0
        private(set) var forgot = 0

        init(keyID: String? = nil, fails: Bool = false) {
            self.keyID = keyID
            self.fails = fails
        }

        func currentKeyID() -> String? { keyID }
        func attestNewKey(clientDataHash: Data) throws -> HubAttestedKey {
            hashes.append(clientDataHash)
            if fails { throw NoHubKey.Unavailable() }
            attested += 1
            keyID = "new-key"
            return HubAttestedKey(keyID: "new-key", attestation: Data("ATT".utf8))
        }
        func assertion(clientDataHash: Data) throws -> Data {
            hashes.append(clientDataHash)
            if fails { throw NoHubKey.Unavailable() }
            return Data("ASR".utf8)
        }
        func set(keyID: String) { self.keyID = keyID }
        func forgetKey() {
            forgot += 1
            keyID = nil
        }
    }

    /// A key slow to say which it holds (the first thing a sign-in asks, before its hello), so a sign-in
    /// stays on its way without holding up the stub server; it counts the sign-ins asking at once.
    actor SlowKeys: HubKeyProvider {
        let delay: Duration
        private var asking = 0
        private(set) var mostAtOnce = 0
        private(set) var attested = 0

        init(delay: Duration) { self.delay = delay }

        func currentKeyID() async -> String? {
            asking += 1
            mostAtOnce = max(mostAtOnce, asking)
            try? await Task.sleep(for: delay)
            asking -= 1
            return nil
        }
        func attestNewKey(clientDataHash: Data) throws -> HubAttestedKey {
            attested += 1
            return HubAttestedKey(keyID: "new-key-\(attested)", attestation: Data("ATT".utf8))
        }
        func assertion(clientDataHash: Data) throws -> Data { Data("ASR".utf8) }
        func forgetKey() {}
    }

    final class Counts: Sendable {
        let value = Mutex<(sessions: Int, routes: Int)>((0, 0))
    }

    /// How the stub server answers.
    struct Plan: Sendable {
        var hello = 200
        var expects = "none"
        var serverNow = HubSessionTests.vectorTime
        /// Hello's `now` as written, in place of `serverNow`.
        var rawNow: String?
        /// Hello's status by the request, in place of `hello`.
        var helloFor: (@Sendable (StubProtocol.Seen) -> Int)?
        /// How many of the first session steps are refused.
        var sessionRefusals = 0
        var expires: TimeInterval = 604_800
        /// The session step's `expires` as written, in place of `expires`.
        var rawExpires: String?
        var helloDelay: TimeInterval = 0
        /// The status for the n-th (from 0) request to a route.
        var route: @Sendable (Int, StubProtocol.Seen) -> Int = { _, _ in 200 }
    }

    private static func serve(_ host: String, _ plan: Plan) throws {
        let screen = try HubScreenTests.fixture("main-paste-idle")
        let reply = try HubScreenTests.fixture("reply-checking")
        let counts = Counts()
        StubProtocol.register(host) { seen in
            let path = seen.url.path()
            if path.hasSuffix("/eq/hello") {
                if plan.helloDelay > 0 { Thread.sleep(forTimeInterval: plan.helloDelay) }
                // "known": an assertion for any key the app sends, else an attestation.
                var expects = plan.expects
                if expects == "known" { expects = HubSessionTests.json(seen)["key"] is String ? "assertion" : "attestation" }
                let now = plan.rawNow ?? String(Int(plan.serverNow))
                let body = #"{"v":1,"challenge":"\#(HubSessionTests.challenge.base64EncodedString())","expects":"\#(expects)","now":\#(now)}"#
                let status = plan.helloFor?(seen) ?? plan.hello
                return .init(status: status, body: status == 200 ? Data(body.utf8) : Data())
            }
            if path.hasSuffix("/eq/session") {
                let n = counts.value.withLock { $0.sessions += 1; return $0.sessions }
                let expires = plan.rawExpires ?? String(Int(plan.expires))
                let body = #"{"v":1,"session":"s\#(n)","secret":"\#(HubSessionTests.secret.base64EncodedString())","expires":\#(expires),"attested":false}"#
                return n <= plan.sessionRefusals ? .init(status: 405, body: Data()) : .init(status: 200, body: Data(body.utf8))
            }
            let n = counts.value.withLock { $0.routes += 1; return $0.routes - 1 }
            let status = plan.route(n, seen)
            let body = path.contains("/eq/") ? Data("NXLV".utf8) : seen.method == "POST" ? reply : screen
            return .init(status: status, body: status == 200 ? body : Data(), headers: ["Location": "/app/"])
        }
    }

    private static func sessions(_ clock: Clock) -> HubSessions {
        HubSessions(session: StubProtocol.session, now: clock.now, random: { count in Data((0..<count).map { UInt8($0) }) })
    }

    private static func account(
        _ host: String, base: String? = nil, username: String = "api", digest: String? = nil,
        keys: any HubKeyProvider = NoHubKey()
    ) -> HubAccount {
        HubAccount(
            baseURL: URL(string: base ?? "http://\(host):4600")!, username: username,
            login: "u=\(username)&t=tok&s=salt", loginDigest: digest.map { Data($0.utf8) },
            keys: keys
        )
    }

    private static func requests(_ host: String, _ suffix: String) -> [StubProtocol.Seen] {
        StubProtocol.requests(host).filter { $0.url.path().hasSuffix(suffix) }
    }

    private static func routes(_ host: String) -> [StubProtocol.Seen] {
        StubProtocol.requests(host).filter { !$0.url.path().hasSuffix("/eq/hello") && !$0.url.path().hasSuffix("/eq/session") }
    }

    static func json(_ seen: StubProtocol.Seen?) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: seen?.body ?? Data())) as? [String: Any] ?? [:]
    }

    static let sessionHeaders = ["X-Session", "X-Session-Time", "X-Session-Nonce", "X-Session-Signature"]

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    // MARK: The test vectors

    @Test func theTestVectorsHold() {
        #expect(Self.secret.base64EncodedString() == "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")
        #expect(HubSessions.base64URL(Data(0..<12)) == "AAECAwQFBgcICQoL")
        #expect(HubSessions.signature(
            secret: Self.secret, method: "GET", path: "/panel/s/a%20b", time: "1794268800", nonce: "AAECAwQFBgcICQoL",
            body: Data()
        ) == "qnzwakaYAK3l0xWamhSEnFfzGJ7wRnhGWwp6haeatMo=")
        #expect(HubSessions.signature(
            secret: Self.secret, method: "POST", path: "/panel", time: "1794268800", nonce: "AAECAwQFBgcICQoL",
            body: Data(#"{"action":"a","control":"c","values":{}}"#.utf8)
        ) == "VK3Hzj6xweJMpAHT3qQ2SoESNI90/EIp5WAmIJjw+jk=")
        #expect(Self.challenge.base64EncodedString() == "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=")
        #expect(Self.hex(HubSessions.clientDataHash(challenge: Self.challenge, username: "api")) == Self.vectorHash)
        #expect(Self.hex(HubSessions.clientDataHash(challenge: Self.challenge, username: "API")) == Self.vectorHash)
    }

    @Test func thePathStartsAtTheRoute() {
        let plain = URL(string: "http://h:4600")!
        #expect(HubSessions.routePath(of: HubClient.rootURL(base: plain), base: plain) == "/panel")
        #expect(HubSessions.routePath(of: MeterClient.url(base: plain, songID: "a b/c"), base: plain) == "/eq/a%20b%2Fc")
        let prefixed = URL(string: "https://h/music/")!
        let screen = HubClient.rootURL(base: prefixed).appending(path: "s").appending(component: "a b")
        #expect(HubSessions.routePath(of: screen, base: prefixed) == "/panel/s/a%20b")
        #expect(HubSessions.routePath(of: URL(string: "https://h/other/panel")!, base: URL(string: "https://h/music")!) == nil)
    }

    // MARK: Signing in and signing

    @Test func helloThenSessionThenSignedRequests() async throws {
        let host = "session-flow"
        try Self.serve(host, Plan())
        let clock = Clock(Self.vectorTime - 900)
        let client = HubClient(account: Self.account(host), sessions: Self.sessions(clock))
        _ = try await client.screen("a b")

        let hello = try #require(Self.requests(host, "/eq/hello").first)
        #expect(hello.method == "POST" && hello.url.absoluteString == "http://\(host):4600/eq/hello")
        #expect(hello.headers["X-Subsonic-Login"] == "u=api&t=tok&s=salt")
        #expect(hello.headers["Content-Type"] == "application/json")
        let helloBody = Self.json(hello)
        #expect(helloBody["v"] as? Int == 1 && helloBody["key"] is NSNull)
        #expect(String(decoding: hello.body ?? Data(), as: UTF8.self) == #"{"key":null,"v":1}"#, "v is the integer 1")

        let session = try #require(Self.requests(host, "/eq/session").first)
        #expect(session.method == "POST" && session.headers["X-Subsonic-Login"] == "u=api&t=tok&s=salt")
        let sessionBody = Self.json(session)
        #expect(sessionBody["v"] as? Int == 1)
        #expect(sessionBody["challenge"] as? String == Self.challenge.base64EncodedString())
        #expect(sessionBody["key"] is NSNull && sessionBody["attestation"] is NSNull && sessionBody["assertion"] is NSNull)
        #expect(String(decoding: session.body ?? Data(), as: UTF8.self).contains(#""v":1}"#))

        let signed = try #require(Self.routes(host).first)
        #expect(signed.method == "GET" && signed.url.absoluteString == "http://\(host):4600/panel/s/a%20b")
        #expect(signed.headers["X-Subsonic-Login"] == nil, "no login rides on a signed request")
        #expect(signed.headers["X-Session"] == "s1")
        #expect(signed.headers["X-Session-Time"] == "1794268800", "the phone's clock, corrected by hello's")
        #expect(signed.headers["X-Session-Nonce"] == "AAECAwQFBgcICQoL")
        #expect(signed.headers["X-Session-Signature"] == "qnzwakaYAK3l0xWamhSEnFfzGJ7wRnhGWwp6haeatMo=")

        // The next call is signed with the same session, with no new sign-in.
        _ = try await client.send(HubRequest(screen: "main", action: "a"))
        #expect(Self.requests(host, "/eq/hello").count == 1 && Self.requests(host, "/eq/session").count == 1)
        let post = try #require(Self.routes(host).last)
        #expect(post.method == "POST" && post.headers["X-Session"] == "s1" && post.headers["X-Subsonic-Login"] == nil)
        #expect(post.headers["X-Session-Signature"] == HubSessions.signature(
            secret: Self.secret, method: "POST", path: "/panel", time: "1794268800", nonce: "AAECAwQFBgcICQoL",
            body: post.body ?? Data()
        ))
    }

    @Test func theAddressPrefixIsNotSigned() async throws {
        let host = "session-prefix"
        try Self.serve(host, Plan())
        let clock = Clock(Self.vectorTime)
        let meter = MeterClient(account: Self.account(host, base: "https://\(host)/music"), sessions: Self.sessions(clock))
        #expect(try await meter.levels(songID: "a b") == .levels(Data("NXLV".utf8)))
        #expect(Self.requests(host, "/eq/hello").first?.url.absoluteString == "https://\(host)/music/eq/hello")
        let signed = try #require(Self.routes(host).first)
        #expect(signed.url.absoluteString == "https://\(host)/music/eq/a%20b")
        #expect(signed.headers["Accept"] == "application/octet-stream")
        #expect(signed.headers["X-Session-Signature"] == HubSessions.signature(
            secret: Self.secret, method: "GET", path: "/eq/a%20b", time: "1794268800", nonce: "AAECAwQFBgcICQoL", body: Data()
        ))
    }

    @Test func theClockIsCorrectedFromNow() async throws {
        let host = "session-clock"
        var plan = Plan()
        plan.serverNow = 5000
        try Self.serve(host, plan)
        let clock = Clock(1000)
        let sessions = Self.sessions(clock)
        let client = HubClient(account: Self.account(host), sessions: sessions)
        _ = await client.probe()
        clock.advance(10)
        _ = await client.probe()
        #expect(Self.routes(host).map { $0.headers["X-Session-Time"] } == ["5000", "5010"])
    }

    // MARK: Refusals

    @Test func anUnlistedAccountIsRefusedOnceAndKeepsItsSession() async throws {
        let host = "session-unlisted"
        var plan = Plan()
        plan.route = { _, seen in seen.url.path().hasPrefix("/panel") ? 302 : 200 }
        try Self.serve(host, plan)
        let sessions = Self.sessions(Clock(Self.vectorTime))
        let client = HubClient(account: Self.account(host), sessions: sessions)
        #expect(await client.probe() == .absent)
        #expect(Self.requests(host, "/eq/hello").count == 1 && Self.requests(host, "/eq/session").count == 1)
        #expect(Self.routes(host).count == 1, "a refusal on a session just made is the answer")
        // The levels go on with the same session.
        let meter = MeterClient(account: Self.account(host), sessions: sessions)
        #expect(try await meter.levels(songID: "s1") == .levels(Data("NXLV".utf8)))
        #expect(Self.requests(host, "/eq/hello").count == 1)
        #expect(Self.routes(host).map { $0.headers["X-Session"] } == ["s1", "s1"])
    }

    @Test func anOlderSessionRefusedIsRenewedOnceAndRetried() async throws {
        let host = "session-renew"
        var plan = Plan()
        plan.route = { n, _ in n == 1 ? 302 : 200 }
        try Self.serve(host, plan)
        let clock = Clock(Self.vectorTime)
        let client = HubClient(account: Self.account(host), sessions: Self.sessions(clock))
        _ = await client.probe()
        clock.advance(120)   // the server restarted meanwhile
        guard case .shown = await client.probe() else {
            Issue.record("the second try's answer is the answer")
            return
        }
        #expect(Self.requests(host, "/eq/hello").count == 2 && Self.requests(host, "/eq/session").count == 2)
        _ = await client.probe()
        #expect(Self.requests(host, "/eq/hello").count == 2, "the renewed session is kept")
        #expect(Self.routes(host).map { $0.headers["X-Session"] } == ["s1", "s1", "s2", "s2"])
    }

    @Test func aRetryRefusedTooKeepsTheRenewedSession() async throws {
        let host = "session-refusing"
        var plan = Plan()
        plan.route = { n, _ in n == 0 ? 200 : 405 }
        try Self.serve(host, plan)
        let clock = Clock(Self.vectorTime)
        let client = HubClient(account: Self.account(host), sessions: Self.sessions(clock))
        _ = await client.probe()
        clock.advance(120)
        await #expect(throws: HubError.refused(status: 405)) { try await client.send(HubRequest(screen: "main", action: "a")) }
        #expect(Self.requests(host, "/eq/hello").count == 2 && Self.requests(host, "/eq/session").count == 2)
        #expect(Self.routes(host).count == 3)
        await #expect(throws: HubError.refused(status: 405)) { try await client.send(HubRequest(screen: "main", action: "a")) }
        #expect(Self.requests(host, "/eq/hello").count == 2, "the new session is just made: its refusal stands")
        #expect(Self.routes(host).map { $0.headers["X-Session"] } == ["s1", "s1", "s2", "s2"])
    }

    @Test func theLevelsOwnAnswersAreNotRefusals() async throws {
        let host = "session-levels-none"
        var plan = Plan()
        plan.route = { _, _ in 500 }
        try Self.serve(host, plan)
        let meter = MeterClient(account: Self.account(host), sessions: Self.sessions(Clock(Self.vectorTime)))
        #expect(try await meter.levels(songID: "s1") == .failed)
        #expect(Self.routes(host).count == 1, "a song that failed isn't a session refused")
    }

    @Test func aRefusedHelloSendsTheOldWayForTenMinutes() async throws {
        let host = "session-old-server"
        var plan = Plan()
        plan.hello = 405
        plan.route = { _, seen in seen.headers["X-Subsonic-Login"] == nil ? 302 : 200 }
        try Self.serve(host, plan)
        let clock = Clock(Self.vectorTime)
        let sessions = Self.sessions(clock)
        let client = HubClient(account: Self.account(host), sessions: sessions)
        guard case .shown = await client.probe() else {
            Issue.record("an older server answers the old way")
            return
        }
        let first = try #require(Self.routes(host).first)
        #expect(first.headers["X-Subsonic-Login"] == "u=api&t=tok&s=salt")
        #expect(Self.sessionHeaders.allSatisfy { first.headers[$0] == nil }, "no session header on the old way")
        #expect(Self.requests(host, "/eq/session").isEmpty)

        // The levels at the same address, a few minutes later: no hello either.
        clock.advance(500)
        let meter = MeterClient(account: Self.account(host), sessions: sessions)
        #expect(try await meter.levels(songID: "s1") == .levels(Data("NXLV".utf8)))
        #expect(Self.requests(host, "/eq/hello").count == 1)

        clock.advance(101)
        _ = await client.probe()
        #expect(Self.requests(host, "/eq/hello").count == 2, "asked again after ten minutes")
    }

    @Test func aBusyServerSendsTheOldWayThisOnce() async throws {
        let host = "session-busy"
        var plan = Plan()
        plan.hello = 503
        try Self.serve(host, plan)
        let client = HubClient(account: Self.account(host), sessions: Self.sessions(Clock(Self.vectorTime)))
        _ = await client.probe()
        _ = await client.probe()
        #expect(Self.requests(host, "/eq/hello").count == 2, "a server error isn't remembered")
        #expect(Self.routes(host).allSatisfy { $0.headers["X-Subsonic-Login"] != nil })
    }

    @Test func noAnswerToHelloSendsNothingMore() async throws {
        StubProtocol.register("session-down") { _ in .init(status: 0, body: Data(), fails: true) }
        let client = HubClient(account: Self.account("session-down"), sessions: Self.sessions(Clock(Self.vectorTime)))
        #expect(await client.probe() == .unreachable)
        #expect(StubProtocol.requests("session-down").count == 1)
    }

    // MARK: One sign-in at a time

    @Test func concurrentCallersShareOneSignIn() async throws {
        let host = "session-shared"
        var plan = Plan()
        plan.helloDelay = 0.3
        try Self.serve(host, plan)
        let sessions = Self.sessions(Clock(Self.vectorTime))
        let client = HubClient(account: Self.account(host), sessions: sessions)
        let meter = MeterClient(account: Self.account(host), sessions: sessions)
        async let probe = client.probe()
        async let levels = meter.levels(songID: "s1")
        async let more = meter.levels(songID: "s2")
        _ = await probe
        _ = try await (levels, more)
        #expect(Self.requests(host, "/eq/hello").count == 1 && Self.requests(host, "/eq/session").count == 1)
        #expect(Self.routes(host).map { $0.headers["X-Session"] } == ["s1", "s1", "s1"])
    }

    /// The tab and the levels name the same login's digest: one sign-in. A call naming none joins the
    /// one on its way for its address and username.
    @Test(arguments: ["a", nil] as [String?])
    func theLevelsJoinTheTabsSignIn(_ levelsDigest: String?) async throws {
        let host = "session-joined-\(levelsDigest ?? "none")"
        try Self.serve(host, Plan())
        let sessions = Self.sessions(Clock(Self.vectorTime))
        let keys = SlowKeys(delay: .milliseconds(300))
        let client = HubClient(account: Self.account(host, digest: "a", keys: keys), sessions: sessions)
        let meter = MeterClient(account: Self.account(host, digest: levelsDigest, keys: keys), sessions: sessions)
        async let probe = client.probe()
        try await Task.sleep(for: .milliseconds(50))
        let levels = try await meter.levels(songID: "s1")
        _ = await probe
        #expect(levels == .levels(Data("NXLV".utf8)))
        #expect(Self.requests(host, "/eq/hello").count == 1 && Self.requests(host, "/eq/session").count == 1)
        #expect(Self.routes(host).map { $0.headers["X-Session"] } == ["s1", "s1"])
    }

    /// A sign-in another login overtakes (a changed password, or one begun by a call naming no login) is
    /// cancelled, and the new one starts only once it has ended: never two at once, never two keys.
    @Test(arguments: ["old", nil] as [String?])
    func aDroppedSignInIsCancelledAndTheNextWaitsForIt(_ firstDigest: String?) async throws {
        let host = "session-dropped-\(firstDigest ?? "none")"
        var plan = Plan()
        plan.expects = "attestation"
        try Self.serve(host, plan)
        let keys = SlowKeys(delay: .milliseconds(300))
        let sessions = Self.sessions(Clock(Self.vectorTime))
        let first = HubClient(account: Self.account(host, digest: firstDigest, keys: keys), sessions: sessions)
        let second = HubClient(account: Self.account(host, digest: "new", keys: keys), sessions: sessions)
        async let dropped = first.probe()
        try await Task.sleep(for: .milliseconds(50))
        guard case .shown = await second.probe() else {
            Issue.record("the new login signs in")
            return
        }
        #expect(await dropped == .unreachable, "the dropped sign-in's caller gets no answer")
        #expect(await keys.mostAtOnce == 1, "the new sign-in began after the dropped one ended")
        #expect(Self.requests(host, "/eq/session").count == 1, "the dropped sign-in went no further")
        #expect(await keys.attested == 1, "one key")
        #expect(Self.routes(host).map { $0.headers["X-Session"] } == ["s1"])
    }

    @Test func aSessionAboutToRunOutIsRenewedBeforeUse() async throws {
        let host = "session-expiry"
        var plan = Plan()
        plan.expires = 3600
        try Self.serve(host, plan)
        let clock = Clock(Self.vectorTime)
        let client = HubClient(account: Self.account(host), sessions: Self.sessions(clock))
        _ = await client.probe()
        clock.advance(3000)
        _ = await client.probe()
        #expect(Self.requests(host, "/eq/hello").count == 1)
        clock.advance(550)
        _ = await client.probe()
        #expect(Self.requests(host, "/eq/hello").count == 2)
        #expect(Self.routes(host).map { $0.headers["X-Session"] } == ["s1", "s1", "s2"])
    }

    @Test func anotherAccountOrASignOutDropsTheSession() async throws {
        let host = "session-accounts"
        try Self.serve(host, Plan())
        let sessions = Self.sessions(Clock(Self.vectorTime))
        let first = HubClient(account: Self.account(host), sessions: sessions)
        let other = HubClient(account: Self.account(host, username: "other"), sessions: sessions)
        _ = await first.probe()
        _ = await other.probe()
        _ = await first.probe()
        #expect(Self.requests(host, "/eq/hello").count == 3)
        await sessions.dropAll()
        _ = await first.probe()
        #expect(Self.requests(host, "/eq/hello").count == 4)
        #expect(Self.routes(host).map { $0.headers["X-Session"] } == ["s1", "s2", "s3", "s4"])
    }

    // MARK: The key

    @Test func aFailingKeySendsNullMaterial() async throws {
        let host = "session-key-fails"
        var plan = Plan()
        plan.expects = "assertion"
        try Self.serve(host, plan)
        let keys = Keys(keyID: "k1", fails: true)
        let client = HubClient(account: Self.account(host, keys: keys), sessions: Self.sessions(Clock(Self.vectorTime)))
        guard case .shown = await client.probe() else {
            Issue.record("the sign-in goes on without the key")
            return
        }
        #expect(Self.json(Self.requests(host, "/eq/hello").first)["key"] as? String == "k1")
        let body = Self.json(Self.requests(host, "/eq/session").first)
        #expect(body["key"] is NSNull && body["attestation"] is NSNull && body["assertion"] is NSNull)
        #expect(Self.routes(host).first?.headers["X-Session"] == "s1")
    }

    @Test func aFailingAttestationSendsNullMaterial() async throws {
        let host = "session-attest-fails"
        var plan = Plan()
        plan.expects = "attestation"
        try Self.serve(host, plan)
        let keys = Keys(fails: true)
        let sessions = Self.sessions(Clock(Self.vectorTime))
        let client = HubClient(account: Self.account(host, keys: keys), sessions: sessions)
        _ = await client.probe()
        let body = Self.json(Self.requests(host, "/eq/session").first)
        #expect(body["key"] is NSNull && body["attestation"] is NSNull && body["assertion"] is NSNull)
        #expect(await keys.hashes.count == 1)
        // Failing on the phone pauses attesting too.
        await sessions.dropAll()
        _ = await client.probe()
        #expect(Self.requests(host, "/eq/hello").count == 2)
        #expect(await keys.hashes.count == 1, "not tried again within the hour")
    }

    @Test func aKeyTheServerDoesntKnowIsReplacedByANewOne() async throws {
        let host = "session-new-key"
        var plan = Plan()
        plan.expects = "attestation"
        try Self.serve(host, plan)
        let keys = Keys(keyID: "old-key")
        let client = HubClient(account: Self.account(host, username: "API", keys: keys), sessions: Self.sessions(Clock(Self.vectorTime)))
        _ = await client.probe()
        #expect(Self.json(Self.requests(host, "/eq/hello").first)["key"] as? String == "old-key")
        #expect(await keys.forgot == 1)
        #expect(await keys.attested == 1)
        #expect(await keys.hashes.map(Self.hex) == [Self.vectorHash], "the challenge bound to the lower-cased username")
        let body = Self.json(Self.requests(host, "/eq/session").first)
        #expect(body["key"] as? String == "new-key")
        #expect(body["attestation"] as? String == Data("ATT".utf8).base64EncodedString())
        #expect(body["assertion"] is NSNull)
    }

    @Test func aKnownKeyAsserts() async throws {
        let host = "session-assert"
        var plan = Plan()
        plan.expects = "assertion"
        try Self.serve(host, plan)
        let keys = Keys(keyID: "k1")
        let client = HubClient(account: Self.account(host, keys: keys), sessions: Self.sessions(Clock(Self.vectorTime)))
        _ = await client.probe()
        #expect(await keys.hashes.map(Self.hex) == [Self.vectorHash])
        let body = Self.json(Self.requests(host, "/eq/session").first)
        #expect(body["key"] as? String == "k1")
        #expect(body["assertion"] as? String == Data("ASR".utf8).base64EncodedString())
        #expect(body["attestation"] is NSNull)
        #expect(await keys.forgot == 0)
        #expect(await keys.attested == 0)
    }

    @Test func aRefusedSessionStepSaysHelloOnceMore() async throws {
        let host = "session-step-retry"
        var plan = Plan()
        plan.expects = "assertion"
        plan.sessionRefusals = 1
        try Self.serve(host, plan)
        let keys = Keys(keyID: "k1")
        let client = HubClient(account: Self.account(host, keys: keys), sessions: Self.sessions(Clock(Self.vectorTime)))
        guard case .shown = await client.probe() else {
            Issue.record("the second session step is let in")
            return
        }
        #expect(Self.requests(host, "/eq/hello").count == 2 && Self.requests(host, "/eq/session").count == 2)
        #expect(await keys.hashes.count == 2, "a new challenge, so a new assertion")
        #expect(await keys.forgot == 0)
        #expect(Self.routes(host).first?.headers["X-Session"] == "s2")
    }

    @Test func aSessionStepRefusedTwiceFallsBackAndKeepsTheKey() async throws {
        let host = "session-step-refused"
        var plan = Plan()
        plan.expects = "assertion"
        plan.sessionRefusals = .max
        try Self.serve(host, plan)
        let keys = Keys(keyID: "k1")
        let client = HubClient(account: Self.account(host, keys: keys), sessions: Self.sessions(Clock(Self.vectorTime)))
        _ = await client.probe()
        #expect(Self.requests(host, "/eq/hello").count == 2 && Self.requests(host, "/eq/session").count == 2)
        #expect(await keys.forgot == 0, "a refusal can be a passing lock: the key stays")
        #expect(await keys.keyID == "k1")
        let old = try #require(Self.routes(host).first)
        #expect(old.headers["X-Subsonic-Login"] == "u=api&t=tok&s=salt")
        #expect(Self.sessionHeaders.allSatisfy { old.headers[$0] == nil }, "no session header on the old way")
        _ = await client.probe()
        #expect(Self.requests(host, "/eq/hello").count == 2, "the old way for ten minutes")
    }

    @Test func aRefusedAttestationMakesOneKeyAndTheSecondRoundCarriesNulls() async throws {
        let host = "session-attest-refused"
        var plan = Plan()
        plan.expects = "known"
        plan.sessionRefusals = 1
        try Self.serve(host, plan)
        let keys = Keys()
        let client = HubClient(account: Self.account(host, keys: keys), sessions: Self.sessions(Clock(Self.vectorTime)))
        guard case .shown = await client.probe() else {
            Issue.record("the second round's unattested session is let in")
            return
        }
        #expect(await keys.attested == 1, "one key in one sign-in")
        #expect(await keys.keyID == "new-key", "kept: the next hello says whether the server has it")
        #expect(await keys.forgot == 0)
        let hellos = Self.requests(host, "/eq/hello").map(Self.json)
        #expect(hellos.count == 2 && hellos.first?["key"] is NSNull && hellos.last?["key"] as? String == "new-key")
        let steps = Self.requests(host, "/eq/session").map(Self.json)
        #expect(steps.count == 2)
        #expect(steps.first?["attestation"] as? String == Data("ATT".utf8).base64EncodedString())
        #expect(steps.last.map { $0["key"] is NSNull && $0["attestation"] is NSNull && $0["assertion"] is NSNull } == true)
        #expect(Self.routes(host).first?.headers["X-Session"] == "s2")
    }

    @Test func noNewAttestationWithinTheHourButAnAssertionStillGoesOut() async throws {
        let host = "session-attest-pause"
        var plan = Plan()
        plan.expects = "known"
        plan.sessionRefusals = 1
        try Self.serve(host, plan)
        let clock = Clock(Self.vectorTime)
        let sessions = Self.sessions(clock)
        let keys = Keys()
        let client = HubClient(account: Self.account(host, keys: keys), sessions: sessions)
        _ = await client.probe()
        #expect(await keys.attested == 1)

        clock.advance(1800)
        await sessions.dropAll()
        _ = await client.probe()
        #expect(await keys.attested == 1, "no new key within the hour")
        #expect(Self.json(Self.requests(host, "/eq/session").last)["attestation"] is NSNull)

        // A key the server knows asserts as usual meanwhile.
        await keys.set(keyID: "k9")
        await sessions.dropAll()
        _ = await client.probe()
        let asserted = Self.json(Self.requests(host, "/eq/session").last)
        #expect(asserted["key"] as? String == "k9")
        #expect(asserted["assertion"] as? String == Data("ASR".utf8).base64EncodedString())

        clock.advance(1801)
        await keys.forgetKey()
        await sessions.dropAll()
        _ = await client.probe()
        #expect(await keys.attested == 2, "after the hour a key is attested again")
        #expect(Self.json(Self.requests(host, "/eq/session").last)["key"] as? String == "new-key")
    }

    // MARK: The audit's fixes (2026-11-15b)

    /// T1: a hello's clock that can't sign used to trap at every launch.
    @Test(arguments: ["1e300", "-1e300", "1e400", "9.3e18", "\(Int(HubSessionTests.vectorTime) + 400 * 86_400)"])
    func aHelloWithAnImpossibleClockIsRefused(_ now: String) async throws {
        let host = "session-clock-\(abs(now.hashValue))"
        var plan = Plan()
        plan.rawNow = now
        plan.route = { _, seen in seen.headers["X-Subsonic-Login"] == nil ? 302 : 200 }
        try Self.serve(host, plan)
        let client = HubClient(account: Self.account(host), sessions: Self.sessions(Clock(Self.vectorTime)))
        guard case .shown = await client.probe() else {
            Issue.record("the old way answers")
            return
        }
        #expect(Self.requests(host, "/eq/session").isEmpty, "refused at hello")
        _ = await client.probe()
        #expect(Self.requests(host, "/eq/hello").count == 1, "remembered as a refused hello")
        #expect(Self.routes(host).allSatisfy { $0.headers["X-Subsonic-Login"] == "u=api&t=tok&s=salt" })
    }

    @Test func aSessionThatCantRunOutIsNoSession() async throws {
        let host = "session-endless"
        var plan = Plan()
        plan.rawExpires = "1e400"
        try Self.serve(host, plan)
        let client = HubClient(account: Self.account(host), sessions: Self.sessions(Clock(Self.vectorTime)))
        _ = await client.probe()
        #expect(Self.routes(host).allSatisfy { $0.headers["X-Session"] == nil })
    }

    @Test func aClockThatCantBeSentSendsTheOldWay() throws {
        let sessions = Self.sessions(Clock(Self.vectorTime))
        let session = HubSessions.Session(
            id: "s", secret: Self.secret, created: .now, expires: .distantFuture, offset: .greatestFiniteMagnitude
        )
        let request = URLRequest(url: URL(string: "http://h:4600/panel")!)
        #expect(sessions.sign(request, base: URL(string: "http://h:4600")!, with: session) == nil)
    }

    /// T3: a changed password made no new session.
    @Test func aChangedLoginIsAnotherSession() async throws {
        let host = "session-new-password"
        try Self.serve(host, Plan())
        let sessions = Self.sessions(Clock(Self.vectorTime))
        _ = await HubClient(account: Self.account(host, digest: "old"), sessions: sessions).probe()
        _ = await HubClient(account: Self.account(host, digest: "new"), sessions: sessions).probe()
        #expect(Self.requests(host, "/eq/hello").count == 2, "the new password signs in again")
        // A call that names no login (the levels) takes the session in use.
        let meter = MeterClient(account: Self.account(host), sessions: sessions)
        #expect(try await meter.levels(songID: "s1") == .levels(Data("NXLV".utf8)))
        _ = await HubClient(account: Self.account(host, digest: "new"), sessions: sessions).probe()
        #expect(Self.requests(host, "/eq/hello").count == 2)
        #expect(Self.routes(host).map { $0.headers["X-Session"] } == ["s1", "s2", "s2", "s2"])
    }

    /// T4: one account's refused hello sent another account the old way for ten minutes.
    @Test func theOldWayIsRememberedPerAccount() async throws {
        let host = "session-fallback-account"
        var plan = Plan()
        plan.helloFor = { seen in seen.headers["X-Subsonic-Login"]?.hasPrefix("u=test&") == true ? 405 : 200 }
        try Self.serve(host, plan)
        let sessions = Self.sessions(Clock(Self.vectorTime))
        _ = await HubClient(account: Self.account(host, username: "test", digest: "t"), sessions: sessions).probe()
        _ = await HubClient(account: Self.account(host, username: "api", digest: "a"), sessions: sessions).probe()
        #expect(Self.requests(host, "/eq/hello").count == 2, "the other account says hello")
        _ = await HubClient(account: Self.account(host, username: "test", digest: "t"), sessions: sessions).probe()
        #expect(Self.requests(host, "/eq/hello").count == 2, "the refused one keeps the old way")
        #expect(Self.routes(host).map { $0.headers["X-Session"] } == [nil, "s1", nil])
    }

    /// T11: a sign-in that takes too long isn't waited for; its answer serves the next call.
    @Test func aSlowSignInIsntWaitedForEver() async throws {
        let host = "session-slow-hello"
        var plan = Plan()
        plan.helloDelay = 0.6
        try Self.serve(host, plan)
        let sessions = HubSessions(
            session: StubProtocol.session, now: Clock(Self.vectorTime).now, random: { Data(repeating: 0, count: $0) },
            signInWait: { _ in .milliseconds(100) }
        )
        let client = HubClient(account: Self.account(host), sessions: sessions)
        #expect(await client.probe() == .unreachable)
        try await Task.sleep(for: .milliseconds(900))
        guard case .shown = await client.probe() else {
            Issue.record("the sign-in's answer is kept for the next call")
            return
        }
        #expect(Self.requests(host, "/eq/hello").count == 1)
        #expect(HubSessions.signInWait(limit: HubClient.timeout) == .seconds(140))
    }

    @Test func aKeyThatNeverAnswersIsNotWaitedFor() async {
        let value = await HubSessions.within(.milliseconds(50)) {
            try await Task.sleep(for: .seconds(30))
            return 1
        }
        #expect(value == nil)
        #expect(await HubSessions.within(.seconds(5)) { 2 } == 2)
    }
}

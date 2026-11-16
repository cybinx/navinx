import CryptoKit
import Foundation
import Synchronization

/// The app's own key, proving a sign-in comes from the app (Apple's App Attest in the app; tests use
/// stand-ins). Any call may fail for any reason: the sign-in then goes without the key's proof.
public protocol HubKeyProvider: Sendable {
    /// The id of the key in use, if there is one.
    func currentKeyID() async -> String?
    /// Makes a new key, attests it for `clientDataHash` and keeps it as the key in use.
    func attestNewKey(clientDataHash: Data) async throws -> HubAttestedKey
    /// The key in use's assertion for `clientDataHash`.
    func assertion(clientDataHash: Data) async throws -> Data
    /// Forgets the key in use.
    func forgetKey() async
}

public struct HubAttestedKey: Sendable, Equatable {
    public let keyID: String
    public let attestation: Data

    public init(keyID: String, attestation: Data) {
        self.keyID = keyID
        self.attestation = attestation
    }
}

/// No key: every sign-in goes without the proof.
public struct NoHubKey: HubKeyProvider {
    struct Unavailable: Error {}

    public init() {}
    public func currentKeyID() async -> String? { nil }
    public func attestNewKey(clientDataHash: Data) async throws -> HubAttestedKey { throw Unavailable() }
    public func assertion(clientDataHash: Data) async throws -> Data { throw Unavailable() }
    public func forgetKey() async {}
}

/// Who signs in to the hub, and where.
public struct HubAccount: Sendable {
    /// The account's address in use, keeping any path prefix.
    public let baseURL: URL
    public let username: String
    /// `SubsonicClient.signedLoginQuery(for:)` for this address. Only an account that has one is made,
    /// so where that function says no, nothing is sent at all.
    public let login: String
    /// A digest of the account's whole login (its password among it), held in memory only: another one
    /// at the same address and username (a changed password) is another account, with its own session.
    /// Nil: the session for the address and username in use, whatever its login.
    public let loginDigest: Data?
    public let keys: any HubKeyProvider

    public init(
        baseURL: URL, username: String, login: String, loginDigest: Data? = nil, keys: any HubKeyProvider = NoHubKey()
    ) {
        self.baseURL = baseURL
        self.username = username
        self.login = login
        self.loginDigest = loginDigest
        self.keys = keys
    }

    fileprivate var slot: HubSessions.Slot {
        HubSessions.Slot(address: baseURL.absoluteString, username: username.lowercased(), login: loginDigest)
    }
}

/// The hub's sessions (protocol v1, `docs/log/C33.md`): the login goes to the server once, at `hello`
/// and `session`, and every request after that is signed with the session's secret instead. One session
/// at a time, for the account and address in use: another account, login or address drops it. The id, the
/// secret and the clock's difference live in memory only.
public actor HubSessions {
    public static let shared = HubSessions()

    /// After a refused hello the old way is used this long, per address and account (an older server, or
    /// none).
    public static let fallbackPeriod: TimeInterval = 600
    /// A hello whose clock is further than this from the phone's is refused (a server's clock a year out
    /// is broken, and the signing time is built from it).
    public static let clockLimit: TimeInterval = 366 * 86_400
    /// A session this close to running out is renewed before it's used.
    public static let renewMargin: TimeInterval = 60
    /// A refusal on a session made less than this long ago is the answer: the session is good, the route
    /// just isn't for this account (one not on the server's list), so it's kept, with no renewal.
    public static let freshPeriod: TimeInterval = 60
    /// Apple's side of the key can be slow, or never answer: a sign-in doesn't wait for it longer.
    public static let keyTimeout: Duration = .seconds(20)
    /// After an attestation refused or failed, no new key for this long, per account and address.
    public static let attestPause: TimeInterval = 3600
    static let version = 1
    static let sessionHeader = "X-Session"
    static let timeHeader = "X-Session-Time"
    static let nonceHeader = "X-Session-Nonce"
    static let signatureHeader = "X-Session-Signature"

    struct Slot: Hashable {
        let address: String
        let username: String
        /// `HubAccount.loginDigest`.
        let login: Data?

        /// Whether what's kept for this slot serves `wanted`: the same address and username, and the same
        /// login unless `wanted` names none.
        func serves(_ wanted: Slot) -> Bool {
            address == wanted.address && username == wanted.username && (wanted.login == nil || wanted.login == login)
        }

        /// The address and username alone (attesting pauses for the account, whatever its password).
        var place: Slot { Slot(address: address, username: username, login: nil) }
    }

    struct Session: Sendable {
        let id: String
        let secret: Data
        /// By the phone's clock.
        let created: Date
        let expires: Date
        /// The server's clock minus the phone's, from hello's `now`.
        let offset: TimeInterval
    }

    enum Credential: Sendable {
        case session(Session)
        /// The request goes the old way, with the login.
        case login
        case unreachable
    }

    enum SignIn: Sendable {
        case session(Session)
        /// Hello refused, or the session step twice: the old way, remembered for `fallbackPeriod`.
        case refused
        /// A server error or a rate limit: the old way, this once.
        case busy
        case unreachable
    }

    /// The transport: the one given (tests), else the hub's current one, renewed when the device's
    /// certificate changes (`HubClient.session`).
    nonisolated var session: URLSession { givenSession ?? HubClient.session }
    private let givenSession: URLSession?
    let now: @Sendable () -> Date
    let random: @Sendable (Int) -> Data
    /// How long a call waits for a sign-in on its way, by the sign-in's timeout (`signInWait(limit:)`).
    let signInWait: @Sendable (TimeInterval) -> Duration

    private var current: (slot: Slot, session: Session)?
    private var pending: (slot: Slot, ticket: Int, task: Task<SignIn, Never>)?
    /// A sign-in dropped on its way, cancelled, per address and username (`Slot.place`) until the next
    /// one there has started: that one waits for it to end first, so two sign-ins for one account never
    /// run at once (each could make a key, or race the other's assertions).
    private var ending: [Slot: Task<SignIn, Never>] = [:]
    private var tickets = 0
    /// Until when the old way is used, per address and account.
    private var fallback: [Slot: Date] = [:]
    /// Until when attesting waits, per account and address (`pauseAttesting`). In memory only.
    private let attestPauses = Mutex<[Slot: Date]>([:])

    /// `session` is the transport (tests add their stub protocol); `now` and `random` are the clock and
    /// the random bytes (the nonces).
    public init(
        session: URLSession? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        random: @escaping @Sendable (Int) -> Data = HubSessions.secureRandom
    ) {
        self.init(session: session, now: now, random: random, signInWait: Self.signInWait(limit:))
    }

    init(
        session: URLSession?, now: @escaping @Sendable () -> Date, random: @escaping @Sendable (Int) -> Data,
        signInWait: @escaping @Sendable (TimeInterval) -> Duration
    ) {
        givenSession = session
        self.now = now
        self.random = random
        self.signInWait = signInWait
    }

    /// The longest a call waits for a sign-in on its way (a hello and a session step, each within its
    /// deadline, and the key between them); after it the call goes unanswered, and the sign-in carries on
    /// for the next one.
    static func signInWait(limit: TimeInterval) -> Duration {
        HubTransport.deadline(for: limit) * 2 + keyTimeout
    }

    /// Forgets the session and any sign-in on its way (a sign-out).
    public func dropAll() {
        current = nil
        dropPending()
    }

    /// The sign-in on its way is no longer wanted: it's cancelled, and the next one for its address and
    /// username waits for it to end.
    private func dropPending() {
        guard let pending else { return }
        pending.task.cancel()
        ending[pending.slot.place] = pending.task
        self.pending = nil
    }

    // MARK: Sending

    /// Sends `request` (built for an address under `account.baseURL`, with no login on it) signed with
    /// the session, signing in first if needed. A refusal (`isRefusal`) on a session just made is the
    /// answer, and the session stays. On an older one (the server restarted, or 12 hours unused) the
    /// session is dropped; one new sign-in and one more try follow, the second answer is the answer and
    /// the new session stays.
    nonisolated func send(
        _ request: URLRequest, as account: HubAccount, maxBytes: Int = HubTransport.maxBytes,
        isRefusal: @Sendable (HTTPURLResponse, Data) -> Bool
    ) async throws(HubError) -> (Data, HTTPURLResponse) {
        var stale: String?
        for attempt in 0..<2 {
            let credential = await credential(for: account, timeout: request.timeoutInterval, replacing: stale)
            switch credential {
            case .unreachable:
                throw .unreachable
            case .login:
                return try await HubTransport.load(Self.withLogin(request, account.login), session: session, maxBytes: maxBytes)
            case .session(let current):
                guard let signed = sign(request, base: account.baseURL, with: current) else {
                    return try await HubTransport.load(Self.withLogin(request, account.login), session: session, maxBytes: maxBytes)
                }
                let (data, response) = try await HubTransport.load(signed, session: session, maxBytes: maxBytes)
                guard attempt == 0, isRefusal(response, data),
                      now().timeIntervalSince(current.created) >= Self.freshPeriod else { return (data, response) }
                stale = current.id
            }
        }
        throw .unreachable   // not reached: the second try always returns
    }

    /// The session for `account`, a sign-in shared by every caller while it's on its way.
    func credential(for account: HubAccount, timeout: TimeInterval, replacing stale: String?) async -> Credential {
        let slot = account.slot
        // Another account, login or address: the old session goes, and its sign-in's answer is for
        // something else. A call naming no login (`serves`) takes the session or sign-in for its address
        // and username, whatever their login.
        if let current, !current.slot.serves(slot) { self.current = nil }
        if let pending, !pending.slot.serves(slot) { dropPending() }
        if let stale, current?.session.id == stale { current = nil }
        let now = now()
        if let session = current?.session, session.expires.timeIntervalSince(now) > Self.renewMargin {
            return .session(session)
        }
        current = nil
        if fallback.contains(where: { $0.key.serves(slot) && $0.value > now }) { return .login }
        let ticket: Int
        let made: Slot
        let task: Task<SignIn, Never>
        let limit = min(timeout, HubClient.timeout)
        if let pending {
            (ticket, made, task) = (pending.ticket, pending.slot, pending.task)
        } else {
            tickets += 1
            ticket = tickets
            made = slot
            let before = ending.removeValue(forKey: slot.place)
            task = Task {
                // A dropped sign-in for this account ends first (it was cancelled, so it ends soon).
                _ = await before?.value
                return await self.signIn(account, timeout: limit)
            }
            pending = (slot, ticket, task)
        }
        // A sign-in that takes too long isn't waited for: this call goes unanswered, and the sign-in's
        // answer is kept by the next call that finds it.
        guard let result = await Self.within(signInWait(limit), { await task.value }) else { return .unreachable }
        // Only the sign-in still wanted is kept (not one a sign-out or another account overtook).
        if pending?.ticket == ticket {
            pending = nil
            switch result {
            case .session(let session): current = (made, session)
            case .refused:
                let now = self.now()
                fallback = fallback.filter { $0.value > now }
                fallback[made] = now.addingTimeInterval(Self.fallbackPeriod)
            case .busy, .unreachable: break
            }
        }
        switch result {
        case .session(let session): return .session(session)
        case .refused, .busy: return .login
        case .unreachable: return .unreachable
        }
    }

    // MARK: Signing in

    /// `POST /eq/hello`, then `POST /eq/session`, both with the login. A refused session step is tried
    /// once more from a new hello (the server uses the challenge up once the login has checked); only a
    /// second refusal falls back.
    nonisolated func signIn(_ account: HubAccount, timeout: TimeInterval) async -> SignIn {
        var proof = true
        for round in 0..<2 {
            switch await signInOnce(account, timeout: timeout, proof: proof) {
            case .done(let result):
                return result
            case .sessionRefused(let attested):
                if attested {
                    // The step that carried the new key wasn't let in, or its answer couldn't be read: the
                    // second round sends no proof, so one sign-in never makes two keys. The key stays: the
                    // next hello says whether the server kept it (an assertion) or not (a new key, and
                    // only then is this one let go).
                    pauseAttesting(account.slot)
                    proof = false
                }
                if round == 1 { return .refused }
            }
        }
        return .refused   // not reached: the second round always returns
    }

    private enum Step {
        case done(SignIn)
        /// `attested`: the step carried a new key's attestation.
        case sessionRefused(attested: Bool)
    }

    /// No attesting for an account and address for `attestPause` after an attestation was refused or
    /// failed on the phone: keys aren't made freely (Apple asks so, and the server keeps few per user).
    private nonisolated func pauseAttesting(_ slot: Slot) {
        attestPauses.withLock { $0[slot.place] = now().addingTimeInterval(Self.attestPause) }
    }

    private nonisolated func mayAttest(_ slot: Slot) -> Bool {
        attestPauses.withLock { ($0[slot.place] ?? .distantPast) <= now() }
    }

    /// `proof`: false sends null key material whatever hello expects.
    private nonisolated func signInOnce(_ account: HubAccount, timeout: TimeInterval, proof: Bool) async -> Step {
        let keyID = await account.keys.currentKeyID()
        let hello: Hello
        let challenge: Data
        switch await post(["v": Self.version, "key": keyID ?? NSNull()], to: "hello", as: account, timeout: timeout) {
        case .answer(let data):
            guard let decoded = try? JSONDecoder().decode(Hello.self, from: data), decoded.v == Self.version,
                  let bytes = Data(base64Encoded: decoded.challenge), !bytes.isEmpty else { return .done(.refused) }
            (hello, challenge) = (decoded, bytes)
        case .refused: return .done(.refused)
        case .busy: return .done(.busy)
        case .unreachable: return .done(.unreachable)
        }
        // A server's clock that isn't a number, or is implausibly far from the phone's, can't sign: the
        // hello is refused (the signing time is built from it).
        let offset = hello.now - now().timeIntervalSince1970
        guard offset.isFinite, abs(offset) <= Self.clockLimit else { return .done(.refused) }
        // A sign-in dropped while saying hello goes no further: it neither makes a key nor asserts one.
        guard !Task.isCancelled else { return .done(.unreachable) }
        let hash = Self.clientDataHash(challenge: challenge, username: account.username)
        var key: String?
        var attestation: Data?
        var assertion: Data?
        switch hello.expects {
        case "assertion" where proof:
            if let keyID, let made = await Self.within(Self.keyTimeout, { try await account.keys.assertion(clientDataHash: hash) }) {
                (key, assertion) = (keyID, made)
            }
        case "attestation":
            // The server doesn't know the key the app holds (it lost its keys, holds it for another
            // username, or never got its attestation): a key is attested only once, so a new one. The only
            // time a key is let go here: a refusal or no answer can be a passing lock, the music server
            // down or the network, and keys aren't made freely.
            if keyID != nil { await account.keys.forgetKey() }
            guard proof, mayAttest(account.slot) else { break }
            if let made = await Self.within(Self.keyTimeout, { try await account.keys.attestNewKey(clientDataHash: hash) }) {
                (key, attestation) = (made.keyID, made.attestation)
            } else {
                pauseAttesting(account.slot)
            }
        default:
            break
        }
        let body: [String: Any] = [
            "v": Self.version, "challenge": hello.challenge, "key": key ?? NSNull(),
            "attestation": attestation?.base64EncodedString() ?? NSNull(),
            "assertion": assertion?.base64EncodedString() ?? NSNull(),
        ]
        switch await post(body, to: "session", as: account, timeout: timeout) {
        case .answer(let data):
            guard let granted = try? JSONDecoder().decode(Granted.self, from: data), granted.v == Self.version,
                  !granted.session.isEmpty, let secret = Data(base64Encoded: granted.secret), !secret.isEmpty,
                  granted.expires.isFinite, granted.expires > 0 else { return .sessionRefused(attested: attestation != nil) }
            let made = now()
            return .done(.session(Session(
                id: granted.session, secret: secret, created: made, expires: made.addingTimeInterval(granted.expires),
                offset: offset
            )))
        case .refused: return .sessionRefused(attested: attestation != nil)
        case .busy: return .done(.busy)
        case .unreachable: return .done(.unreachable)
        }
    }

    private enum Posted {
        case answer(Data)
        case refused
        case busy
        case unreachable
    }

    private nonisolated func post(
        _ body: [String: Any], to step: String, as account: HubAccount, timeout: TimeInterval
    ) async -> Posted {
        var request = URLRequest(
            url: account.baseURL.appending(path: "eq").appending(path: step),
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard let (data, response) = try? await HubTransport.load(Self.withLogin(request, account.login), session: session)
        else { return .unreachable }
        switch response.statusCode {
        case 200: return .answer(data)
        case 429, 500...599: return .busy
        default: return .refused
        }
    }

    private struct Hello: Decodable {
        let v: Int
        let challenge: String
        let expects: String
        let now: TimeInterval
    }

    private struct Granted: Decodable {
        let v: Int
        let session: String
        let secret: String
        let expires: TimeInterval
    }

    // MARK: Signing

    /// The request with the session's four headers and no login; nil when its address isn't under `base`,
    /// or when the corrected clock isn't a whole number of seconds a request can carry.
    nonisolated func sign(_ request: URLRequest, base: URL, with session: Session) -> URLRequest? {
        guard let url = request.url, let path = Self.routePath(of: url, base: base),
              let seconds = Int(exactly: (now().timeIntervalSince1970 + session.offset).rounded(.down))
        else { return nil }
        let time = String(seconds)
        let nonce = Self.base64URL(random(12))
        var signed = request
        signed.setValue(nil, forHTTPHeaderField: HubClient.loginHeader)
        signed.setValue(session.id, forHTTPHeaderField: Self.sessionHeader)
        signed.setValue(time, forHTTPHeaderField: Self.timeHeader)
        signed.setValue(nonce, forHTTPHeaderField: Self.nonceHeader)
        signed.setValue(
            Self.signature(
                secret: session.secret, method: request.httpMethod ?? "GET", path: path, time: time, nonce: nonce,
                body: request.httpBody ?? Data()
            ),
            forHTTPHeaderField: Self.signatureHeader
        )
        return signed
    }

    /// Base64 of HMAC-SHA256 over the method, the path, the time, the nonce and the body's hash.
    static func signature(secret: Data, method: String, path: String, time: String, nonce: String, body: Data) -> String {
        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let message = [method.uppercased(), path, time, nonce, bodyHash].joined(separator: "\n")
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: secret))
        return Data(code).base64EncodedString()
    }

    /// What the key signs at sign-in: the challenge, bound to the account.
    public static func clientDataHash(challenge: Data, username: String) -> Data {
        var data = Data("navinx-session-v1\n".utf8)
        data.append(challenge)
        data.append(Data("\n".utf8))
        data.append(Data(username.lowercased().utf8))
        return Data(SHA256.hash(data: data))
    }

    /// The path from the route on (`/panel…`, `/eq/…`), percent-encoded as sent, without the prefix the
    /// account's address carries; nil when `url` isn't under `base`.
    static func routePath(of url: URL, base: URL) -> String? {
        let full = url.path(percentEncoded: true)
        var prefix = base.path(percentEncoded: true)
        while prefix.hasSuffix("/") { prefix.removeLast() }
        guard full.hasPrefix(prefix + "/") else { return nil }
        return String(full.dropFirst(prefix.count))
    }

    static func withLogin(_ request: URLRequest, _ login: String) -> URLRequest {
        var request = request
        request.setValue(login, forHTTPHeaderField: HubClient.loginHeader)
        return request
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The system's generator, which is cryptographically secure on Apple's systems.
    public static func secureRandom(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// `work`'s answer, or nil when it fails or takes longer than `limit` (it isn't waited for then).
    static func within<Value: Sendable>(
        _ limit: Duration, _ work: @escaping @Sendable () async throws -> Value
    ) async -> Value? {
        let once = Once<Value>()
        return await withCheckedContinuation { continuation in
            once.set(continuation)
            let worker = Task {
                let value = try? await work()
                once.resume(value)
            }
            let timer = Task {
                try? await Task.sleep(for: limit)
                once.resume(nil)
                worker.cancel()
            }
            // Work done in time: the timer goes too.
            Task {
                _ = await worker.value
                timer.cancel()
            }
        }
    }
}

/// A continuation resumed by whichever comes first.
private final class Once<Value: Sendable>: Sendable {
    private let continuation = Mutex<CheckedContinuation<Value?, Never>?>(nil)

    func set(_ continuation: CheckedContinuation<Value?, Never>) {
        self.continuation.withLock { $0 = continuation }
    }

    func resume(_ value: Value?) {
        continuation.withLock { $0.take() }?.resume(returning: value)
    }
}

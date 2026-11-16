import Foundation
import Synchronization

/// How a server takes devices (`hello`'s `devices`).
public enum DeviceRule: String, Sendable, Equatable {
    case off, optional, required
}

/// `GET /eq/enroll/hello`'s answer.
public struct EnrollHello: Sendable, Equatable {
    public var devices: DeviceRule
    /// This connection presented a certificate the add-on knows and hasn't revoked.
    public var approved: Bool
    /// A live invite waits for this username.
    public var invited: Bool
    /// Where the invite's code went, masked by the add-on.
    public var to: String?
    public var attest: DeviceRule

    public init(devices: DeviceRule, approved: Bool, invited: Bool, to: String? = nil, attest: DeviceRule = .off) {
        self.devices = devices
        self.approved = approved
        self.invited = invited
        self.to = to
        self.attest = attest
    }
}

public enum HelloResult: Sendable, Equatable {
    case answer(EnrollHello)
    /// Anything that isn't a v1 hello: a stock music server's own answer to an unknown path (a 302 or a
    /// 404), a refusal, a body this build can't read. The server doesn't approve devices, as far as the
    /// app is concerned, and nothing changes.
    case notOffered
    /// No answer, a server error or a rate limit.
    case unreachable
}

/// What the device sends with its application (`POST /eq/enroll/request`).
public struct EnrollApplication: Sendable, Equatable {
    public var code: String
    public var csr: Data
    public var deviceID: String
    public var name: String
    public var model: String
    public var system: String
    public var app: String
    public var attestKey: String?
    public var attestation: Data?

    public init(
        code: String, csr: Data, deviceID: String, name: String, model: String, system: String, app: String,
        attestKey: String? = nil, attestation: Data? = nil
    ) {
        self.code = code
        self.csr = csr
        self.deviceID = deviceID
        self.name = name
        self.model = model
        self.system = system
        self.app = app
        self.attestKey = attestKey
        self.attestation = attestation
    }

    /// The JSON body, as the protocol writes it.
    public var body: [String: Any] {
        [
            "v": 1,
            "code": code,
            "csr": csr.base64EncodedString(),
            "device": ["id": deviceID, "name": name, "model": model, "system": system, "app": app],
            "key": attestKey ?? NSNull(),
            "attestation": attestation?.base64EncodedString() ?? NSNull(),
        ]
    }
}

public enum ApplyResult: Sendable, Equatable {
    /// Filed, waiting for the owner (or approved at once: the status says).
    case filed(request: String)
    /// A wrong, used or expired code; `triesLeft` when the add-on says.
    case wrongCode(triesLeft: Int?)
    /// Applied from outside the invite's place.
    case wrongPlace
    case refused
    case unreachable
}

/// The certificate the add-on issued.
public struct IssuedCertificate: Sendable, Equatable {
    public var certificate: Data
    public var issuer: Data?
    public var renewAfter: Double

    public init(certificate: Data, issuer: Data?, renewAfter: Double) {
        self.certificate = certificate
        self.issuer = issuer
        self.renewAfter = renewAfter
    }
}

public enum StatusResult: Sendable, Equatable {
    case pending
    case denied
    case approved(IssuedCertificate)
    /// The add-on doesn't know the request, or the proof failed: the request is gone.
    case refused
    case unreachable
}

public enum RenewResult: Sendable, Equatable {
    case renewed(IssuedCertificate)
    case refused
    case unreachable
}

/// The add-on's enrolment routes, as the app uses them. `EnrollClient` is the real one; tests a stand-in.
public protocol EnrollAPI: Sendable {
    func hello() async -> HelloResult
    func apply(_ application: EnrollApplication) async -> ApplyResult
    /// `sign` is the pending key's signature over the status message.
    func status(request: String, sign: @Sendable (Data) throws -> Data) async -> StatusResult
    func renew(csr: Data) async -> RenewResult
    /// The same routes over a sign-in check's own sessions, which present only that login's identity
    /// (the review after C56). By default the routes themselves (a stand-in has no sessions).
    func using(_ sessions: LoginSessions) -> any EnrollAPI
}

extension EnrollAPI {
    public func using(_ sessions: LoginSessions) -> any EnrollAPI { self }
}

/// The enrolment routes over HTTP (C44, "The protocol, v1"). Always the profile's **main** address: the
/// home-network one is never asked (its `/eq` is the music server's own 404). Every call carries the
/// account's signed login (`X-Subsonic-Login`); redirects are never followed (a refusal is the music
/// server's own redirect); the device's certificate is presented where the device has one.
public struct EnrollClient: EnrollAPI {
    public static let helloTimeout: TimeInterval = 10
    public static let timeout: TimeInterval = 30
    public static let loginHeader = "X-Subsonic-Login"
    static let timeHeader = "X-Navinx-Time"
    static let proofHeader = "X-Navinx-Proof"

    public let baseURL: URL
    private let login: String
    /// Read for every request: the shared session is replaced when the certificate changes (`sessions`).
    /// Nil: a check's sessions that have ended; nothing is sent (no answer).
    private var session: @Sendable () -> URLSession?
    /// A fixed session (tests): `using` keeps it.
    private let fixedSession: Bool
    private let now: @Sendable () -> Date
    /// The server's clock minus the phone's, from the last answer's `Date` header, for the status proof's
    /// time (it must be within 120 s of the server's).
    private let offset = ClockOffset()

    /// `login`: `SubsonicClient.signedLoginQuery(for:)` for `baseURL`. `session`: a fixed one (tests); nil,
    /// the shared `sessions`.
    public init(
        baseURL: URL, login: String, session: URLSession? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseURL = baseURL
        self.login = login
        if let session {
            self.session = { session }
        } else {
            self.session = { EnrollClient.sessions.session }
        }
        fixedSession = session != nil
        self.now = now
    }

    /// Over a sign-in check's own enrolment session, which presents only that login's identity; a fixed
    /// session (tests) is kept.
    public func using(_ sessions: LoginSessions) -> any EnrollAPI {
        guard !fixedSession else { return self }
        var copy = self
        copy.session = { sessions.enrol.openSession }
        return copy
    }

    /// Ephemeral, no cookies or cache, no redirects followed, the signed-in profile's certificate presented.
    /// A new session whenever the certificate is stored or removed (the re-check, item 1): the gateway asks
    /// for it only in the TLS handshake, so the `hello` after an approval must not travel over a connection
    /// opened without it, where the answer is `approved:false`.
    public static let sessions = RenewableSession { makeSession(certificates: .shared, login: nil) }

    /// An enrolment session: presenting `login`'s own identity only where it's given (`LoginSessions`),
    /// else the signed-in profile's.
    static func makeSession(certificates: DeviceCertificates, login: DeviceLogin?) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let delegate = EnrollSessionDelegate(certificates: certificates, login: login)
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    static func route(_ base: URL, _ step: String) -> URL {
        base.appending(path: "eq").appending(path: "enroll").appending(path: step)
    }

    public func hello() async -> HelloResult {
        switch await send(Self.request(Self.route(baseURL, "hello"), timeout: Self.helloTimeout)) {
        case .answer(let json):
            guard let hello = Self.hello(from: json) else { return .notOffered }
            return .answer(hello)
        case .refused: return .notOffered
        case .unreachable: return .unreachable
        }
    }

    static func hello(from json: [String: Any]) -> EnrollHello? {
        guard json["v"] as? Int == 1, let devices = (json["devices"] as? String).flatMap(DeviceRule.init(rawValue:))
        else { return nil }
        return EnrollHello(
            devices: devices,
            approved: json["approved"] as? Bool ?? false,
            invited: json["invited"] as? Bool ?? false,
            to: json["to"] as? String,
            attest: (json["attest"] as? String).flatMap(DeviceRule.init(rawValue:)) ?? .off
        )
    }

    public func apply(_ application: EnrollApplication) async -> ApplyResult {
        var request = Self.request(Self.route(baseURL, "request"), timeout: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: application.body, options: [.sortedKeys])
        switch await send(request) {
        case .answer(let json): return Self.applyResult(json)
        case .refused: return .refused
        case .unreachable: return .unreachable
        }
    }

    static func applyResult(_ json: [String: Any]) -> ApplyResult {
        guard json["v"] as? Int == 1 else { return .refused }
        if let id = json["request"] as? String, !id.isEmpty { return .filed(request: id) }
        switch json["error"] as? String {
        case "place": return .wrongPlace
        case "code":
            // "With the tries left": the protocol doesn't name the field, so the likely names are read.
            let tries = ["tries", "triesLeft", "tries_left", "left", "remaining"].lazy.compactMap { json[$0] as? Int }.first
            return .wrongCode(triesLeft: tries)
        default: return .refused
        }
    }

    public func status(request id: String, sign: @Sendable (Data) throws -> Data) async -> StatusResult {
        guard isSecure else { return .refused }
        var components = URLComponents(url: Self.route(baseURL, "status"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "request", value: id)]
        guard let url = components?.url else { return .refused }
        let time = Int((now().timeIntervalSince1970 + offset.value).rounded(.down))
        guard let proof = try? sign(EnrollProof.statusMessage(request: id, time: time)) else { return .refused }
        var request = Self.request(url, timeout: Self.timeout)
        request.setValue(String(time), forHTTPHeaderField: Self.timeHeader)
        request.setValue(proof.base64EncodedString(), forHTTPHeaderField: Self.proofHeader)
        switch await send(request) {
        case .answer(let json):
            guard json["v"] as? Int == 1 else { return .refused }
            switch json["state"] as? String {
            case "pending": return .pending
            case "denied": return .denied
            case "approved": return Self.issued(json).map(StatusResult.approved) ?? .refused
            default: return .refused
            }
        case .refused: return .refused
        case .unreachable: return .unreachable
        }
    }

    public func renew(csr: Data) async -> RenewResult {
        var request = Self.request(Self.route(baseURL, "renew"), timeout: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["v": 1, "csr": csr.base64EncodedString()], options: [.sortedKeys]
        )
        switch await send(request) {
        case .answer(let json):
            guard json["v"] as? Int == 1, let issued = Self.issued(json) else { return .refused }
            return .renewed(issued)
        case .refused: return .refused
        case .unreachable: return .unreachable
        }
    }

    static func issued(_ json: [String: Any]) -> IssuedCertificate? {
        guard let certificate = (json["certificate"] as? String).flatMap({ Data(base64Encoded: $0) }), !certificate.isEmpty,
              certificate.count <= CertificateKey.maxSize,
              let renewAfter = json["renewAfter"] as? Double ?? (json["renewAfter"] as? Int).map(Double.init)
        else { return nil }
        // An issuer too large to be one is dropped (it goes into the settings), not the answer.
        let issuer = (json["issuer"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { $0.count <= CertificateKey.maxSize ? $0 : nil }
        return IssuedCertificate(certificate: certificate, issuer: issuer, renewAfter: renewAfter)
    }

    // MARK: Sending

    private enum Answer {
        case answer([String: Any])
        case refused
        case unreachable
    }

    private static func request(_ url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Enrolment goes only over https (C49): for a plain-http main address nothing is sent (the code, the
    /// request and the signed login would go out in clear), and the server is one that doesn't approve
    /// devices as far as the app is concerned. The app doesn't make a client for one either.
    var isSecure: Bool { baseURL.scheme?.lowercased() == "https" }

    /// The largest clock correction taken from a server's `Date` header (C49): the status proof only needs
    /// the phone's clock near the server's, and a larger one would let whoever answers choose the time
    /// the device signs for.
    static let maxClockCorrection: TimeInterval = 5 * 60

    /// The correction a `Date` header gives, or nil when it's larger than `maxClockCorrection` (ignored).
    static func clockCorrection(serverDate: Date, now: Date) -> TimeInterval? {
        let difference = serverDate.timeIntervalSince(now)
        return abs(difference) <= maxClockCorrection ? difference : nil
    }

    private func send(_ request: URLRequest) async -> Answer {
        guard isSecure, request.url?.scheme?.lowercased() == "https" else { return .refused }
        var request = request
        request.setValue(login, forHTTPHeaderField: Self.loginHeader)
        guard let current = session(), let (data, response) = try? await current.data(for: request),
              let http = response as? HTTPURLResponse else { return .unreachable }
        if let date = http.value(forHTTPHeaderField: "Date").flatMap(Self.httpDate),
           let correction = Self.clockCorrection(serverDate: date, now: now()) {
            offset.value = correction
        }
        switch http.statusCode {
        case 200:
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .refused }
            return .answer(json)
        case 429, 500...599: return .unreachable
        default: return .refused
        }
    }

    static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}

/// Presents the device's certificate where it has one (the signed-in profile's, or `login`'s own only where
/// it's given), and never follows a redirect.
final class EnrollSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let answer: DeviceChallengeAnswer

    init(certificates: DeviceCertificates, login: DeviceLogin?) {
        answer = DeviceChallengeAnswer(certificates: certificates, login: login)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await answer.urlSession(session, task: task, didReceive: challenge)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// The server's clock minus the phone's, shared by a client's copies.
final class ClockOffset: Sendable {
    private let stored = Mutex<TimeInterval>(0)
    var value: TimeInterval {
        get { stored.withLock { $0 } }
        set { stored.withLock { $0 = newValue } }
    }
}

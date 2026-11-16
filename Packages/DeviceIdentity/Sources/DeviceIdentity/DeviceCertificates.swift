import Foundation
import Security
import Synchronization

/// The one place every connection to the server asks for the device's certificate (C45): the API's
/// transport, the covers, the downloads, the server's own routes, the levels and the player. The app
/// names the signed-in profile and its **main** address (`use`); only a TLS connection to that host and
/// port is answered with the profile's identity, and only when that is the address the certificate was
/// issued for (its record's `origin`, C49), so the home-network address, other hosts, a profile edited to
/// another address and every server without a certificate here get exactly what they got before (the system's default, no
/// certificate). Nothing else stores the identity: it is read from the Keychain when first asked for and
/// kept in memory until `refresh()` or `use` changes it. A login being checked before it's signed in never
/// changes what these answer: its check goes over sessions of its own (`LoginSessions`), which answer with
/// that login's identity only (`DeviceLogin`).
public final class DeviceCertificates: Sendable {
    public static let shared = DeviceCertificates(store: KeychainDeviceKeys())

    struct Target: Hashable {
        let profile: UUID
        let host: String
        let port: Int
    }

    private struct IdentityBox: @unchecked Sendable {
        let identity: SecIdentity
        let issuer: SecCertificate?
    }

    private struct State: Sendable {
        /// The signed-in profile at its main address.
        var target: Target?
        /// Identities read so far (nil inside: none there).
        var cached: [Target: IdentityBox?] = [:]
    }

    private let store: any DeviceKeyStore
    private let records: DeviceRecords
    private let state = Mutex(State())
    /// What `resetConnections()` runs: each long-lived session's swap for a new one (`RenewableSession`).
    private let resets = Mutex<[@Sendable () -> Void]>([])
    /// What `refresh()` runs besides: the sessions that react to a certificate change only.
    private let certificateChanges = Mutex<[@Sendable () -> Void]>([])

    public init(store: any DeviceKeyStore, records: DeviceRecords = DeviceRecords()) {
        self.store = store
        self.records = records
    }

    /// `action` runs on every `resetConnections()`, so a session can drop the connections it keeps open.
    public func addConnectionReset(_ action: @escaping @Sendable () -> Void) {
        resets.withLock { $0.append(action) }
    }

    /// `action` runs on `refresh()` only (a certificate stored, renewed or removed), not on the other
    /// `resetConnections()` (a change of account, the revocation's re-check): for a session whose reset
    /// costs more than a new handshake, the background downloads one, whose running tasks it touches.
    public func addCertificateChange(_ action: @escaping @Sendable () -> Void) {
        certificateChanges.withLock { $0.append(action) }
    }

    /// Every session that registered drops its open connections: the next request makes a new one, with a
    /// new TLS handshake. A server asks for the certificate only in that handshake, so a connection opened
    /// before a certificate was stored goes on without it (and one opened before it was removed, with it).
    public func resetConnections() {
        for reset in resets.withLock({ $0 }) { reset() }
    }

    /// The profile signed in and its main address; nil for either: nothing is presented for it. A change
    /// drops the open connections (`resetConnections()`): one opened for the last profile presented its
    /// certificate, or none, and would go on doing so for the new one (the audit after C55, A1).
    public func use(profile: UUID?, server: URL?) {
        let target = profile.flatMap { id in server.flatMap { Self.target(id, $0) } }
        let changed = state.withLock { state in
            defer { state.target = target }
            return state.target != target
        }
        if changed { resetConnections() }
    }

    /// The certificate changed (stored, renewed, removed): it's read again when next asked for, and the
    /// sessions that keep connections open start new ones (`resetConnections()`, then each
    /// `addCertificateChange` action).
    public func refresh() {
        state.withLock { $0.cached.removeAll() }
        resetConnections()
        for change in certificateChanges.withLock({ $0 }) { change() }
    }

    /// Whether a connection to `url` is answered with a certificate (the player feeds itself then).
    public func presents(to url: URL) -> Bool {
        guard let host = url.host()?.lowercased(), url.scheme?.lowercased() == "https" else { return false }
        return identity(host: host, port: url.port ?? 443) != nil
    }

    /// The signed-in profile's credential for a client-certificate challenge from `host`:`port`, if this
    /// device has one there. By default never kept by the session (`.none`): every handshake asks again, so
    /// a change of profile or certificate is answered at once (A1). The background downloads session passes
    /// `.forSession`: the system runs its connections while the app is suspended (the review after C56).
    public func credential(host: String, port: Int, persistence: URLCredential.Persistence = .none) -> URLCredential? {
        identity(host: host.lowercased(), port: port).map { Self.credential($0, persistence: persistence) }
    }

    /// The credential one login presents to `host`:`port`: its own certificate where it holds one issued
    /// there, else none. Never another account's, whoever is signed in (the review after C56).
    public func credential(host: String, port: Int, for login: DeviceLogin) -> URLCredential? {
        identity(host: host.lowercased(), port: port, of: login.target).map { Self.credential($0, persistence: .none) }
    }

    /// How to answer any challenge a connection gets: a client-certificate one with the signed-in profile's
    /// identity where there is one, everything else (and a client-certificate one elsewhere) the system's
    /// default, as a session without a delegate does.
    public func answer(
        _ challenge: URLAuthenticationChallenge, persistence: URLCredential.Persistence = .none
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        Self.answer(challenge) { credential(host: $0, port: $1, persistence: persistence) }
    }

    /// `answer`, with `login`'s own identity only (a sign-in being checked, and its approval screens).
    public func answer(
        _ challenge: URLAuthenticationChallenge, for login: DeviceLogin
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        Self.answer(challenge) { credential(host: $0, port: $1, for: login) }
    }

    private static func answer(
        _ challenge: URLAuthenticationChallenge, credential: (String, Int) -> URLCredential?
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodClientCertificate,
              let credential = credential(space.host, space.port == 0 ? 443 : space.port) else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, credential)
    }

    private static func credential(_ box: IdentityBox, persistence: URLCredential.Persistence) -> URLCredential {
        URLCredential(identity: box.identity, certificates: box.issuer.map { [$0] }, persistence: persistence)
    }

    /// The signed-in profile's identity, for its own host and port only.
    private func identity(host: String, port: Int) -> IdentityBox? {
        identity(host: host, port: port, of: state.withLock { $0.target })
    }

    /// `target`'s identity, for its own host and port only.
    private func identity(host: String, port: Int, of target: Target?) -> IdentityBox? {
        guard let target, target.host == host, target.port == port else { return nil }
        return lookUp(target)
    }

    private func lookUp(_ target: Target) -> IdentityBox? {
        if let cached = state.withLock({ $0.cached[target] }) { return cached }
        // Only the address the certificate was issued for gets it (C49): a profile edited to another
        // address, or a login being checked there, presents nothing.
        let record = records.record(for: target.profile)
        let found = record.belongs(to: DeviceOrigin(host: target.host, port: target.port))
            ? store.identity(for: target.profile).map { identity in
                IdentityBox(identity: identity, issuer: record.issuer.flatMap { SecCertificateCreateWithData(nil, $0 as CFData) })
            }
            : nil
        state.withLock { $0.cached[target] = .some(found) }
        return found
    }

    static func target(_ profile: UUID, _ server: URL) -> Target? {
        guard let origin = DeviceOrigin(server) else { return nil }
        return Target(profile: profile, host: origin.host, port: origin.port)
    }
}

/// A long-lived `URLSession` that is replaced by a new one whenever `DeviceCertificates` resets connections
/// (a certificate stored, renewed or removed): the new session has no open connection and no TLS session to
/// resume, so its first request makes a full handshake, where the server asks for the certificate. The old
/// session finishes what it's running and is then let go.
public final class RenewableSession: Sendable {
    private let make: @Sendable () -> URLSession
    private let current: Mutex<URLSession>
    /// Set by `end()`: no new session, and none to send on.
    private let ended = Mutex(false)

    /// How long a replaced session is kept before it's invalidated: a request that read `session` just
    /// before the swap may still be starting its task on it, and a task started on an invalidated session
    /// throws.
    static let retireDelay: Duration = .seconds(60)

    public init(certificates: DeviceCertificates = .shared, make: @escaping @Sendable () -> URLSession) {
        self.make = make
        current = Mutex(make())
        certificates.addConnectionReset { [weak self] in self?.renew() }
    }

    /// The session to send the next request on.
    public var session: URLSession { current.withLock { $0 } }

    /// `session`, or nil once `end()` has run (a request then fails as one with no answer does).
    public var openSession: URLSession? { ended.withLock { $0 } ? nil : session }

    /// Whether `end()` has run.
    public var hasEnded: Bool { ended.withLock { $0 } }

    /// A new session from now on; the old one ends after `retireDelay`, its running tasks finished.
    /// Nothing once `end()` has run.
    public func renew() {
        guard !hasEnded else { return }
        let fresh = make()
        let old = current.withLock { session in
            let old = session
            session = fresh
            return old
        }
        Self.retire(old)
    }

    /// Done with: nothing is sent on it from now on (`openSession` is nil, `renew()` does nothing), and the
    /// session is invalidated after `retireDelay`, its running tasks finished. A second call does nothing.
    public func end() {
        let first = ended.withLock { ended in
            defer { ended = true }
            return !ended
        }
        if first { Self.retire(session) }
    }

    private static func retire(_ old: URLSession) {
        Task.detached {
            try? await Task.sleep(for: retireDelay)
            old.finishTasksAndInvalidate()
        }
    }
}

/// One login's own identity, whoever is signed in: its certificate at its main address where it holds one
/// issued there, else nothing. What a sign-in being checked presents, and the approval screens after it.
public struct DeviceLogin: Sendable, Hashable {
    let target: DeviceCertificates.Target?

    /// `server`: the login's main address.
    public init(profile: UUID, server: URL?) {
        target = server.flatMap { DeviceCertificates.target(profile, $0) }
    }
}

/// The sessions one sign-in check uses, and the approval screens that follow it (the review after C56):
/// they answer a certificate challenge with that login's own identity only (`DeviceLogin`), whoever is
/// signed in, so the shared sessions keep presenting the signed-in account's. Each check has its own: one
/// ending can't change what another presents. They're renewed when a certificate is stored, renewed or
/// removed, as the shared ones are, and `end()` lets them go when the check, or its screens, are done.
public final class LoginSessions: Sendable {
    public let login: DeviceLogin
    /// For the music server's API (`URLSessionTransport`), made as `URLSessionTransport.apiSessions` is.
    public let api: RenewableSession
    /// For the enrolment routes (`EnrollClient`), made as `EnrollClient.sessions` is.
    public let enrol: RenewableSession

    /// `server`: the login's main address.
    public init(certificates: DeviceCertificates = .shared, profile: UUID, server: URL?) {
        let login = DeviceLogin(profile: profile, server: server)
        self.login = login
        let answer = DeviceChallengeAnswer(certificates: certificates, login: login)
        api = RenewableSession(certificates: certificates) {
            URLSession(configuration: .ephemeral, delegate: answer, delegateQueue: nil)
        }
        enrol = RenewableSession(certificates: certificates) {
            EnrollClient.makeSession(certificates: certificates, login: login)
        }
    }

    /// New connections for the next requests, with a new TLS handshake (the revocation's confirmation).
    public func freshConnections() {
        api.renew()
        enrol.renew()
    }

    /// The check, or its screens, are done: nothing more is sent on these.
    public func end() {
        api.end()
        enrol.end()
    }

    public var hasEnded: Bool { api.hasEnded && enrol.hasEnded }
}

/// A session delegate that answers the server's request for a client certificate from
/// `DeviceCertificates` and does nothing else (redirects followed, the server's trust the system's): with
/// the signed-in profile's identity, or, where `login` is given, with that login's own only.
public final class DeviceChallengeAnswer: NSObject, URLSessionTaskDelegate, Sendable {
    public static let shared = DeviceChallengeAnswer()

    private let certificates: DeviceCertificates
    private let login: DeviceLogin?

    public init(certificates: DeviceCertificates = .shared, login: DeviceLogin? = nil) {
        self.certificates = certificates
        self.login = login
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if let login { return certificates.answer(challenge, for: login) }
        return certificates.answer(challenge)
    }
}

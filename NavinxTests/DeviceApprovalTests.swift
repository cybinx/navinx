import DeviceIdentity
import Foundation
import Security
import SubsonicKit
import Testing
@testable import Navinx

/// C45: when the sign-in asks a server whether it approves devices, and what follows, with fakes.

/// `ping` per host, switchable: up answers ok, down can't connect.
private final class SwitchTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var up: Set<String>
    init(up: Set<String>) { self.up = up }
    func setUp(_ host: String) { _ = lock.withLock { up.insert(host) } }
    func setDown(_ host: String) { _ = lock.withLock { up.remove(host) } }

    func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        guard lock.withLock({ up.contains(url.host() ?? "") }) else { throw URLError(.cannotConnectToHost) }
        let body = #"{"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.64.2"}}"#
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private final class ScriptedEnroll: EnrollAPI, @unchecked Sendable {
    let lock = NSLock()
    var hellos: [HelloResult]
    var applies: [ApplyResult] = []
    var statuses: [StatusResult] = []
    var helloCount = 0
    init(_ hellos: [HelloResult]) { self.hellos = hellos }

    func hello() async -> HelloResult {
        lock.withLock {
            helloCount += 1
            return hellos.count > 1 ? hellos.removeFirst() : (hellos.first ?? .notOffered)
        }
    }
    func apply(_ application: EnrollApplication) async -> ApplyResult { lock.withLock { applies.isEmpty ? .unreachable : applies.removeFirst() } }
    func status(request: String, sign: @Sendable (Data) throws -> Data) async -> StatusResult {
        _ = try? sign(Data("x".utf8))
        return lock.withLock { statuses.isEmpty ? .pending : statuses.removeFirst() }
    }
    func renew(csr: Data) async -> RenewResult { .unreachable }
}

private final class Keys: DeviceKeyStore, @unchecked Sendable {
    let lock = NSLock()
    var keys: [UUID: SoftwareDeviceKey] = [:]
    var certificates: [UUID: Data] = [:]
    func key(for profile: UUID) -> (any DeviceKey)? { lock.withLock { keys[profile] } }
    func makeKey(for profile: UUID) throws -> any DeviceKey {
        lock.withLock { let key = SoftwareDeviceKey(); keys[profile] = key; certificates[profile] = nil; return key }
    }
    func storeCertificate(_ certificate: Data, for profile: UUID) throws { lock.withLock { certificates[profile] = certificate } }
    func hasCertificate(for profile: UUID) -> Bool { lock.withLock { certificates[profile] != nil } }
    func identity(for profile: UUID) -> SecIdentity? { nil }
    func removeCertificate(for profile: UUID) { _ = lock.withLock { certificates.removeValue(forKey: profile) } }
    func remove(profile: UUID) { lock.withLock { keys[profile] = nil; certificates[profile] = nil } }
}

private let required = EnrollHello(devices: .required, approved: false, invited: true, to: "m•••@g•••.com")

@MainActor
private struct Setup {
    let model: AccountModel
    let store: ProfileStore
    let transport: SwitchTransport
    let api: ScriptedEnroll
    let keys = Keys()
    let records: DeviceRecords
    /// The addresses the routes were made for.
    let asked: Box

    final class Box { var addresses: [String] = [] }

    init(up: Set<String>, hellos: [HelloResult], store: ProfileStore? = nil) {
        let defaults = UserDefaults(suiteName: "DeviceApprovalTests.\(UUID().uuidString)")!
        records = DeviceRecords(defaults: defaults)
        self.store = store ?? ProfileStore(defaults: defaults, secrets: InMemorySecretStore())
        transport = SwitchTransport(up: up)
        let api = ScriptedEnroll(hellos)
        self.api = api
        let asked = Box()
        self.asked = asked
        let services = DeviceServices(
            api: { config in
                asked.addresses.append(config.normalizedURL)
                return api
            },
            keys: keys, records: records, certificates: nil,
            device: DeviceDescription(model: "iPhone18,1", system: "iOS 27.2", app: "1.0 (1)"), deviceName: "iPhone",
            attesting: nil
        )
        model = AccountModel(
            store: self.store, transport: transport, verifyAttempts: 1, verifyTimeout: .seconds(2),
            retryDelay: .milliseconds(1), devices: services
        )
    }
}

@MainActor
struct DeviceApprovalTests {
    /// A stock server (hello is its own 404): signed in as before, no screens.
    @Test func aServerThatDoesntApproveDevicesIsUntouched() async {
        let setup = Setup(up: ["music.example"], hellos: [.notOffered])
        let failure = await setup.model.login(serverURL: "https://music.example", username: "u", password: "p")
        #expect(failure == nil)
        #expect(setup.model.state == .authenticated)
        #expect(setup.model.approval == nil)
        #expect(setup.asked.addresses == ["https://music.example"])
    }

    /// Signed in at the home-network address: nothing is asked at all (5a).
    @Test func theHomeNetworkAddressIsNeverAsked() async {
        let setup = Setup(up: ["music.example", "lan.example"], hellos: [.answer(required)])
        let failure = await setup.model.login(
            serverURL: "https://music.example", homeNetworkURL: "http://lan.example", username: "u", password: "p"
        )
        #expect(failure == nil)
        #expect(setup.model.client?.baseURL.host() == "lan.example")
        #expect(setup.model.state == .authenticated)
        #expect(setup.asked.addresses.isEmpty)
        #expect(setup.api.helloCount == 0)
    }

    /// A server that lets in only approved devices: no answer to the ping, hello at the **main** address
    /// (never the home-network one), the code, the words, approval, then the sign-in again, as the same
    /// profile.
    @Test func requiredCodeWaitingApprovedThenSignedIn() async throws {
        let setup = Setup(up: [], hellos: [.answer(required), .notOffered])
        setup.api.applies = [.filed(request: "r1")]
        setup.api.statuses = [.pending]
        let failure = await setup.model.login(
            serverURL: "https://music.example", homeNetworkURL: "http://lan.example", username: "u", password: "p"
        )
        #expect(failure == nil)
        #expect(setup.asked.addresses.allSatisfy { $0 == "https://music.example" })
        #expect(!setup.asked.addresses.isEmpty)
        let flow = try #require(setup.model.approval)
        #expect(flow.step == .enterCode(sentTo: "m•••@g•••.com"))
        #expect(flow.rule == .required)
        #expect(setup.model.state == .unauthenticated)

        flow.code = "ABCD2345"
        await flow.send()
        let key = try #require(setup.keys.key(for: flow.profile))
        #expect(flow.step == .waiting(words: key.words))
        // Kept as a saved login while it waits, so the request is found after the app closes.
        #expect(setup.store.savedProfiles.map(\.id) == [flow.profile])
        #expect(setup.records.record(for: flow.profile).origin == "https://music.example:443")

        setup.api.statuses = [.approved(IssuedCertificate(certificate: try SelfSigned.certificate(for: key), issuer: nil, renewAfter: 4_000_000_000))]
        setup.transport.setUp("music.example")
        await flow.poll()
        for _ in 0..<50 where setup.model.state != .authenticated { try await Task.sleep(for: .milliseconds(20)) }
        #expect(setup.model.state == .authenticated)
        #expect(setup.model.approval == nil)
        #expect(setup.model.active?.id == flow.profile)
        #expect(setup.keys.hasCertificate(for: flow.profile))
    }

    /// `optional`: the app works without a certificate, so the screens show with Not Now, which signs in.
    @Test func optionalCanBeSkipped() async throws {
        var optional = required
        optional.devices = .optional
        let setup = Setup(up: ["music.example"], hellos: [.answer(optional)])
        let failure = await setup.model.login(serverURL: "https://music.example", username: "u", password: "p")
        #expect(failure == nil)
        let flow = try #require(setup.model.approval)
        #expect(flow.rule == .optional)
        #expect(setup.model.state == .unauthenticated)
        await setup.model.skipApproval()
        #expect(setup.model.approval == nil)
        #expect(setup.model.state == .authenticated)
    }

    @Test func cancelKeepsTheLoginScreenAndTheRequest() async throws {
        let setup = Setup(up: [], hellos: [.answer(required)])
        setup.api.applies = [.filed(request: "r1")]
        _ = await setup.model.login(serverURL: "https://music.example", username: "u", password: "p")
        let flow = try #require(setup.model.approval)
        flow.code = "ABCD2345"
        await flow.send()
        setup.model.cancelApproval()
        #expect(setup.model.approval == nil)
        #expect(setup.model.state == .unauthenticated)

        // Back again (a chip, the same login): the waiting screen, with the same request.
        _ = await setup.model.login(serverURL: "https://music.example", username: "u", password: "p")
        let again = try #require(setup.model.approval)
        #expect(again.profile == flow.profile)
        if case .waiting = again.step {} else { Issue.record("not waiting: \(again.step)") }
    }

    /// A known server that stops answering a device it had approved: back to the login screen, saying so.
    @Test func aRevokedDeviceReturnsToTheLoginScreen() async throws {
        let store = ProfileStore(defaults: UserDefaults(suiteName: "DeviceApprovalTests.\(UUID().uuidString)")!, secrets: InMemorySecretStore())
        let profile = store.save(ServerProfile(serverURL: "https://music.example", username: "u"), password: "p")
        store.setActive(profile, password: "p")
        var revoked = required
        revoked.invited = false
        let setup = Setup(up: [], hellos: [.answer(revoked)], store: store)
        _ = try setup.keys.makeKey(for: profile.id)
        try setup.keys.storeCertificate(Data([1]), for: profile.id)
        await setup.model.start()
        #expect(setup.model.state == .error)
        #expect(setup.model.error == AccountModel.deviceRevokedMessage)
        #expect(setup.model.approval == nil)
        #expect(setup.keys.key(for: profile.id) == nil)
        #expect(setup.model.prefill?.id == profile.id)
        // Removed only once a second hello, on a new connection, said so too (the re-check, item 1).
        #expect(setup.api.helloCount == 2)
    }

    // MARK: The re-check, item 1

    /// At launch, the server doesn't answer and the first hello says "not approved" (a connection from
    /// before the certificate): the new connection says approved, so the certificate stays.
    @Test func aStaleRefusalAtLaunchKeepsTheCertificate() async throws {
        var stale = required
        stale.invited = false
        let approved = EnrollHello(devices: .required, approved: true, invited: false)
        let (setup, profile, certificate) = try approvedProfile(up: [], hellos: [.answer(stale), .answer(approved)])
        await setup.model.start()
        #expect(setup.api.helloCount == 2)
        #expect(setup.keys.certificates[profile.id] == certificate)
        #expect(setup.model.state == .serverUnreachable)
        #expect(setup.model.error != AccountModel.deviceRevokedMessage)
    }

    /// The confirmation finds no server: nothing is deleted.
    @Test func anUnansweredConfirmationKeepsTheCertificate() async throws {
        var stale = required
        stale.invited = false
        let (setup, profile, certificate) = try approvedProfile(up: [], hellos: [.answer(stale), .unreachable])
        await setup.model.start()
        #expect(setup.keys.certificates[profile.id] == certificate)
        #expect(setup.model.state == .serverUnreachable)
    }

    /// A sign-in from the form: "not approved" on the old connection, approved on the new one: signed in,
    /// the certificate kept, no screens.
    @Test func aStaleRefusalAtSignInKeepsTheCertificate() async throws {
        let approved = EnrollHello(devices: .required, approved: true, invited: false)
        let (setup, profile, certificate) = try approvedProfile(up: ["music.example"], hellos: [.answer(required), .answer(approved)])
        let failure = await setup.model.login(serverURL: "https://music.example", username: "u", password: "p")
        #expect(failure == nil)
        #expect(setup.model.state == .authenticated)
        #expect(setup.model.active?.id == profile.id)
        #expect(setup.model.approval == nil)
        #expect(setup.keys.certificates[profile.id] == certificate)
    }

    /// A known server that stops answering and approves devices, with none here: its screens, over the
    /// unreachable screen.
    @Test func aKnownServerAskingForApprovalShowsTheScreens() async throws {
        let store = ProfileStore(defaults: UserDefaults(suiteName: "DeviceApprovalTests.\(UUID().uuidString)")!, secrets: InMemorySecretStore())
        let profile = store.save(ServerProfile(serverURL: "https://music.example", username: "u"), password: "p")
        store.setActive(profile, password: "p")
        let setup = Setup(up: [], hellos: [.answer(required)], store: store)
        await setup.model.start()
        #expect(setup.model.state == .serverUnreachable)
        #expect(setup.model.approval?.profile == profile.id)
    }

    /// A server that's simply down (hello unanswered, or approved already): the unreachable screen as before.
    @Test func aServerThatIsJustDownIsUnreachableAsBefore() async {
        let store = ProfileStore(defaults: UserDefaults(suiteName: "DeviceApprovalTests.\(UUID().uuidString)")!, secrets: InMemorySecretStore())
        let profile = store.save(ServerProfile(serverURL: "https://music.example", username: "u"), password: "p")
        store.setActive(profile, password: "p")
        let setup = Setup(up: [], hellos: [.unreachable], store: store)
        await setup.model.start()
        #expect(setup.model.state == .serverUnreachable)
        #expect(setup.model.approval == nil)
    }

    // MARK: C49

    /// A plain-http main address is never asked, whatever it would answer: signed in as before.
    @Test func aPlainHTTPAddressIsNeverAsked() async {
        let setup = Setup(up: ["music.example"], hellos: [.answer(required)])
        let failure = await setup.model.login(serverURL: "http://music.example", username: "u", password: "p")
        #expect(failure == nil)
        #expect(setup.model.state == .authenticated)
        #expect(setup.model.approval == nil)
        #expect(setup.asked.addresses.isEmpty)
        #expect(setup.api.helloCount == 0)
    }

    /// A plain-http server that doesn't answer is unreachable as before: no screens, no key.
    @Test func aPlainHTTPAddressThatDoesntAnswerShowsNoScreens() async {
        let setup = Setup(up: [], hellos: [.answer(required)])
        let failure = await setup.model.login(serverURL: "http://music.example", username: "u", password: "p")
        #expect(failure != nil)
        #expect(setup.model.approval == nil)
        #expect(setup.api.helloCount == 0)
        #expect(setup.keys.keys.isEmpty)
    }

    /// An approved profile, saved and signed in at `https://music.example`.
    private func approvedProfile(up: Set<String>, hellos: [HelloResult]) throws -> (Setup, ServerProfile, Data) {
        let store = ProfileStore(defaults: UserDefaults(suiteName: "DeviceApprovalTests.\(UUID().uuidString)")!, secrets: InMemorySecretStore())
        let profile = store.save(ServerProfile(serverURL: "https://music.example", username: "u"), password: "p")
        store.setActive(profile, password: "p")
        let setup = Setup(up: up, hellos: hellos, store: store)
        let key = try setup.keys.makeKey(for: profile.id)
        let certificate = try SelfSigned.certificate(for: key)
        try setup.keys.storeCertificate(certificate, for: profile.id)
        setup.records.set(DeviceRecords.Record(renewAfter: 4_000_000_000, origin: "https://music.example:443"), for: profile.id)
        return (setup, profile, certificate)
    }

    /// Edit Server to another address that doesn't answer and says "not approved": nothing is asked
    /// there and nothing goes; the edit fails as an unreachable server does.
    @Test func anEditToAnotherAddressCantRemoveTheApproval() async throws {
        let (setup, profile, certificate) = try approvedProfile(up: ["music.example"], hellos: [.answer(required)])
        await setup.model.start()
        #expect(setup.model.state == .authenticated)
        let failure = await setup.model.login(serverURL: "https://other.example", username: "u", password: "p", replacing: profile)
        #expect(failure != nil)
        #expect(setup.api.helloCount == 0)
        #expect(setup.model.approval == nil)
        #expect(setup.keys.key(for: profile.id) != nil)
        #expect(setup.keys.certificates[profile.id] == certificate)
        #expect(setup.records.record(for: profile.id).origin == "https://music.example:443")
        #expect(setup.model.active?.serverURL == "https://music.example")
    }

    /// Edit Server to another address that answers: saved, and only then the old address's approval goes.
    @Test func aSavedEditToAnotherAddressDropsTheOldApproval() async throws {
        let (setup, profile, _) = try approvedProfile(up: ["music.example", "other.example"], hellos: [.notOffered])
        await setup.model.start()
        let failure = await setup.model.login(serverURL: "https://other.example", username: "u", password: "p", replacing: profile)
        #expect(failure == nil)
        #expect(setup.model.active?.id == profile.id)
        #expect(setup.model.active?.serverURL == "https://other.example")
        #expect(setup.keys.key(for: profile.id) == nil)
        #expect(!setup.keys.hasCertificate(for: profile.id))
        #expect(setup.records.record(for: profile.id) == DeviceRecords.Record())
        // Asked at the new address once saved, as after any sign-in; this one doesn't approve devices.
        #expect(setup.asked.addresses == ["https://other.example"])
        #expect(setup.model.approval == nil)
    }

    // MARK: The audit after C55, A5

    /// Edit Server to another username whose check fails, at a server that says "not approved": nothing is
    /// asked and nothing goes; the edit fails as an unreachable server does.
    @Test func anEditToAnotherUsernameThatFailsCantRemoveTheApproval() async throws {
        var revoked = required
        revoked.invited = false
        let (setup, profile, certificate) = try approvedProfile(up: ["music.example"], hellos: [.answer(revoked)])
        await setup.model.start()
        #expect(setup.model.state == .authenticated)
        setup.transport.setDown("music.example")
        let failure = await setup.model.login(serverURL: "https://music.example", username: "v", password: "p", replacing: profile)
        #expect(failure != nil)
        #expect(setup.api.helloCount == 0)
        #expect(setup.model.approval == nil)
        #expect(setup.keys.certificates[profile.id] == certificate)
        #expect(setup.model.active?.username == "u")
    }

    /// Edit Server to another username that answers: saved first, and only then asked, so the approval
    /// screens that follow come after the edit, not instead of it; a stale "not approved" keeps the certificate.
    @Test func anEditToAnotherUsernameIsSavedBeforeItsHello() async throws {
        var revoked = required
        revoked.invited = false
        let approved = EnrollHello(devices: .required, approved: true, invited: false)
        let (setup, profile, certificate) = try approvedProfile(up: ["music.example"], hellos: [.answer(revoked), .answer(approved)])
        await setup.model.start()
        let failure = await setup.model.login(serverURL: "https://music.example", username: "v", password: "p", replacing: profile)
        #expect(failure == nil)
        #expect(setup.api.helloCount == 2)
        #expect(setup.model.active?.id == profile.id && setup.model.active?.username == "v")
        #expect(setup.store.savedProfiles.first { $0.id == profile.id }?.username == "v")
        #expect(setup.keys.certificates[profile.id] == certificate)
        #expect(setup.model.approval == nil)
    }

    /// "Not approved" twice for the new username: the approval goes, but the edit is saved and signed in
    /// already, so cancelling the screens can't leave the old account without it.
    @Test func aRefusedNewUsernameShowsTheScreensAfterTheEdit() async throws {
        var revoked = required
        revoked.invited = false
        let (setup, profile, _) = try approvedProfile(up: ["music.example"], hellos: [.answer(revoked)])
        await setup.model.start()
        let failure = await setup.model.login(serverURL: "https://music.example", username: "v", password: "p", replacing: profile)
        #expect(failure == nil)
        #expect(setup.model.approval?.profile == profile.id)
        #expect(setup.model.state == .authenticated)
        #expect(setup.model.active?.username == "v")
        setup.model.cancelApproval()
        #expect(setup.model.active?.username == "v")
    }

    /// A record kept before C49 has no address: it's taken to be for the profile's main address.
    @Test func aRecordFromBeforeIsForTheSavedAddress() async throws {
        let (setup, profile, _) = try approvedProfile(up: ["music.example"], hellos: [.notOffered])
        setup.records.set(DeviceRecords.Record(renewAfter: 4_000_000_000), for: profile.id)
        await setup.model.start()
        #expect(setup.model.state == .authenticated)
        #expect(setup.records.record(for: profile.id) == DeviceRecords.Record(renewAfter: 4_000_000_000, origin: "https://music.example:443"))
        #expect(setup.keys.hasCertificate(for: profile.id))
    }
}

/// `hello` that holds its first call until `release()`, and notes which check's sessions each call went over.
private final class GatedEnroll: EnrollAPI, @unchecked Sendable {
    struct Call {
        let login: DeviceLogin?
        let ended: Bool
    }

    private let lock = NSLock()
    private var held: CheckedContinuation<Void, Never>?
    private var holdNext = true
    private var made: [Call] = []
    var calls: [Call] { lock.withLock { made } }
    var isHolding: Bool { lock.withLock { held != nil } }

    func release() { lock.withLock { held }?.resume() }

    func hello(over sessions: LoginSessions?) async -> HelloResult {
        let hold = lock.withLock {
            made.append(Call(login: sessions?.login, ended: sessions?.hasEnded ?? false))
            defer { holdNext = false }
            return holdNext
        }
        if hold { await withCheckedContinuation { continuation in lock.withLock { held = continuation } } }
        return .answer(required)
    }

    func hello() async -> HelloResult { await hello(over: nil) }
    func apply(_ application: EnrollApplication) async -> ApplyResult { .unreachable }
    func status(request: String, sign: @Sendable (Data) throws -> Data) async -> StatusResult { .unreachable }
    func renew(csr: Data) async -> RenewResult { .unreachable }
    func using(_ sessions: LoginSessions) -> any EnrollAPI { Over(base: self, sessions: sessions) }

    struct Over: EnrollAPI {
        let base: GatedEnroll
        let sessions: LoginSessions
        func hello() async -> HelloResult { await base.hello(over: sessions) }
        func apply(_ application: EnrollApplication) async -> ApplyResult { .unreachable }
        func status(request: String, sign: @Sendable (Data) throws -> Data) async -> StatusResult { .unreachable }
        func renew(csr: Data) async -> RenewResult { .unreachable }
    }
}

/// The review after C56: each sign-in check goes over its own sessions, so one overtaken by a newer one can't
/// change what the newer one, or its approval screens, present.
@MainActor
struct LoginCheckSessionTests {
    @Test func anOvertakenSignInCantChangeTheNewerChecksSessions() async throws {
        let defaults = UserDefaults(suiteName: "LoginCheckSessionTests.\(UUID().uuidString)")!
        let keys = Keys()
        let records = DeviceRecords(defaults: defaults)
        let api = GatedEnroll()
        let services = DeviceServices(
            api: { _ in api }, keys: keys, records: records,
            certificates: DeviceCertificates(store: keys, records: records),
            device: DeviceDescription(model: "iPhone18,1", system: "iOS 27.2", app: "1.0 (1)"), deviceName: "iPhone",
            attesting: nil
        )
        let model = AccountModel(
            store: ProfileStore(defaults: defaults, secrets: InMemorySecretStore()),
            transport: SwitchTransport(up: ["music.example"]), verifyAttempts: 1, verifyTimeout: .seconds(2),
            retryDelay: .milliseconds(1), devices: services
        )

        // The first sign-in waits on its hello; a second account on the same server signs in meanwhile.
        let older = Task { await model.signIn(serverURL: "https://music.example", username: "a", password: "p") }
        for _ in 0..<200 where !api.isHolding { try await Task.sleep(for: .milliseconds(10)) }
        #expect(api.isHolding)
        #expect(await model.signIn(serverURL: "https://music.example", username: "b", password: "p") == .done)
        let flow = try #require(model.approval)

        // The overtaken one ends (its own sessions only).
        api.release()
        #expect(await older.value == .superseded)
        #expect(model.approval === flow)

        // The newer one's screens still ask over its own sessions, open, for its own login.
        await flow.checkAgain()
        let calls = api.calls
        try #require(calls.count == 3)
        let newer = DeviceLogin(profile: flow.profile, server: URL(string: "https://music.example"))
        #expect(calls[0].login != nil && calls[0].login != newer)
        #expect(calls[1].login == newer && !calls[1].ended)
        #expect(calls[2].login == newer && !calls[2].ended)

        // Closed, the screens' sessions go.
        model.cancelApproval()
        await flow.checkAgain()
        #expect(api.calls.last?.login == newer && api.calls.last?.ended == true)
    }
}

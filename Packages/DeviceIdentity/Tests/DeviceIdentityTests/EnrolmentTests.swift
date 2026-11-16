import Foundation
import Security
import Synchronization
import Testing
@testable import DeviceIdentity

/// Keys and certificates in memory (the Keychain needs the app's entitlements, so the real store is
/// tested in the app's own tests).
final class MemoryKeys: DeviceKeyStore, @unchecked Sendable {
    let lock = NSLock()
    var keys: [UUID: SoftwareDeviceKey] = [:]
    var certificates: [UUID: Data] = [:]
    var made = 0

    func key(for profile: UUID) -> (any DeviceKey)? { lock.withLock { keys[profile] } }
    func makeKey(for profile: UUID) throws -> any DeviceKey {
        lock.withLock {
            made += 1
            let key = SoftwareDeviceKey()
            keys[profile] = key
            certificates[profile] = nil
            return key
        }
    }
    func storeCertificate(_ certificate: Data, for profile: UUID) throws { lock.withLock { certificates[profile] = certificate } }
    func hasCertificate(for profile: UUID) -> Bool { lock.withLock { certificates[profile] != nil } }
    func identity(for profile: UUID) -> SecIdentity? { nil }
    func removeCertificate(for profile: UUID) { lock.withLock { certificates[profile] = nil } }
    func remove(profile: UUID) { lock.withLock { keys[profile] = nil; certificates[profile] = nil } }
}

/// The add-on's enrolment routes, scripted.
final class FakeEnroll: EnrollAPI, @unchecked Sendable {
    let lock = NSLock()
    var hellos: [HelloResult]
    var applies: [ApplyResult]
    var statuses: [StatusResult]
    var renewals: [RenewResult] = []
    var applied: [EnrollApplication] = []
    var statusAsked: [(String, Data)] = []

    init(hellos: [HelloResult] = [], applies: [ApplyResult] = [], statuses: [StatusResult] = []) {
        self.hellos = hellos
        self.applies = applies
        self.statuses = statuses
    }

    func hello() async -> HelloResult { lock.withLock { hellos.isEmpty ? .unreachable : hellos.removeFirst() } }
    func apply(_ application: EnrollApplication) async -> ApplyResult {
        lock.withLock {
            applied.append(application)
            return applies.isEmpty ? .unreachable : applies.removeFirst()
        }
    }
    func status(request: String, sign: @Sendable (Data) throws -> Data) async -> StatusResult {
        let signature = (try? sign(EnrollProof.statusMessage(request: request, time: 0))) ?? Data()
        return lock.withLock {
            statusAsked.append((request, signature))
            return statuses.isEmpty ? .pending : statuses.removeFirst()
        }
    }
    func renew(csr: Data) async -> RenewResult { lock.withLock { renewals.isEmpty ? .unreachable : renewals.removeFirst() } }
}

struct FixedAttest: EnrolmentAttesting {
    func attest(clientDataHash: Data) async -> (keyID: String, attestation: Data)? { ("a2V5", clientDataHash) }
}

let invited = EnrollHello(devices: .required, approved: false, invited: true, to: "m•••@g•••.com")
let notInvited = EnrollHello(devices: .required, approved: false, invited: false)
let musicOrigin = DeviceOrigin(host: "music.example", port: 443)
let otherOrigin = DeviceOrigin(host: "other.example", port: 443)

@MainActor
func makeFlow(
    _ api: FakeEnroll, hello: EnrollHello = invited, keys: MemoryKeys = MemoryKeys(),
    records: DeviceRecords = DeviceRecords(defaults: UserDefaults(suiteName: UUID().uuidString)!),
    profile: UUID = UUID(), origin: DeviceOrigin = musicOrigin, attesting: (any EnrolmentAttesting)? = nil
) -> DeviceEnrolment {
    DeviceEnrolment(
        profile: profile, origin: origin, username: "Demo", hello: hello, api: api, keys: keys, records: records, certificates: nil,
        device: DeviceDescription(model: "iPhone18,1", system: "iOS 27.2", app: "1.0 (1)"), deviceName: "iPhone",
        attesting: attesting
    )
}

@MainActor
struct EnrolmentTests {
    @Test func noInviteThenOneArrives() async {
        let api = FakeEnroll(hellos: [.answer(invited)])
        let flow = makeFlow(api, hello: notInvited)
        #expect(flow.step == .noInvite)
        await flow.checkAgain()
        #expect(flow.step == .enterCode(sentTo: "m•••@g•••.com"))
    }

    @Test func checkingAgainWithTheServerOutOfReach() async {
        let flow = makeFlow(FakeEnroll(hellos: [.unreachable]), hello: notInvited)
        await flow.checkAgain()
        #expect(flow.step == .unreachable)
    }

    @Test func theCodeIsSentWithTheDeviceAndAKeyMadeHere() async throws {
        let keys = MemoryKeys()
        let records = DeviceRecords(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let profile = UUID()
        let api = FakeEnroll(applies: [.filed(request: "req-1")], statuses: [.pending])
        let flow = makeFlow(api, keys: keys, records: records, profile: profile)
        flow.code = "abcd-2345"
        #expect(flow.canSend)
        await flow.send()
        let sent = try #require(api.applied.first)
        #expect(sent.code == "ABCD2345")
        #expect(sent.name == "iPhone")
        #expect(sent.model == "iPhone18,1")
        #expect(sent.deviceID == records.installID)
        #expect(sent.attestKey == nil && sent.attestation == nil)
        let key = try #require(keys.key(for: profile))
        #expect(CertificateRequest.isSigned(sent.csr, point: key.point))
        #expect(flow.step == .waiting(words: key.words))
        #expect(key.words.count == 4)
        #expect(records.record(for: profile).request == "req-1")
        // The status asks are signed by the pending key.
        let (request, signature) = try #require(api.statusAsked.first)
        #expect(request == "req-1")
        let soft = try #require(key as? SoftwareDeviceKey)
        #expect(soft.privateKey.publicKey.isValidSignature(
            try .init(derRepresentation: signature), for: EnrollProof.statusMessage(request: "req-1", time: 0)
        ))
    }

    @Test func attestationGoesWhenTheAddOnAsks() async throws {
        var hello = invited
        hello.attest = .optional
        let api = FakeEnroll(applies: [.filed(request: "r")])
        let keys = MemoryKeys()
        let profile = UUID()
        let flow = makeFlow(api, hello: hello, keys: keys, profile: profile, attesting: FixedAttest())
        flow.code = "ABCD2345"
        await flow.send()
        let sent = try #require(api.applied.first)
        let key = try #require(keys.key(for: profile))
        #expect(sent.attestKey == "a2V5")
        #expect(sent.attestation == EnrollProof.attestClientDataHash(code: "ABCD2345", username: "Demo", subjectPublicKeyInfo: key.subjectPublicKeyInfo))
    }

    @Test func aWrongCodeSaysTheTriesLeftAndKeepsTheKey() async {
        let keys = MemoryKeys()
        let api = FakeEnroll(applies: [.wrongCode(triesLeft: 3), .filed(request: "r")])
        let flow = makeFlow(api, keys: keys)
        flow.code = "AAAA2222"
        await flow.send()
        #expect(flow.step == .enterCode(sentTo: "m•••@g•••.com"))
        #expect(flow.notice == .wrongCode(triesLeft: 3))
        flow.code = "ABCD2345"
        await flow.send()
        #expect(keys.made == 1)
        if case .waiting = flow.step {} else { Issue.record("not waiting: \(flow.step)") }
    }

    @Test func theLastWrongCodeEndsTheInvite() async {
        let flow = makeFlow(FakeEnroll(applies: [.wrongCode(triesLeft: 0)]))
        flow.code = "AAAA2222"
        await flow.send()
        #expect(flow.step == .expired)
    }

    @Test func anExpiredInviteWithNoCountIsToldApart() async {
        let flow = makeFlow(FakeEnroll(hellos: [.answer(notInvited)], applies: [.wrongCode(triesLeft: nil)]))
        flow.code = "AAAA2222"
        await flow.send()
        #expect(flow.step == .expired)
    }

    @Test func theWrongPlace() async {
        let flow = makeFlow(FakeEnroll(applies: [.wrongPlace]))
        flow.code = "AAAA2222"
        await flow.send()
        #expect(flow.notice == .wrongPlace)
        #expect(flow.step == .enterCode(sentTo: "m•••@g•••.com"))
    }

    @Test func sendingWithTheServerOutOfReach() async {
        let flow = makeFlow(FakeEnroll(applies: [.unreachable]))
        flow.code = "AAAA2222"
        await flow.send()
        #expect(flow.notice == .unreachable)
    }

    @Test func approvedStoresTheCertificateOnce() async throws {
        let keys = MemoryKeys()
        let records = DeviceRecords(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let profile = UUID()
        let api = FakeEnroll(applies: [.filed(request: "r")], statuses: [.pending])
        let flow = makeFlow(api, keys: keys, records: records, profile: profile)
        var approvals = 0
        flow.onApproved = { approvals += 1 }
        flow.code = "ABCD2345"
        await flow.send()
        if case .waiting = flow.step {} else { Issue.record("not waiting") }
        // The request is recorded for the address it was filed at (C49).
        #expect(records.record(for: profile) == DeviceRecords.Record(request: "r", origin: "https://music.example:443"))
        let issued = try TestCertificate.issued(for: try #require(keys.key(for: profile)))
        api.statuses = [.approved(issued)]
        await flow.poll()
        #expect(flow.step == .approved)
        #expect(approvals == 1)
        #expect(keys.certificates[profile] == issued.certificate)
        #expect(records.record(for: profile) == DeviceRecords.Record(renewAfter: 1_800_000_000, issuer: Data([4]), origin: "https://music.example:443"))
    }

    /// C49: a certificate that isn't for this device's key is not kept; the request counts as failed.
    @Test func aCertificateForAnotherKeyIsRefused() async throws {
        let keys = MemoryKeys()
        let records = DeviceRecords(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let profile = UUID()
        let api = FakeEnroll(hellos: [.answer(invited)], applies: [.filed(request: "r")], statuses: [.pending])
        let flow = makeFlow(api, keys: keys, records: records, profile: profile)
        flow.code = "ABCD2345"
        await flow.send()
        let key = try #require(keys.key(for: profile))
        api.statuses = [.approved(try TestCertificate.issued(for: SoftwareDeviceKey()))]
        await flow.poll()
        #expect(keys.certificates[profile] == nil)
        #expect(records.record(for: profile).request == nil)
        #expect(flow.step == .enterCode(sentTo: "m•••@g•••.com"))
        #expect(flow.notice == .notAccepted)
        // The key stays, and is used again for the next code.
        #expect(keys.key(for: profile)?.point == key.point)
    }

    /// C49: a profile whose certificate or request is for another address: a flow here neither waits on
    /// that request nor replaces the key.
    @Test func anApprovalForAnotherAddressIsLeftAlone() async throws {
        let keys = MemoryKeys()
        let records = DeviceRecords(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let profile = UUID()
        let key = try keys.makeKey(for: profile)
        try keys.storeCertificate(try TestCertificate.make(for: key), for: profile)
        records.set(DeviceRecords.Record(request: "theirs", renewAfter: 1000, origin: otherOrigin.text), for: profile)
        let api = FakeEnroll(applies: [.filed(request: "r")])
        let flow = makeFlow(api, keys: keys, records: records, profile: profile)
        #expect(flow.step == .enterCode(sentTo: "m•••@g•••.com"))
        flow.code = "ABCD2345"
        await flow.send()
        #expect(api.applied.isEmpty)
        #expect(flow.notice == .notAccepted)
        #expect(keys.made == 1)
        #expect(keys.key(for: profile)?.point == key.point)
        #expect(keys.hasCertificate(for: profile))
        #expect(records.record(for: profile).request == "theirs")
    }

    @Test func deniedForgetsTheKeyAndRequest() async {
        let keys = MemoryKeys()
        let records = DeviceRecords(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let profile = UUID()
        let flow = makeFlow(FakeEnroll(applies: [.filed(request: "r")], statuses: [.denied]), keys: keys, records: records, profile: profile)
        flow.code = "ABCD2345"
        await flow.send()
        #expect(flow.step == .denied)
        #expect(keys.key(for: profile) == nil)
        #expect(records.record(for: profile).request == nil)
    }

    /// Leaving the waiting screen keeps the request: a new flow for the profile goes straight back to
    /// waiting with the same words, and asks again.
    @Test func comingBackToTheWaitingScreen() async throws {
        let keys = MemoryKeys()
        let records = DeviceRecords(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let profile = UUID()
        let first = makeFlow(FakeEnroll(applies: [.filed(request: "r")], statuses: [.pending]), keys: keys, records: records, profile: profile)
        first.code = "ABCD2345"
        await first.send()
        let key = try #require(keys.key(for: profile))
        let words = key.words
        let api = FakeEnroll(statuses: [.approved(try TestCertificate.issued(for: key))])
        let again = makeFlow(api, hello: notInvited, keys: keys, records: records, profile: profile)
        #expect(again.step == .waiting(words: words))
        await again.poll()
        #expect(again.step == .approved)
        #expect(api.statusAsked.first?.0 == "r")
    }

    @Test func aRequestTheAddOnForgotStartsAgainFromTheInvite() async {
        let keys = MemoryKeys()
        let records = DeviceRecords(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let profile = UUID()
        _ = try? keys.makeKey(for: profile)
        records.set(DeviceRecords.Record(request: "gone", origin: musicOrigin.text), for: profile)
        let flow = makeFlow(FakeEnroll(hellos: [.answer(invited)], statuses: [.refused]), hello: notInvited, keys: keys, records: records, profile: profile)
        await flow.poll()
        #expect(flow.step == .enterCode(sentTo: "m•••@g•••.com"))
        #expect(records.record(for: profile).request == nil)
    }

    @Test func renewalWhenDueOnly() async throws {
        let keys = MemoryKeys()
        let records = DeviceRecords(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let profile = UUID()
        let key = try keys.makeKey(for: profile)
        try keys.storeCertificate(try TestCertificate.make(for: key), for: profile)
        records.set(DeviceRecords.Record(renewAfter: 1000, issuer: Data([4]), origin: musicOrigin.text), for: profile)
        let renewed = try TestCertificate.make(for: key, serial: 2)
        let api = FakeEnroll()
        api.renewals = [.renewed(IssuedCertificate(certificate: renewed, issuer: nil, renewAfter: 5000))]
        #expect(!(await DeviceRenewal.renewIfDue(profile: profile, origin: musicOrigin, api: api, keys: keys, records: records, certificates: nil, now: Date(timeIntervalSince1970: 999))))
        #expect(await DeviceRenewal.renewIfDue(profile: profile, origin: musicOrigin, api: api, keys: keys, records: records, certificates: nil, now: Date(timeIntervalSince1970: 1000)))
        #expect(keys.certificates[profile] == renewed)
        #expect(records.record(for: profile) == DeviceRecords.Record(renewAfter: 5000, issuer: Data([4]), origin: musicOrigin.text))
    }

    /// C49: a renewal answered with a certificate for another key keeps the current one, and a renewal is
    /// never asked of an address the certificate wasn't issued for.
    @Test func renewalKeepsTheCertificateUnlessTheNewOneIsForThisKey() async throws {
        let keys = MemoryKeys()
        let records = DeviceRecords(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let profile = UUID()
        let key = try keys.makeKey(for: profile)
        let current = try TestCertificate.make(for: key)
        try keys.storeCertificate(current, for: profile)
        let record = DeviceRecords.Record(renewAfter: 1000, issuer: Data([4]), origin: musicOrigin.text)
        records.set(record, for: profile)
        let api = FakeEnroll()
        api.renewals = [.renewed(try TestCertificate.issued(for: SoftwareDeviceKey(), renewAfter: 5000))]
        #expect(!(await DeviceRenewal.renewIfDue(profile: profile, origin: musicOrigin, api: api, keys: keys, records: records, certificates: nil, now: Date(timeIntervalSince1970: 2000))))
        #expect(keys.certificates[profile] == current)
        #expect(records.record(for: profile) == record)

        api.renewals = [.renewed(try TestCertificate.issued(for: key, serial: 2, renewAfter: 5000))]
        #expect(!(await DeviceRenewal.renewIfDue(profile: profile, origin: otherOrigin, api: api, keys: keys, records: records, certificates: nil, now: Date(timeIntervalSince1970: 2000))))
        #expect(api.renewals.count == 1)
        #expect(keys.certificates[profile] == current)
    }
}

struct ClientSafetyTests {
    /// C49: nothing goes to a plain-http address: hello is "not offered" and no proof is signed.
    @Test func plainHTTPIsNeverAsked() async {
        let client = EnrollClient(baseURL: URL(string: "http://music.example")!, login: "u=demo")
        #expect(await client.hello() == .notOffered)
        #expect(await client.apply(EnrollApplication(code: "ABCD2345", csr: Data([1]), deviceID: "d", name: "n", model: "m", system: "s", app: "a")) == .refused)
        let status = await client.status(request: "r", sign: { _ in
            Issue.record("signed for http")
            return Data()
        })
        #expect(status == .refused)
        #expect(await client.renew(csr: Data([1])) == .refused)
    }

    /// C49: a server's `Date` corrects the clock by a few minutes at most; a larger one is ignored.
    @Test func theClockCorrectionIsBounded() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(EnrollClient.clockCorrection(serverDate: now.addingTimeInterval(90), now: now) == 90)
        #expect(EnrollClient.clockCorrection(serverDate: now.addingTimeInterval(-300), now: now) == -300)
        #expect(EnrollClient.clockCorrection(serverDate: now.addingTimeInterval(301), now: now) == nil)
        #expect(EnrollClient.clockCorrection(serverDate: now.addingTimeInterval(-86_400), now: now) == nil)
    }

    /// C49: a certificate or issuer larger than any real one is not taken from an answer.
    @Test func oversizedCertificatesAreNotRead() {
        let big = Data(count: CertificateKey.maxSize + 1).base64EncodedString()
        #expect(EnrollClient.issued(["certificate": big, "renewAfter": 1]) == nil)
        let fine = Data([1, 2]).base64EncodedString()
        #expect(EnrollClient.issued(["certificate": fine, "issuer": big, "renewAfter": 1])?.issuer == nil)
        #expect(EnrollClient.issued(["certificate": fine, "issuer": fine, "renewAfter": 1])?.issuer == Data([1, 2]))
    }
}

struct ProtocolTests {
    @Test func helloReadsTheProtocolsAnswer() {
        let hello = EnrollClient.hello(from: ["v": 1, "devices": "optional", "approved": false, "invited": true, "to": "a•••@b•••.com", "attest": "off"])
        #expect(hello == EnrollHello(devices: .optional, approved: false, invited: true, to: "a•••@b•••.com", attest: .off))
        #expect(EnrollClient.hello(from: ["v": 2, "devices": "off"]) == nil)
        #expect(EnrollClient.hello(from: ["error": "not_found"]) == nil)
    }

    @Test func applicationAnswers() {
        #expect(EnrollClient.applyResult(["v": 1, "request": "x"]) == .filed(request: "x"))
        #expect(EnrollClient.applyResult(["v": 1, "error": "place"]) == .wrongPlace)
        #expect(EnrollClient.applyResult(["v": 1, "error": "code", "tries": 2]) == .wrongCode(triesLeft: 2))
        #expect(EnrollClient.applyResult(["v": 1, "error": "code"]) == .wrongCode(triesLeft: nil))
    }

    @Test func theApplicationsBody() throws {
        let body = EnrollApplication(code: "ABCD2345", csr: Data([1]), deviceID: "id", name: "n", model: "m", system: "s", app: "a").body
        let json = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        #expect(String(decoding: json, as: UTF8.self) == #"{"attestation":null,"code":"ABCD2345","csr":"AQ==","device":{"app":"a","id":"id","model":"m","name":"n","system":"s"},"key":null,"v":1}"#)
    }

    @Test func theProviderAnswersOnlyTheMainAddress() {
        let certificates = DeviceCertificates(store: MemoryKeys())
        certificates.use(profile: UUID(), server: URL(string: "https://music.example")!)
        // No identity stored: nothing presented anywhere.
        #expect(!certificates.presents(to: URL(string: "https://music.example/rest/stream")!))
        #expect(DeviceCertificates.target(UUID(), URL(string: "http://home.example:4533")!) == nil)
        let target = DeviceCertificates.target(UUID(), URL(string: "https://Music.Example:8443/sub")!)
        #expect(target?.host == "music.example" && target?.port == 8443)
    }
}

/// The re-check, item 1: a certificate is never deleted on an answer that may have come over a connection
/// opened before it was stored.
struct RevocationTests {
    final class Resets: @unchecked Sendable {
        var count = 0
        /// The hellos still unasked at each reset: the reset comes before the hello it's for.
        var hellosLeftAtReset: [Int] = []
    }

    private func confirm(_ api: FakeEnroll) async -> (EnrollHello?, Resets) {
        let resets = Resets()
        let answer = await DeviceRevocation.confirm(api: api) {
            resets.count += 1
            resets.hellosLeftAtReset.append(api.hellos.count)
        }
        return (answer, resets)
    }

    /// The stale "not approved", then the new connection says approved: the certificate stays.
    @Test func aStaleAnswerThenApprovedKeepsTheCertificate() async {
        let api = FakeEnroll(hellos: [.answer(EnrollHello(devices: .required, approved: true, invited: false))])
        let (answer, resets) = await confirm(api)
        #expect(answer == nil)
        #expect(resets.count == 1)
        #expect(resets.hellosLeftAtReset == [1])
        #expect(api.hellos.isEmpty)
    }

    /// "Not approved" again on the new connection: the revocation stands.
    @Test func notApprovedTwiceRemovesIt() async {
        let api = FakeEnroll(hellos: [.answer(notInvited)])
        let (answer, resets) = await confirm(api)
        #expect(answer == notInvited)
        #expect(resets.hellosLeftAtReset == [1])
    }

    /// No answer, or no longer a server that asks: nothing is deleted on that.
    @Test(arguments: [HelloResult.unreachable, .notOffered, .answer(EnrollHello(devices: .off, approved: false, invited: false))])
    func aFailedConfirmationKeepsIt(_ second: HelloResult) async {
        let api = FakeEnroll(hellos: [second])
        let (answer, resets) = await confirm(api)
        #expect(answer == nil)
        #expect(resets.count == 1)
    }

    /// Storing or removing a certificate (`refresh`) gives every registered session a new one.
    @Test func aChangedCertificateRenewsTheSessions() {
        let certificates = DeviceCertificates(store: MemoryKeys())
        let sessions = RenewableSession(certificates: certificates) { URLSession(configuration: .ephemeral) }
        let first = sessions.session
        #expect(sessions.session === first)
        certificates.refresh()
        let second = sessions.session
        #expect(second !== first)
        certificates.resetConnections()
        #expect(sessions.session !== second)
    }
}

/// The review after C56: a sign-in check's own sessions. The shared ones are never reset by a check, and
/// one check ending can't change what another presents or end its sessions.
struct LoginSessionsTests {
    @Test func aCheckLeavesTheSharedSessionsAlone() {
        let certificates = DeviceCertificates(store: MemoryKeys())
        let shared = RenewableSession(certificates: certificates) { URLSession(configuration: .ephemeral) }
        let before = shared.session
        let main = URL(string: "https://music.example")
        certificates.use(profile: UUID(), server: main)
        let afterSignIn = shared.session
        #expect(afterSignIn !== before)
        let check = LoginSessions(certificates: certificates, profile: UUID(), server: main)
        check.freshConnections()
        check.end()
        #expect(shared.session === afterSignIn)
        #expect(shared.openSession === afterSignIn)
    }

    /// An overtaken sign-in ending (its `end()`) leaves a newer check's identity and sessions as they were.
    @Test func anOvertakenCheckEndingLeavesTheNewerOne() {
        let certificates = DeviceCertificates(store: MemoryKeys())
        let main = URL(string: "https://music.example")
        let (older, newer) = (UUID(), UUID())
        let overtaken = LoginSessions(certificates: certificates, profile: older, server: main)
        let current = LoginSessions(certificates: certificates, profile: newer, server: main)
        let (api, enrol) = (current.api.session, current.enrol.session)
        overtaken.end()
        #expect(overtaken.hasEnded)
        #expect(overtaken.api.openSession == nil && overtaken.enrol.openSession == nil)
        #expect(!current.hasEnded)
        #expect(current.api.openSession === api && current.enrol.openSession === enrol)
        #expect(current.login == DeviceLogin(profile: newer, server: main))
        #expect(current.login != overtaken.login)
    }

    /// A certificate stored while the screens wait gives a live check new sessions (its next `hello` makes a
    /// new handshake); an ended one stays ended.
    @Test func aStoredCertificateRenewsALiveCheck() {
        let certificates = DeviceCertificates(store: MemoryKeys())
        let main = URL(string: "https://music.example")
        let live = LoginSessions(certificates: certificates, profile: UUID(), server: main)
        let ended = LoginSessions(certificates: certificates, profile: UUID(), server: main)
        ended.end()
        let enrol = live.enrol.session
        certificates.refresh()
        #expect(live.enrol.openSession !== enrol)
        #expect(live.enrol.openSession != nil)
        #expect(ended.enrol.openSession == nil)
        // The revocation's confirmation: new connections for the check alone.
        let renewed = live.enrol.session
        live.freshConnections()
        #expect(live.enrol.session !== renewed)
    }

    /// A check's enrolment calls go over its own session; a stand-in's or a fixed session's stay as they are,
    /// and an ended check's are sent nowhere (no answer, which never removes anything).
    @Test func theRoutesGoOverTheChecksSession() async {
        let check = LoginSessions(certificates: DeviceCertificates(store: MemoryKeys()), profile: UUID(), server: URL(string: "https://music.example"))
        let fake = FakeEnroll(hellos: [.notOffered])
        #expect(fake.using(check) as? FakeEnroll === fake)
        check.end()
        let client = EnrollClient(baseURL: URL(string: "https://music.example")!, login: "u=demo")
        #expect(await client.using(check).hello() == .unreachable)
    }
}

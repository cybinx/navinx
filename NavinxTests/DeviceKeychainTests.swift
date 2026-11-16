import CryptoKit
import DeviceIdentity
import Foundation
import Security
import Testing
@testable import Navinx

/// C45: the device's key and certificate in the Keychain (hosted by the app, which the Keychain needs).
/// The certificate is a self-signed one written here for the key the store made, so no private key is
/// kept anywhere.
@MainActor @Suite(.serialized) struct DeviceKeychainTests {
    private let store = KeychainDeviceKeys()

    @Test func aKeyAndItsCertificateComeBackAsOneIdentity() throws {
        let profile = UUID()
        defer { store.remove(profile: profile) }
        let key = try store.makeKey(for: profile)
        #expect(key.point.count == 65)
        let again = try #require(store.key(for: profile))
        #expect(again.point == key.point)
        let signature = try again.sign(Data("hello".utf8))
        let publicKey = try P256.Signing.PublicKey(x963Representation: key.point)
        #expect(publicKey.isValidSignature(try .init(derRepresentation: signature), for: Data("hello".utf8)))
        #expect(CertificateRequest.isSigned(try again.certificateRequest(), point: key.point))

        #expect(store.identity(for: profile) == nil)
        let certificate = try SelfSigned.certificate(for: again)
        try store.storeCertificate(certificate, for: profile)
        #expect(store.hasCertificate(for: profile))
        let identity = try #require(store.identity(for: profile))
        var held: SecCertificate?
        SecIdentityCopyCertificate(identity, &held)
        #expect((held.map { SecCertificateCopyData($0) as Data }) == certificate)

        // A renewal replaces it (the old one goes once the new one is in, C49); the key stays.
        let renewed = try SelfSigned.certificate(for: again, serial: 2)
        try store.storeCertificate(renewed, for: profile)
        let renewedIdentity = try #require(store.identity(for: profile))
        var renewedHeld: SecCertificate?
        SecIdentityCopyCertificate(renewedIdentity, &renewedHeld)
        #expect((renewedHeld.map { SecCertificateCopyData($0) as Data }) == renewed)
        // The same answer twice is fine.
        try store.storeCertificate(renewed, for: profile)
        #expect(store.hasCertificate(for: profile))
        store.removeCertificate(for: profile)
        #expect(store.identity(for: profile) == nil)
        #expect(store.key(for: profile) != nil)
        store.remove(profile: profile)
        #expect(store.key(for: profile) == nil)
    }

    /// The launch's tidy-up looks only at generic passwords: a device key and certificate stay (D8).
    @Test func theKeychainTidyLeavesTheDeviceAlone() throws {
        let profile = UUID()
        defer { store.remove(profile: profile) }
        let key = try store.makeKey(for: profile)
        try store.storeCertificate(try SelfSigned.certificate(for: key), for: profile)
        let defaults = UserDefaults(suiteName: "device-tidy-\(UUID().uuidString)")!
        defaults.set(true, forKey: KeychainTidy.installCheckedKey)
        KeychainTidy.run(defaults: defaults)
        // A new install's clearing too (on a service of its own, so no saved login is touched).
        KeychainTidy.clearIfNewInstall(service: "com.example.device-tidy", defaults: UserDefaults(suiteName: "device-tidy-\(UUID().uuidString)")!)
        #expect(store.key(for: profile) != nil)
        #expect(store.identity(for: profile) != nil)
    }

    /// C49: only a certificate for the profile's own key is kept, and storing one for a profile never
    /// removes another profile's.
    @Test func onlyACertificateForThisKeyIsKept() throws {
        let (first, second) = (UUID(), UUID())
        defer {
            store.remove(profile: first)
            store.remove(profile: second)
        }
        let firstKey = try store.makeKey(for: first)
        let firstCertificate = try SelfSigned.certificate(for: firstKey)
        try store.storeCertificate(firstCertificate, for: first)
        _ = try store.makeKey(for: second)
        // Another profile's certificate, as a hostile server could send it back.
        #expect(throws: (any Error).self) { try store.storeCertificate(firstCertificate, for: second) }
        #expect(!store.hasCertificate(for: second))
        #expect(store.identity(for: first) != nil)
        // A certificate for a key that isn't the profile's: refused, and the working one stays.
        #expect(throws: (any Error).self) { try store.storeCertificate(try SelfSigned.certificate(for: SoftwareDeviceKey()), for: first) }
        let identity = try #require(store.identity(for: first))
        var held: SecCertificate?
        SecIdentityCopyCertificate(identity, &held)
        #expect((held.map { SecCertificateCopyData($0) as Data }) == firstCertificate)
    }

    /// The provider answers only the profile's main address, and only once it holds a certificate
    /// issued there (C49).
    @Test func theProviderPresentsAtTheMainAddressOnly() throws {
        let profile = UUID()
        defer { store.remove(profile: profile) }
        let records = DeviceRecords(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        records.set(DeviceRecords.Record(origin: "https://music.example:443"), for: profile)
        let certificates = DeviceCertificates(store: store, records: records)
        certificates.use(profile: profile, server: URL(string: "https://music.example"))
        let key = try store.makeKey(for: profile)
        #expect(!certificates.presents(to: URL(string: "https://music.example/rest/stream")!))
        try store.storeCertificate(try SelfSigned.certificate(for: key), for: profile)
        certificates.refresh()
        #expect(certificates.presents(to: URL(string: "https://music.example/rest/stream")!))
        #expect(certificates.credential(host: "Music.Example", port: 443) != nil)
        #expect(!certificates.presents(to: URL(string: "http://music.example/rest/stream")!))
        #expect(!certificates.presents(to: URL(string: "https://other.example/rest/stream")!))
        #expect(certificates.credential(host: "music.example", port: 8443) == nil)
        // The profile edited to another address, or a login checked there: nothing presented to it.
        certificates.use(profile: profile, server: URL(string: "https://other.example"))
        #expect(!certificates.presents(to: URL(string: "https://other.example/rest/stream")!))
        let checkedThere = DeviceLogin(profile: profile, server: URL(string: "https://other.example"))
        #expect(certificates.credential(host: "other.example", port: 443, for: checkedThere) == nil)
        // A certificate recorded for another address isn't presented at this one, even as its target.
        records.set(DeviceRecords.Record(origin: "https://other.example:443"), for: profile)
        certificates.use(profile: profile, server: URL(string: "https://music.example"))
        certificates.refresh()
        #expect(!certificates.presents(to: URL(string: "https://music.example/rest/stream")!))
        certificates.use(profile: nil, server: nil)
        #expect(!certificates.presents(to: URL(string: "https://music.example/rest/stream")!))
    }

    /// The audit after C55, A1, and the review after C56: a second account on the same server never presents
    /// the first one's certificate, while it's checked (over its own sessions) or once it's signed in; while
    /// it's checked, the shared sessions go on presenting the signed-in account's and aren't reset; every
    /// change of the signed-in account drops the open connections.
    @Test func anotherAccountOnTheSameServerPresentsOnlyItsOwn() throws {
        let (first, second) = (UUID(), UUID())
        defer {
            store.remove(profile: first)
            store.remove(profile: second)
        }
        let records = DeviceRecords(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        records.set(DeviceRecords.Record(origin: "https://music.example:443"), for: first)
        records.set(DeviceRecords.Record(origin: "https://music.example:443"), for: second)
        let certificates = DeviceCertificates(store: store, records: records)
        let resets = ResetCount()
        certificates.addConnectionReset { resets.add() }
        let main = URL(string: "https://music.example")
        func data(_ credential: URLCredential?) -> Data? {
            guard let identity = credential?.identity else { return nil }
            var held: SecCertificate?
            SecIdentityCopyCertificate(identity, &held)
            return held.map { SecCertificateCopyData($0) as Data }
        }
        /// What the shared sessions present (the signed-in account's).
        func presented() -> Data? { data(certificates.credential(host: "music.example", port: 443)) }
        /// What a check of `login` presents over its own sessions.
        func checked(_ login: LoginSessions) -> Data? {
            data(certificates.credential(host: "music.example", port: 443, for: login.login))
        }

        let firstCertificate = try SelfSigned.certificate(for: try store.makeKey(for: first))
        try store.storeCertificate(firstCertificate, for: first)
        certificates.use(profile: first, server: main)
        #expect(resets.count == 1)
        #expect(presented() == firstCertificate)
        #expect(certificates.credential(host: "music.example", port: 443)?.persistence == URLCredential.Persistence.none)
        // The background downloads session keeps it for the session.
        #expect(certificates.credential(host: "music.example", port: 443, persistence: .forSession)?.persistence == .forSession)

        // The second account checked: nothing over its own sessions (it holds no certificate), never the
        // first one's; the shared sessions still present the first's, and nothing was reset.
        let check = LoginSessions(certificates: certificates, profile: second, server: main)
        #expect(checked(check) == nil)
        #expect(presented() == firstCertificate)
        #expect(resets.count == 1)
        // A login checked at another server presents nothing here either.
        let elsewhere = LoginSessions(certificates: certificates, profile: second, server: URL(string: "https://other.example"))
        #expect(checked(elsewhere) == nil)
        check.end()
        elsewhere.end()
        #expect(presented() == firstCertificate)
        #expect(resets.count == 1)

        // Signed in as the second: nothing, over new connections; the same again drops nothing.
        certificates.use(profile: second, server: main)
        #expect(resets.count == 2)
        #expect(presented() == nil)
        certificates.use(profile: second, server: main)
        #expect(resets.count == 2)

        // Its own once it has one, also while it's checked with the first signed in.
        // Its own serial: the Keychain keeps one certificate per issuer and serial.
        let secondCertificate = try SelfSigned.certificate(for: try store.makeKey(for: second), serial: 2)
        try store.storeCertificate(secondCertificate, for: second)
        certificates.refresh()
        #expect(presented() == secondCertificate)
        certificates.use(profile: first, server: main)
        let again = LoginSessions(certificates: certificates, profile: second, server: main)
        #expect(checked(again) == secondCertificate)
        #expect(presented() == firstCertificate)
        // A check of the signed-in account presents its own, as the shared sessions do.
        let same = LoginSessions(certificates: certificates, profile: first, server: main)
        #expect(checked(same) == firstCertificate)
        again.end()
        same.end()
        #expect(presented() == firstCertificate)
    }
}

private final class ResetCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}

/// A minimal self-signed X.509 certificate for a device key (tests only).
enum SelfSigned {
    static func certificate(for key: any DeviceKey, serial: UInt8 = 1) throws -> Data {
        func element(_ tag: UInt8, _ content: Data) -> Data {
            var out = Data([tag])
            if content.count < 0x80 {
                out.append(UInt8(content.count))
            } else if content.count < 0x100 {
                out.append(contentsOf: [0x81, UInt8(content.count)])
            } else {
                out.append(contentsOf: [0x82, UInt8(content.count >> 8), UInt8(content.count & 0xFF)])
            }
            out.append(content)
            return out
        }
        func sequence(_ parts: Data...) -> Data { element(0x30, parts.reduce(Data(), +)) }
        let ecdsaSHA256 = Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
        let commonName = Data([0x06, 0x03, 0x55, 0x04, 0x03])
        let name = sequence(element(0x31, sequence(commonName, element(0x0C, Data("device test".utf8)))))
        let validity = sequence(element(0x17, Data("260101000000Z".utf8)), element(0x17, Data("361231000000Z".utf8)))
        let tbs = sequence(
            element(0xA0, element(0x02, Data([2]))),
            element(0x02, Data([serial])),
            sequence(ecdsaSHA256),
            name,
            validity,
            name,
            key.subjectPublicKeyInfo
        )
        let signature = try key.sign(tbs)
        return sequence(tbs, sequence(ecdsaSHA256), element(0x03, Data([0]) + signature))
    }
}

import Foundation
import Security
import Testing
@testable import DeviceIdentity

/// A minimal self-signed X.509 certificate for a device key, written here (no key or certificate is kept
/// in the repo). The same layout as the app tests' `SelfSigned`.
enum TestCertificate {
    static func element(_ tag: UInt8, _ content: Data) -> Data {
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

    static func sequence(_ parts: Data...) -> Data { element(0x30, parts.reduce(Data(), +)) }

    static func make(for key: any DeviceKey, serial: UInt8 = 1) throws -> Data {
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

    static func issued(for key: any DeviceKey, serial: UInt8 = 1, renewAfter: Double = 1_800_000_000) throws -> IssuedCertificate {
        IssuedCertificate(certificate: try make(for: key, serial: serial), issuer: Data([4]), renewAfter: renewAfter)
    }
}

struct CertificateKeyTests {
    @Test func readsTheKeyOfACertificateMadeHere() throws {
        let key = SoftwareDeviceKey()
        let certificate = try TestCertificate.make(for: key)
        // The system takes it as a certificate too, so the reader is checked against a real layout.
        #expect(SecCertificateCreateWithData(nil, certificate as CFData) != nil)
        #expect(CertificateKey.subjectPublicKeyInfo(of: certificate) == key.subjectPublicKeyInfo)
        #expect(CertificateKey.certificate(certificate, isFor: key))
        #expect(!CertificateKey.certificate(certificate, isFor: SoftwareDeviceKey()))
    }

    @Test func aCertificateWithNoVersionFieldIsReadToo() throws {
        let key = SoftwareDeviceKey()
        let algorithm = TestCertificate.sequence(Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]))
        let empty = TestCertificate.sequence()
        let tbs = TestCertificate.sequence(Data([0x02, 0x01, 0x01]), algorithm, empty, empty, empty, key.subjectPublicKeyInfo)
        let certificate = TestCertificate.sequence(tbs, algorithm, TestCertificate.element(0x03, Data([0, 1])))
        #expect(CertificateKey.subjectPublicKeyInfo(of: certificate) == key.subjectPublicKeyInfo)
    }

    @Test func anythingButOneWellFormedCertificateIsRefused() throws {
        let certificate = try TestCertificate.make(for: SoftwareDeviceKey())
        #expect(CertificateKey.subjectPublicKeyInfo(of: Data()) == nil)
        #expect(CertificateKey.subjectPublicKeyInfo(of: Data([1, 2, 3])) == nil)
        // Cut short, or with anything after it.
        #expect(CertificateKey.subjectPublicKeyInfo(of: certificate.dropLast()) == nil)
        #expect(CertificateKey.subjectPublicKeyInfo(of: certificate + Data([0])) == nil)
        // An indefinite length.
        var indefinite = certificate
        indefinite[indefinite.startIndex + 1] = 0x80
        #expect(CertificateKey.subjectPublicKeyInfo(of: indefinite) == nil)
        // Too large to be one, whatever is in it.
        #expect(CertificateKey.subjectPublicKeyInfo(of: Data(count: CertificateKey.maxSize + 1)) == nil)
        // The key's field missing: nothing else is taken for it.
        let empty = TestCertificate.sequence()
        let short = TestCertificate.sequence(
            TestCertificate.sequence(Data([0x02, 0x01, 0x01]), empty, empty, empty, empty),
            empty, TestCertificate.element(0x03, Data([0]))
        )
        #expect(CertificateKey.subjectPublicKeyInfo(of: short) == nil)
    }

    @Test func lengthsMustBeInTheirShortestForm() {
        let reader = StrictDER(bytes: [0x30, 0x81, 0x03, 1, 2, 3])
        #expect(reader.element(at: 0, end: 6) == nil)
        let long = StrictDER(bytes: [0x04, 0x82, 0x00, 0x05, 1, 2, 3, 4, 5])
        #expect(long.element(at: 0, end: 9) == nil)
        let fine = StrictDER(bytes: [0x04, 0x03, 1, 2, 3])
        #expect(fine.element(at: 0, end: 5)?.content == 2..<5)
        // Contents past the bound given.
        #expect(fine.element(at: 0, end: 4) == nil)
        // A high tag number.
        #expect(StrictDER(bytes: [0x1F, 0x01, 0x00]).element(at: 0, end: 3) == nil)
    }
}

struct RecordFormTests {
    /// A record written before C49 reads as it was, and a record with no origin is written as before.
    @Test func recordsWithoutAnOriginKeepTheirForm() throws {
        let old = Data(#"{"issuer":"BA==","renewAfter":1000,"request":"r"}"#.utf8)
        let read = try JSONDecoder().decode(DeviceRecords.Record.self, from: old)
        #expect(read == DeviceRecords.Record(request: "r", renewAfter: 1000, issuer: Data([4])))
        #expect(read.origin == nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(read) == old)
        let new = DeviceRecords.Record(renewAfter: 1000, origin: "https://music.example:443")
        #expect(String(decoding: try encoder.encode(new), as: UTF8.self) == #"{"origin":"https:\/\/music.example:443","renewAfter":1000}"#)
    }

    @Test func origins() {
        #expect(DeviceOrigin(URL(string: "https://Music.Example/sub")!)?.text == "https://music.example:443")
        #expect(DeviceOrigin(URL(string: "https://music.example:8443")!)?.text == "https://music.example:8443")
        #expect(DeviceOrigin(URL(string: "http://music.example")!) == nil)
        let record = DeviceRecords.Record(origin: "https://music.example:443")
        #expect(record.belongs(to: DeviceOrigin(host: "music.example", port: 443)))
        #expect(!record.belongs(to: DeviceOrigin(host: "other.example", port: 443)))
        #expect(!record.belongs(to: nil))
        #expect(!DeviceRecords.Record().belongs(to: DeviceOrigin(host: "music.example", port: 443)))
    }
}

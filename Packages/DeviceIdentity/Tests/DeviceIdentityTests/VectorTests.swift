import CryptoKit
import Foundation
import Testing
@testable import DeviceIdentity

/// The shared vectors (`Server/panel/enroll_vectors.json`, copied as it is): the add-on asserts the same.
struct Vectors: Decodable {
    struct Words: Decodable { let spki: String; let sha256: String; let indexes: [Int]; let words: [String] }
    struct Attest: Decodable { let code: String; let username: String; let spki: String; let sha256: String }
    struct Status: Decodable { let request: String; let time: Int; let messageBase64: String }
    struct Reference: Decodable { let csr: String; let spki: String }
    let words: [Words]
    let attestClientData: [Attest]
    let statusMessage: [Status]
    let csrReference: Reference

    static let loaded: Vectors = {
        let url = Bundle.module.url(forResource: "enroll_vectors", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }()
}

private func hex(_ data: some Sequence<UInt8>) -> String { data.map { String(format: "%02x", $0) }.joined() }

/// The point inside a P-256 SubjectPublicKeyInfo (its last 65 bytes).
private func point(ofSPKI spki: Data) -> Data { spki.suffix(65) }

struct VectorTests {
    @Test func theWordListIsTheAddOnsAndHas256Words() {
        #expect(DeviceWords.list.count == 256)
        #expect(Set(DeviceWords.list).count == 256)
        #expect(DeviceWords.list.first == "otter")
    }

    @Test(arguments: Vectors.loaded.words)
    func fourWords(_ vector: Vectors.Words) throws {
        let spki = try #require(Data(base64Encoded: vector.spki))
        var hashed = Data("navinx-words-v1\n".utf8)
        hashed.append(spki)
        #expect(hex(SHA256.hash(data: hashed)) == vector.sha256)
        #expect(DeviceWords.indexes(subjectPublicKeyInfo: spki) == vector.indexes)
        #expect(DeviceWords.words(subjectPublicKeyInfo: spki) == vector.words)
        // The app makes the same SubjectPublicKeyInfo from the bare point the system exports.
        #expect(PublicKeyInfo.subjectPublicKeyInfo(point: point(ofSPKI: spki)) == spki)
    }

    @Test(arguments: Vectors.loaded.attestClientData)
    func attestationClientDataHash(_ vector: Vectors.Attest) throws {
        let spki = try #require(Data(base64Encoded: vector.spki))
        let hash = EnrollProof.attestClientDataHash(code: vector.code, username: vector.username, subjectPublicKeyInfo: spki)
        #expect(hex(hash) == vector.sha256)
    }

    @Test(arguments: Vectors.loaded.statusMessage)
    func statusMessage(_ vector: Vectors.Status) {
        #expect(EnrollProof.statusMessage(request: vector.request, time: vector.time).base64EncodedString() == vector.messageBase64)
    }

    /// The reference request (made by `openssl`) and the app's own for the same key: the same bytes up to
    /// the signature, so `openssl` and the add-on read them the same way; each signature holds.
    @Test func certificateRequestReadsLikeTheReference() throws {
        let reference = try #require(Data(base64Encoded: Vectors.loaded.csrReference.csr))
        let spki = try #require(Data(base64Encoded: Vectors.loaded.csrReference.spki))
        let point = point(ofSPKI: spki)
        let (referenceInfo, _) = try #require(CertificateRequest.parts(of: reference))
        #expect(CertificateRequest.info(point: point) == referenceInfo)
        #expect(CertificateRequest.isSigned(reference, point: point))

        // The app's own, with a throwaway key made now (never kept).
        let key = SoftwareDeviceKey()
        let made = try key.certificateRequest()
        let (info, _) = try #require(CertificateRequest.parts(of: made))
        #expect(info == CertificateRequest.info(point: key.point))
        #expect(CertificateRequest.isSigned(made, point: key.point))
        #expect(!CertificateRequest.isSigned(made, point: point))
        #expect(info.count == referenceInfo.count)
        if let folder = ProcessInfo.processInfo.environment["DEVICEIDENTITY_OUT"] {
            try made.write(to: URL(fileURLWithPath: folder).appending(path: "app-request.der"))
        }
    }
}

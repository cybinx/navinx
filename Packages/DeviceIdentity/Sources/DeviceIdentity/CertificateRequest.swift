import CryptoKit
import Foundation

/// The public half of a P-256 key in the forms the protocol uses (`docs/log/C44.md`, "The protocol, v1").
public enum PublicKeyInfo {
    /// The SubjectPublicKeyInfo DER for an uncompressed P-256 point (`04 || X || Y`, 65 bytes), as the
    /// system exports a key (`SecKeyCopyExternalRepresentation`): what the four words and the
    /// attestation's hash are made from.
    public static func subjectPublicKeyInfo(point: Data) -> Data {
        DER.sequence(
            DER.sequence(DER.oid("1.2.840.10045.2.1"), DER.oid("1.2.840.10045.3.1.7")),
            DER.bitString(point)
        )
    }
}

/// A PKCS#10 certificate request (RFC 2986) for a P-256 key, signed with ECDSA and SHA-256, written by
/// hand: the subject `CN=navinx`, no attributes, as the reference request in `enroll_vectors.json`. The
/// add-on ignores the subject and writes its own; the request's signature proves the sender holds the key.
public enum CertificateRequest {
    public static let commonName = "navinx"

    /// The part the key signs (`CertificationRequestInfo`).
    public static func info(point: Data) -> Data {
        DER.sequence(
            DER.integer(0),
            DER.sequence(DER.set(DER.sequence(DER.oid("2.5.4.3"), DER.utf8String(commonName)))),
            PublicKeyInfo.subjectPublicKeyInfo(point: point),
            DER.element(0xA0, Data())
        )
    }

    /// The request, its info signed by `sign`, which returns an X9.62 DER ECDSA signature over SHA-256
    /// of what it's given (`SecKeyCreateSignature` with `.ecdsaSignatureMessageX962SHA256`).
    public static func make(point: Data, sign: (Data) throws -> Data) rethrows -> Data {
        let info = info(point: point)
        let signature = try sign(info)
        return DER.sequence(info, DER.sequence(DER.oid("1.2.840.10045.4.3.2")), DER.bitString(signature))
    }

    /// A request's info and signature, for checking one (tests, and the reference in the vectors).
    public static func parts(of request: Data) -> (info: Data, signature: Data)? {
        guard let outer = DER.read(request, at: 0), outer.tag == 0x30,
              let info = DER.read(request, at: outer.content.lowerBound), info.tag == 0x30,
              let algorithm = DER.read(request, at: info.end), algorithm.tag == 0x30,
              let bits = DER.read(request, at: algorithm.end), bits.tag == 0x03, bits.content.count > 1 else { return nil }
        let infoBytes = request.subdata(in: (outer.content.lowerBound)..<info.end)
        let signature = request.subdata(in: (bits.content.lowerBound + 1)..<bits.content.upperBound)
        return (infoBytes, signature)
    }

    /// Whether `request`'s own signature holds for the key in it.
    public static func isSigned(_ request: Data, point: Data) -> Bool {
        guard let (info, signature) = parts(of: request),
              let key = try? P256.Signing.PublicKey(x963Representation: point),
              let decoded = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return key.isValidSignature(decoded, for: info)
    }
}

/// The protocol's hashes and signed messages (C44, "The protocol, v1").
public enum EnrollProof {
    /// What App Attest's attestation covers at enrolment: `SHA256("navinx-enroll-v1\n" + code + "\n" +
    /// lower-cased username + "\n" + SHA256(SubjectPublicKeyInfo))`.
    public static func attestClientDataHash(code: String, username: String, subjectPublicKeyInfo: Data) -> Data {
        var data = Data("navinx-enroll-v1\n".utf8)
        data.append(Data(code.utf8))
        data.append(Data("\n".utf8))
        data.append(Data(username.lowercased().utf8))
        data.append(Data("\n".utf8))
        data.append(Data(SHA256.hash(data: subjectPublicKeyInfo)))
        return Data(SHA256.hash(data: data))
    }

    /// What the pending key signs to ask for its request's state: `"navinx-status-v1\n" + id + "\n" + time`.
    public static func statusMessage(request: String, time: Int) -> Data {
        Data("navinx-status-v1\n\(request)\n\(time)".utf8)
    }
}

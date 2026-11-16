import Foundation

/// Which key a certificate from the server is for (C49): before a certificate is kept, its
/// SubjectPublicKeyInfo must be this device's own, byte for byte (DER has one encoding per value). A
/// certificate for any other key is refused, so a server can't make the app keep a certificate it can't
/// use, or one that belongs to another profile.
public enum CertificateKey {
    /// No certificate the add-on issues comes near this; anything larger is refused unread.
    public static let maxSize = 16 * 1024

    /// The certificate's SubjectPublicKeyInfo, whole (tag and length included), or nil when `certificate`
    /// isn't one well-formed DER X.509 certificate of at most `maxSize` bytes.
    public static func subjectPublicKeyInfo(of certificate: Data) -> Data? {
        guard certificate.count <= maxSize else { return nil }
        let reader = StrictDER(bytes: [UInt8](certificate))
        let all = reader.bytes.count
        // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }, nothing after it.
        guard let outer = reader.element(at: 0, end: all), outer.tag == 0x30, outer.end == all,
              let tbs = reader.element(at: outer.content.lowerBound, end: outer.content.upperBound), tbs.tag == 0x30,
              let algorithm = reader.element(at: tbs.end, end: outer.content.upperBound), algorithm.tag == 0x30,
              let signature = reader.element(at: algorithm.end, end: outer.content.upperBound), signature.tag == 0x03,
              signature.end == outer.content.upperBound else { return nil }
        // TBSCertificate ::= SEQUENCE { [0] version OPTIONAL, serialNumber, signature, issuer, validity,
        // subject, subjectPublicKeyInfo, ... }
        let end = tbs.content.upperBound
        guard var field = reader.element(at: tbs.content.lowerBound, end: end) else { return nil }
        if field.tag == 0xA0 {
            guard let next = reader.element(at: field.end, end: end) else { return nil }
            field = next
        }
        guard field.tag == 0x02 else { return nil }
        // signature, issuer, validity, subject, subjectPublicKeyInfo: five SEQUENCEs in a row.
        for _ in 0..<5 {
            guard let next = reader.element(at: field.end, end: end), next.tag == 0x30 else { return nil }
            field = next
        }
        return Data(reader.bytes[field.whole])
    }

    /// Whether `certificate` is for `key`.
    public static func certificate(_ certificate: Data, isFor key: any DeviceKey) -> Bool {
        guard let info = subjectPublicKeyInfo(of: certificate) else { return false }
        return info == key.subjectPublicKeyInfo
    }
}

/// A DER reader that accepts only what DER allows: a low tag number, a definite length in its shortest
/// form (at most two length bytes, enough for `CertificateKey.maxSize`), and contents inside the bounds
/// it is given.
struct StrictDER {
    struct Element {
        let tag: UInt8
        /// Tag, length and contents.
        let whole: Range<Int>
        let content: Range<Int>
        var end: Int { whole.upperBound }
    }

    let bytes: [UInt8]

    /// The element starting at `offset`, which must end by `end`.
    func element(at offset: Int, end: Int) -> Element? {
        guard offset >= 0, end <= bytes.count, offset + 2 <= end else { return nil }
        let tag = bytes[offset]
        guard tag & 0x1F != 0x1F else { return nil }   // high tag numbers: never in a certificate's frame
        let first = Int(bytes[offset + 1])
        var index = offset + 2
        let count: Int
        switch first {
        case 0..<0x80:
            count = first
        case 0x81:
            guard index + 1 <= end else { return nil }
            count = Int(bytes[index])
            guard count >= 0x80 else { return nil }   // would fit the short form
            index += 1
        case 0x82:
            guard index + 2 <= end else { return nil }
            count = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            guard count >= 0x100 else { return nil }   // would fit one length byte
            index += 2
        default:
            return nil   // indefinite (0x80) or longer than any certificate kept here
        }
        guard count <= end - index else { return nil }
        return Element(tag: tag, whole: offset..<(index + count), content: index..<(index + count))
    }
}

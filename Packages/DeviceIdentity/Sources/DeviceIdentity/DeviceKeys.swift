import CryptoKit
import Foundation
import Security

/// A device key: P-256, its private half never leaving where it was made.
public protocol DeviceKey: Sendable {
    /// The public half, an uncompressed point (`04 || X || Y`).
    var point: Data { get }
    /// An X9.62 DER ECDSA signature over SHA-256 of `message`.
    func sign(_ message: Data) throws -> Data
}

extension DeviceKey {
    public var subjectPublicKeyInfo: Data { PublicKeyInfo.subjectPublicKeyInfo(point: point) }
    public var words: [String] { DeviceWords.words(subjectPublicKeyInfo: subjectPublicKeyInfo) }
    public func certificateRequest() throws -> Data { try CertificateRequest.make(point: point, sign: sign) }
}

/// Where each server profile's key and certificate are kept. The app uses `KeychainDeviceKeys`; tests a
/// stand-in.
public protocol DeviceKeyStore: Sendable {
    func key(for profile: UUID) -> (any DeviceKey)?
    /// A new key for the profile, replacing any it had (and its certificate).
    func makeKey(for profile: UUID) throws -> any DeviceKey
    /// Keeps `certificate` (DER) for the profile's key, in place of the one it had. The caller has checked
    /// that it is for the profile's key (`CertificateKey`); the Keychain store checks again.
    func storeCertificate(_ certificate: Data, for profile: UUID) throws
    func hasCertificate(for profile: UUID) -> Bool
    /// The key and certificate together, as the system hands them to a connection.
    func identity(for profile: UUID) -> SecIdentity?
    /// The profile's certificate goes; the key stays.
    func removeCertificate(for profile: UUID)
    /// The profile's key and certificate go (the profile was removed, or the device revoked).
    func remove(profile: UUID)
}

/// Keys in the Secure Enclave where there is one (a phone), not exportable; a Keychain key elsewhere (the
/// simulator). Both are readable after the first unlock, so background playback and downloads can use
/// them with the phone locked, and never leave this device (`ThisDeviceOnly`). Key items are
/// `kSecClassKey` and certificates `kSecClassCertificate`, so the launch's Keychain tidy-up, which looks
/// only at generic passwords, never touches them.
public struct KeychainDeviceKeys: DeviceKeyStore {
    public struct Failure: Error, Sendable {
        public let status: OSStatus
    }

    public init() {}

    static func tag(_ profile: UUID) -> Data { Data("navinx.device-key.\(profile.uuidString)".utf8) }
    static func label(_ profile: UUID) -> String { "navinx.device-certificate.\(profile.uuidString)" }

    public func key(for profile: UUID) -> (any DeviceKey)? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag: Self.tag(profile),
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let result, CFGetTypeID(result) == SecKeyGetTypeID() else { return nil }
        return KeychainKey(privateKey: result as! SecKey)
    }

    public func makeKey(for profile: UUID) throws -> any DeviceKey {
        remove(profile: profile)
        if SecureEnclave.isAvailable, let made = try? make(profile, inSecureEnclave: true) { return made }
        return try make(profile, inSecureEnclave: false)
    }

    private func make(_ profile: UUID, inSecureEnclave: Bool) throws -> any DeviceKey {
        var privateAttributes: [CFString: Any] = [
            kSecAttrIsPermanent: true,
            kSecAttrApplicationTag: Self.tag(profile),
        ]
        var attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
        ]
        if inSecureEnclave {
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, nil
            ) else { throw Failure(status: errSecParam) }
            privateAttributes[kSecAttrAccessControl] = access
            attributes[kSecAttrTokenID] = kSecAttrTokenIDSecureEnclave
        } else {
            privateAttributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        attributes[kSecPrivateKeyAttrs] = privateAttributes
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw Failure(status: OSStatus((error?.takeRetainedValue()).map(CFErrorGetCode) ?? Int(errSecParam)))
        }
        return KeychainKey(privateKey: key)
    }

    /// Only a certificate for the profile's own key is kept (C49). The new one is added first and the
    /// older ones under the profile's label go after, so a failed add leaves the working certificate;
    /// nothing under another profile's label is ever removed (a certificate already kept there is refused).
    public func storeCertificate(_ certificate: Data, for profile: UUID) throws {
        guard let key = key(for: profile), CertificateKey.certificate(certificate, isFor: key) else {
            throw Failure(status: errSecParam)
        }
        guard let made = SecCertificateCreateWithData(nil, certificate as CFData) else {
            throw Failure(status: errSecDecode)
        }
        let label = Self.label(profile)
        let status = SecItemAdd([
            kSecClass: kSecClassCertificate,
            kSecValueRef: made,
            kSecAttrLabel: label,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Kept already: fine under this profile's label (the same answer twice), refused under another's.
            guard certificates(labelled: label).contains(where: { $0.data == certificate }) else {
                throw Failure(status: status)
            }
        } else if status != errSecSuccess {
            throw Failure(status: status)
        }
        for old in certificates(labelled: label) where old.data != certificate {
            SecItemDelete([kSecClass: kSecClassCertificate, kSecValuePersistentRef: old.reference] as CFDictionary)
        }
    }

    /// Every certificate kept under `label`: its DER and a reference to that one item.
    private func certificates(labelled label: String) -> [(data: Data, reference: Data)] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: label,
            kSecReturnData: true,
            kSecReturnPersistentRef: true,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let data = item[kSecValueData as String] as? Data,
                  let reference = item[kSecValuePersistentRef as String] as? Data else { return nil }
            return (data, reference)
        }
    }

    public func hasCertificate(for profile: UUID) -> Bool {
        SecItemCopyMatching([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: Self.label(profile),
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, nil) == errSecSuccess
    }

    public func identity(for profile: UUID) -> SecIdentity? {
        guard hasCertificate(for: profile) else { return nil }
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassIdentity,
            kSecAttrApplicationTag: Self.tag(profile),
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let result, CFGetTypeID(result) == SecIdentityGetTypeID() else { return nil }
        return (result as! SecIdentity)
    }

    public func removeCertificate(for profile: UUID) {
        SecItemDelete([kSecClass: kSecClassCertificate, kSecAttrLabel: Self.label(profile)] as CFDictionary)
    }

    public func remove(profile: UUID) {
        removeCertificate(for: profile)
        SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: Self.tag(profile)] as CFDictionary)
    }
}

/// A key held by the system (Secure Enclave or Keychain).
struct KeychainKey: DeviceKey, @unchecked Sendable {
    let privateKey: SecKey

    var point: Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let data = SecKeyCopyExternalRepresentation(publicKey, nil) else { return Data() }
        return data as Data
    }

    func sign(_ message: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey, .ecdsaSignatureMessageX962SHA256, message as CFData, &error
        ) else {
            throw KeychainDeviceKeys.Failure(status: OSStatus((error?.takeRetainedValue()).map(CFErrorGetCode) ?? Int(errSecParam)))
        }
        return signature as Data
    }
}

/// A key in memory (CryptoKit), for tests.
public struct SoftwareDeviceKey: DeviceKey {
    public let privateKey: P256.Signing.PrivateKey

    public init(_ privateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
        self.privateKey = privateKey
    }

    public var point: Data { privateKey.publicKey.x963Representation }

    public func sign(_ message: Data) throws -> Data {
        try privateKey.signature(for: message).derRepresentation
    }
}

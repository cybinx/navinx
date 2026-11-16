import DeviceCheck
import Foundation
import HubKit

/// What `AppKey` asks of Apple's App Attest (`DCAppAttestService`); tests use a stand-in.
nonisolated protocol AttestService {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

nonisolated extension DCAppAttestService: AttestService {}

/// The app's key for the hub's sign-in: Apple's App Attest, one key per account profile. The key stays in
/// the Secure Enclave; its id is kept in the Keychain. Where App Attest can't work (the simulator, a build
/// without its entitlement, Apple's service unreachable) every call fails, and the sign-in goes without it.
///
/// A key is let go only on an answer that it can't be used: Apple's (an attestation refused for any
/// reason but its service being unreachable, or an assertion for a key the system no longer has) or the
/// server's (`HubSessions`: hello asks for a new key). A key made whose attestation didn't get through is
/// kept aside and attested on the next try, as Apple asks, instead of a new one being made.
nonisolated final class AppKey: HubKeyProvider {
    struct Unavailable: Error {}

    private let name: String
    private let waitingName: String
    private let service: @Sendable () -> any AttestService
    private let store: @MainActor @Sendable () -> any SecretStore

    init(
        profileID: UUID,
        service: @escaping @Sendable () -> any AttestService = { DCAppAttestService.shared },
        store: @escaping @MainActor @Sendable () -> any SecretStore = { KeychainSecretStore() }
    ) {
        name = Self.keychainName(profileID)
        waitingName = Self.waitingKeychainName(profileID)
        self.service = service
        self.store = store
    }

    /// The key for a profile, or none without one (nothing signed in).
    static func provider(for profileID: UUID?) -> any HubKeyProvider {
        profileID.map { AppKey(profileID: $0) } ?? NoHubKey()
    }

    static func keychainName(_ profileID: UUID) -> String { "device.\(profileID.uuidString)" }

    /// A key made but not yet attested.
    static func waitingKeychainName(_ profileID: UUID) -> String { "device.waiting.\(profileID.uuidString)" }

    /// A profile's key ids go with the profile (a sign-out, a removed server).
    @MainActor static func forget(profileID: UUID, in store: any SecretStore = KeychainSecretStore()) {
        store.delete(keychainName(profileID))
        store.delete(waitingKeychainName(profileID))
    }

    func currentKeyID() async -> String? {
        await read(name)
    }

    func attestNewKey(clientDataHash: Data) async throws -> HubAttestedKey {
        let service = service()
        guard service.isSupported else { throw Unavailable() }
        let id: String
        if let waiting = await read(waitingName) {
            id = waiting
        } else {
            id = try await service.generateKey()
            // Aside at once, so a failure or a sign-in that stops waiting doesn't lose it.
            await write(id, waitingName)
        }
        let attestation: Data
        do {
            attestation = try await service.attestKey(id, clientDataHash: clientDataHash)
        } catch let error as DCError where error.code != .serverUnavailable {
            // Apple's answer that this key can't be attested: the next try makes a new one.
            await delete(waitingName)
            throw error
        }
        await write(id, name)
        await delete(waitingName)
        return HubAttestedKey(keyID: id, attestation: attestation)
    }

    func assertion(clientDataHash: Data) async throws -> Data {
        let service = service()
        guard service.isSupported, let id = await currentKeyID() else { throw Unavailable() }
        do {
            return try await service.generateAssertion(id, clientDataHash: clientDataHash)
        } catch let error as DCError where error.code == .invalidKey {
            // The system no longer has this key (a restore to another phone): the next sign-in makes one.
            await forgetKey()
            throw error
        }
    }

    func forgetKey() async {
        await delete(name)
    }

    // MARK: The Keychain

    private func read(_ key: String) async -> String? {
        let store = store
        return await MainActor.run { store().read(key) }
    }

    private func write(_ value: String, _ key: String) async {
        let store = store
        await MainActor.run { _ = store().write(value, for: key) }
    }

    private func delete(_ key: String) async {
        let store = store
        await MainActor.run { store().delete(key) }
    }
}

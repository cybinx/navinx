import Foundation
import Security

/// Where passwords live. The app uses the Keychain; tests use `InMemorySecretStore`.
protocol SecretStore: AnyObject {
    func read(_ key: String) -> String?
    /// False when the value couldn't be saved.
    @discardableResult func write(_ value: String, for key: String) -> Bool
    func delete(_ key: String)
}

/// Generic-password items under one service, readable after the first unlock so background
/// playback (C4) can reconnect while the phone is locked.
final class KeychainSecretStore: SecretStore {
    let service: String

    nonisolated static let defaultService = "com.cybinx.navinx.app.servers"

    init(service: String = KeychainSecretStore.defaultService) {
        self.service = service
    }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    /// True before the phone's first unlock since it was switched on: a login is saved, and the
    /// Keychain won't hand it over yet. False on a phone locked again later, when every item still
    /// reads (`AfterFirstUnlock`), and false with nothing saved.
    var isLockedUntilFirstUnlock: Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecInteractionNotAllowed
    }

    func read(_ key: String) -> String? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult func write(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(key).merging(attributes) { $1 } as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}

final class InMemorySecretStore: SecretStore {
    private(set) var values: [String: String] = [:]

    func read(_ key: String) -> String? { values[key] }
    @discardableResult func write(_ value: String, for key: String) -> Bool {
        values[key] = value
        return true
    }
    func delete(_ key: String) { values[key] = nil }
}

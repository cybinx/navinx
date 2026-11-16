import Foundation
import Security

/// Keeps the app's Keychain to the one service it uses: every generic password under any other
/// service (left by an earlier build) is removed. Nothing is named but the service that stays
/// (D116). Cheap and harmless when there's nothing else, so it runs on every launch.
nonisolated enum KeychainTidy {
    /// Set once an install's first launch has had its look at the Keychain.
    static let installCheckedKey = "keychain_install_checked"

    static func run(keeping service: String = KeychainSecretStore.defaultService, defaults: UserDefaults = .standard) {
        clearIfNewInstall(service: service, defaults: defaults)
        for other in otherServices(in: items(), keeping: service) {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: other,
            ] as CFDictionary)
        }
    }

    /// Keychain items outlive the app, but the profiles in `UserDefaults` don't: after a delete and
    /// reinstall every saved password would stay behind for good. So on an install's first launch,
    /// with no login saved, `service`'s items go. An update from a build without the flag has its
    /// logins saved, so it keeps them. While the Keychain is locked (before the first unlock) it
    /// waits for a later launch.
    static func clearIfNewInstall(service: String, defaults: UserDefaults) {
        guard !defaults.bool(forKey: installCheckedKey) else { return }
        if !ProfileStore.hasLogins(in: defaults) {
            let query = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary
            let status = SecItemDelete(query)
            guard status == errSecSuccess || status == errSecItemNotFound else { return }
        }
        defaults.set(true, forKey: installCheckedKey)
    }

    /// The services in `items` (Keychain attributes) other than `service`; an item without one is left.
    static func otherServices(in items: [[String: Any]], keeping service: String) -> Set<String> {
        Set(items.compactMap { item in
            guard let found = item[kSecAttrService as String] as? String, !found.isEmpty, found != service else {
                return nil
            }
            return found
        })
    }

    /// The attributes of every generic password the app can see (its own).
    private static func items() -> [[String: Any]] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ] as CFDictionary, &result)
        guard status == errSecSuccess else { return [] }
        return result as? [[String: Any]] ?? []
    }
}

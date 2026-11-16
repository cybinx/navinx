import Foundation
import SubsonicKit

/// Saved logins, as the Flutter `StorageService` keeps them: the **active** login (Flutter's
/// `server_config`) and the list of **saved profiles** (`server_profiles`), as JSON in
/// `UserDefaults`, each with its password in the Keychain. The active login is its own slot, so
/// removing it from the saved list doesn't sign out (as in Flutter).
final class ProfileStore {
    private let defaults: UserDefaults
    private let secrets: any SecretStore

    nonisolated private enum Key {
        static let profiles = "server_profiles"
        static let active = "server_config"
        static let coverArtSalt = "subsonic_client_salt"
        static let activePassword = "active"
        static func password(_ id: UUID) -> String { "profile.\(id.uuidString)" }
    }

    init(defaults: UserDefaults = .standard, secrets: any SecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
    }

    /// Whether `defaults` holds a login, active or saved (for `KeychainTidy`'s first-launch check).
    nonisolated static func hasLogins(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: Key.profiles) != nil || defaults.object(forKey: Key.active) != nil
    }

    // MARK: Saved profiles

    var savedProfiles: [ServerProfile] {
        guard let data = defaults.data(forKey: Key.profiles),
              let list = try? JSONDecoder().decode([ServerProfile].self, from: data) else { return [] }
        return list
    }

    /// False when a saved list is there but can't be read, so nothing is taken to be unsaved because of it.
    var canReadSavedProfiles: Bool {
        guard let data = defaults.data(forKey: Key.profiles) else { return true }
        return (try? JSONDecoder().decode([ServerProfile].self, from: data)) != nil
    }

    private func setSavedProfiles(_ list: [ServerProfile]) {
        defaults.set(try? JSONEncoder().encode(list), forKey: Key.profiles)
    }

    func password(for profile: ServerProfile) -> String? {
        secrets.read(Key.password(profile.id))
    }

    /// Adds `profile`, or replaces the saved one with the same ID or the same login (Flutter's
    /// match: address, username, name). Returns it with the ID it's saved under. `byIDOnly` (an edited
    /// login, D139) replaces only the profile with this ID, so it can't take over another saved login.
    @discardableResult
    func save(_ profile: ServerProfile, password: String?, byIDOnly: Bool = false) -> ServerProfile {
        var list = savedProfiles
        var saved = profile
        if let index = list.firstIndex(where: { $0.id == profile.id })
            ?? (byIDOnly ? nil : list.firstIndex(where: { $0.isSameLogin(as: profile) })) {
            saved.id = list[index].id
            list[index] = saved
        } else {
            list.append(saved)
        }
        if let password, !password.isEmpty {
            secrets.write(password, for: Key.password(saved.id))
        }
        setSavedProfiles(list)
        return saved
    }

    /// Replaces the saved profile with this ID (a rename, or a new server type), if it's there.
    func update(_ profile: ServerProfile) {
        var list = savedProfiles
        guard let index = list.firstIndex(where: { $0.id == profile.id }) else { return }
        list[index] = profile
        setSavedProfiles(list)
    }

    func delete(_ profile: ServerProfile) {
        setSavedProfiles(savedProfiles.filter { $0.id != profile.id })
        secrets.delete(Key.password(profile.id))
    }

    // MARK: Active login

    var activeProfile: ServerProfile? {
        guard let data = defaults.data(forKey: Key.active) else { return nil }
        return try? JSONDecoder().decode(ServerProfile.self, from: data)
    }

    var activePassword: String? {
        secrets.read(Key.activePassword)
    }

    func setActive(_ profile: ServerProfile, password: String?) {
        defaults.set(try? JSONEncoder().encode(profile), forKey: Key.active)
        // A failed write mustn't leave the last login's password paired with this profile.
        if let password, !password.isEmpty, !secrets.write(password, for: Key.activePassword) {
            secrets.delete(Key.activePassword)
        }
    }

    func clearActive() {
        defaults.removeObject(forKey: Key.active)
        secrets.delete(Key.activePassword)
    }

    // MARK: Cover-art salt

    /// One salt per install, so a cover keeps one URL (Flutter `getOrCreateSubsonicSalt`).
    var coverArtSalt: String {
        if let salt = defaults.string(forKey: Key.coverArtSalt), !salt.isEmpty { return salt }
        let salt = SubsonicClient.makeCoverArtSalt()
        defaults.set(salt, forKey: Key.coverArtSalt)
        return salt
    }
}

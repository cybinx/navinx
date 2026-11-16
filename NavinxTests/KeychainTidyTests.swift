import Foundation
import Security
import Testing
@testable import Navinx

/// D116: the Keychain keeps only the service the app uses now.
@MainActor @Suite(.serialized) struct KeychainTidyTests {
    private let kept = KeychainSecretStore.defaultService
    private let other = "com.example.tidy-test.other"
    private let account = "tidy-test"

    @Test func onlyOtherServicesAreChosen() {
        let items: [[String: Any]] = [
            [kSecAttrService as String: kept, kSecAttrAccount as String: "a"],
            [kSecAttrService as String: "old.one", kSecAttrAccount as String: "b"],
            [kSecAttrService as String: "old.one", kSecAttrAccount as String: "c"],
            [kSecAttrService as String: "old.two"],
            [kSecAttrService as String: ""],
            [kSecAttrAccount as String: "no service"],
        ]
        #expect(KeychainTidy.otherServices(in: items, keeping: kept) == ["old.one", "old.two"])
        #expect(KeychainTidy.otherServices(in: [], keeping: kept).isEmpty)
    }

    @Test func anItemUnderAnotherServiceGoesAndTheServersStay() {
        let mine = KeychainSecretStore(service: kept)
        let old = KeychainSecretStore(service: other)
        mine.write("keep", for: account)
        old.write("drop", for: account)
        old.write("drop too", for: account + "-2")
        #expect(old.read(account) == "drop", "the simulator's Keychain took the item")

        KeychainTidy.run(defaults: checkedDefaults())

        #expect(old.read(account) == nil)
        #expect(old.read(account + "-2") == nil)
        #expect(mine.read(account) == "keep")
        mine.delete(account)
    }

    /// A reinstall: no login in `UserDefaults`, so the passwords left from before go, once.
    @Test func aNewInstallClearsItsServiceOnce() {
        let store = KeychainSecretStore(service: other)
        store.write("orphan", for: account)
        let defaults = freshDefaults()
        KeychainTidy.clearIfNewInstall(service: other, defaults: defaults)
        #expect(store.read(account) == nil)
        #expect(defaults.bool(forKey: KeychainTidy.installCheckedKey))

        store.write("new", for: account)
        KeychainTidy.clearIfNewInstall(service: other, defaults: defaults)
        #expect(store.read(account) == "new")
        store.delete(account)
    }

    /// An update from a build without the check: its logins are saved, so nothing goes.
    @Test func anUpdateWithLoginsKeepsThem() {
        let store = KeychainSecretStore(service: other)
        store.write("saved", for: account)
        let defaults = freshDefaults()
        ProfileStore(defaults: defaults, secrets: InMemorySecretStore())
            .save(ServerProfile(serverURL: "https://music.example", username: "u"), password: "pw")
        KeychainTidy.clearIfNewInstall(service: other, defaults: defaults)
        #expect(store.read(account) == "saved")
        #expect(defaults.bool(forKey: KeychainTidy.installCheckedKey))
        store.delete(account)
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "KeychainTidyTests.\(UUID().uuidString)")!
    }

    private func checkedDefaults() -> UserDefaults {
        let defaults = freshDefaults()
        defaults.set(true, forKey: KeychainTidy.installCheckedKey)
        return defaults
    }
}

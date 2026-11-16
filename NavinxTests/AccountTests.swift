import Foundation
import Testing
import SubsonicKit
@testable import Navinx

/// A server that answers `ping` per host: "ok" with a type and version (at once, or after 300 ms),
/// wrong password, or down.
private struct StubTransport: HTTPTransport {
    enum Answer: Sendable { case ok, slow, wrongPassword, down }
    let answers: [String: Answer]

    func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let host = url.host() ?? ""
        let body: String
        switch answers[host] ?? .down {
        case .down:
            throw URLError(.cannotConnectToHost)
        case .slow:
            try await Task.sleep(for: .milliseconds(300))
            fallthrough
        case .ok:
            body = #"{"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.64.2","openSubsonic":true}}"#
        case .wrongPassword:
            body = #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":40,"message":"Wrong username or password"}}}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

/// A Keychain that saves nothing.
@MainActor
private final class FailingSecretStore: SecretStore {
    func read(_ key: String) -> String? { nil }
    func write(_ value: String, for key: String) -> Bool { false }
    func delete(_ key: String) {}
}

@MainActor
private func makeStore() -> (ProfileStore, InMemorySecretStore) {
    let defaults = UserDefaults(suiteName: "AccountTests.\(UUID().uuidString)")!
    let secrets = InMemorySecretStore()
    return (ProfileStore(defaults: defaults, secrets: secrets), secrets)
}

@MainActor
private func makeModel(
    _ answers: [String: StubTransport.Answer],
    store: ProfileStore? = nil
) -> (AccountModel, ProfileStore) {
    let store = store ?? makeStore().0
    let model = AccountModel(
        store: store,
        transport: StubTransport(answers: answers),
        verifyAttempts: 3,
        verifyTimeout: .seconds(2),
        retryDelay: .milliseconds(1)
    )
    return (model, store)
}

@MainActor
struct ProfileStoreTests {
    @Test func savesProfilesWithPasswordsInTheSecretStore() {
        let (store, secrets) = makeStore()
        let saved = store.save(ServerProfile(serverURL: "https://a", username: "u"), password: "pw")
        #expect(store.savedProfiles == [saved])
        #expect(store.password(for: saved) == "pw")
        #expect(secrets.values.values.contains("pw"))
    }

    @Test func sameLoginUpdatesInsteadOfAdding() {
        let (store, _) = makeStore()
        let first = store.save(ServerProfile(serverURL: "https://a", username: "u", name: "Home"), password: "1")
        let again = store.save(ServerProfile(serverURL: "https://a", username: "u", name: "Home"), password: "2")
        #expect(again.id == first.id)
        #expect(store.savedProfiles.count == 1)
        #expect(store.password(for: first) == "2")
        // Another name is another profile, as in Flutter.
        store.save(ServerProfile(serverURL: "https://a", username: "u", name: "VPN"), password: "3")
        #expect(store.savedProfiles.count == 2)
    }

    @Test func deleteRemovesThePassword() {
        let (store, secrets) = makeStore()
        let saved = store.save(ServerProfile(serverURL: "https://a", username: "u"), password: "pw")
        store.delete(saved)
        #expect(store.savedProfiles.isEmpty)
        #expect(secrets.values.isEmpty)
    }

    @Test func activeLoginIsItsOwnSlot() {
        let (store, _) = makeStore()
        let profile = store.save(ServerProfile(serverURL: "https://a", username: "u"), password: "pw")
        store.setActive(profile, password: "pw")
        store.delete(profile)
        #expect(store.activeProfile == profile)
        #expect(store.activePassword == "pw")
        store.clearActive()
        #expect(store.activeProfile == nil)
        #expect(store.activePassword == nil)
    }

    @Test func coverArtSaltIsKeptPerInstall() {
        let (store, _) = makeStore()
        let salt = store.coverArtSalt
        #expect(salt.count == 16)
        #expect(store.coverArtSalt == salt)
    }
}

@MainActor
struct AccountModelTests {
    @Test func startsSignedOutWithNoSavedLogin() async {
        let (model, _) = makeModel([:])
        await model.start()
        #expect(model.state == .unauthenticated)
    }

    @Test func loginSavesTheProfileAndSignsIn() async {
        let (model, store) = makeModel(["music.example": .ok])
        let error = await model.login(serverURL: "http://music.example:4533", username: "u", password: "pw")
        #expect(error == nil)
        #expect(model.state == .authenticated)
        #expect(model.client != nil)
        #expect(model.active?.serverType == "navidrome")
        #expect(model.active?.serverVersion == "0.64.2")
        #expect(model.active?.shownServerName == "navidrome")
        #expect(store.activeProfile?.id == model.active?.id)
        #expect(store.activePassword == "pw")
        #expect(model.savedProfiles.map(\.id) == [model.active?.id])
    }

    @Test func wrongPasswordFromTheLoginScreenIsAnError() async {
        let (model, store) = makeModel(["music.example": .wrongPassword])
        let error = await model.login(serverURL: "https://music.example", username: "u", password: "bad")
        #expect(error == "Wrong username or password")
        #expect(model.state == .error)
        #expect(model.error == "Wrong username or password")
        #expect(store.savedProfiles.isEmpty)
        // Navidrome's own wording counts as credentials (Flutter's phrases missed it: generic there).
        #expect(SignInFailure.kind(of: error ?? "") == .credentials)
    }

    /// The login screen has no LAN field: signing in again there keeps the saved LAN address, and
    /// Add Server's field left empty clears it.
    @Test func signingInAgainKeepsTheLANAddressUnlessAddServerClearsIt() async {
        let (model, store) = makeModel(["music.example": .ok])
        await model.login(serverURL: "https://music.example", homeNetworkURL: "http://lan.example:4533", username: "u", password: "pw")
        model.disconnect()
        await model.login(serverURL: "https://music.example", username: "u", password: "pw")
        #expect(model.active?.homeNetworkURL == "http://lan.example:4533")
        #expect(store.savedProfiles.map(\.homeNetworkURL) == ["http://lan.example:4533"])
        await model.login(serverURL: "https://music.example", homeNetworkURL: "", username: "u", password: "pw")
        #expect(model.active?.homeNetworkURL == nil)
        #expect(store.savedProfiles.map(\.homeNetworkURL) == [nil])
    }

    /// A user and password in the address is refused on a new sign-in; one saved that way still works.
    @Test func anAddressWithAUserIsRefusedButASavedOneStillSignsIn() async {
        let (model, store) = makeModel(["music.example": .ok])
        let error = await model.login(serverURL: "https://me:se#cret@music.example", username: "u", password: "pw")
        #expect(error == "Invalid server URL format.")
        #expect(model.state == .error && store.savedProfiles.isEmpty)
        let lan = await model.login(serverURL: "https://music.example", homeNetworkURL: "me:pw@lan.example", username: "u", password: "pw")
        #expect(lan == "Invalid server URL format." && store.savedProfiles.isEmpty)

        let old = store.save(ServerProfile(serverURL: "https://me:pw@music.example", username: "u"), password: "pw")
        store.setActive(old, password: "pw")
        let (fresh, _) = makeModel(["music.example": .ok], store: store)
        await fresh.start()
        #expect(fresh.state == .authenticated && fresh.active?.id == old.id)
    }

    /// A chip tapped while a sign-in is still checking: the slower sign-in, finishing last, doesn't
    /// take over, and isn't saved.
    @Test func aSlowerSignInDoesNotOverwriteANewerSwitch() async throws {
        let (store, _) = makeStore()
        let fast = store.save(ServerProfile(serverURL: "https://fast.example", username: "u"), password: "pw")
        let (model, _) = makeModel(["slow.example": .slow, "fast.example": .ok], store: store)
        let login = Task { await model.login(serverURL: "https://slow.example", username: "u", password: "pw") }
        try await Task.sleep(for: .milliseconds(50))
        await model.switchTo(fast)
        #expect(await login.value == nil)
        #expect(model.state == .authenticated && model.active?.id == fast.id)
        #expect(model.client?.baseURL.host() == "fast.example")
        #expect(store.activeProfile?.id == fast.id)
        #expect(model.savedProfiles.map(\.id) == [fast.id])
    }

    /// The remove alert says the downloads go when `delete` removes them, the active server's too (they go
    /// with its sign-out, D213), and says the active one is signed out of.
    @Test func removingAServerSaysWhenItsDownloadsGo() async {
        let (model, _) = makeModel(["a.example": .ok, "b.example": .ok])
        model.hasDownloads = { _ in true }
        await model.login(serverURL: "https://a.example", username: "u", password: "pw")
        await model.login(serverURL: "https://b.example", username: "u", password: "pw")
        let a = try! #require(model.savedProfiles.first { $0.serverURL == "https://a.example" })
        let b = try! #require(model.active)
        #expect(model.deleteRemovesDownloads(a))
        #expect(model.deleteRemovesDownloads(b))
        #expect(!model.deleteSignsOut(a))
        #expect(model.deleteSignsOut(b))
        model.hasDownloads = { _ in false }
        #expect(!model.deleteRemovesDownloads(a))
    }

    @Test func atMostFiveServersAreSaved() async {
        let (store, _) = makeStore()
        for n in 1...5 { store.save(ServerProfile(serverURL: "https://s\(n).example", username: "u"), password: "pw") }
        let (model, _) = makeModel(["s6.example": .ok, "s3.example": .ok], store: store)
        #expect(!model.canAddServer)
        let refused = await model.login(serverURL: "https://s6.example", username: "u", password: "pw")
        #expect(refused == AccountModel.limitMessage)
        #expect(model.savedProfiles.count == 5 && model.active == nil)
        // Signing in again to a saved one is an update, not an addition.
        let again = await model.login(serverURL: "https://s3.example", username: "u", password: "pw")
        #expect(again == nil && model.savedProfiles.count == 5)
        // Removing one makes room.
        model.delete(model.savedProfiles[0])
        #expect(model.canAddServer)
    }

    @Test func moreThanFiveSavedStayAllKept() {
        let (store, _) = makeStore()
        for n in 1...7 { store.save(ServerProfile(serverURL: "https://s\(n).example", username: "u"), password: "pw") }
        let (model, _) = makeModel([:], store: store)
        #expect(model.savedProfiles.count == 7 && !model.canAddServer)
    }

    @Test func failedAddServerKeepsTheCurrentServerSignedIn() async {
        let (model, _) = makeModel(["home.example": .ok, "other.example": .wrongPassword])
        await model.login(serverURL: "https://home.example", username: "u", password: "pw")
        let home = model.active
        let error = await model.login(serverURL: "https://other.example", username: "u", password: "bad")
        #expect(error == "Wrong username or password")
        #expect(model.state == .authenticated)
        #expect(model.active == home)
        #expect(model.error == nil)
    }

    @Test func savedLoginIsCheckedAtStart() async {
        let (first, store) = makeModel(["music.example": .ok])
        await first.login(serverURL: "https://music.example", username: "u", password: "pw")
        let (model, _) = makeModel(["music.example": .ok], store: store)
        await model.start()
        #expect(model.state == .authenticated)
        #expect(model.active?.serverURL == "https://music.example")
    }

    @Test func unreachableSavedServerAfterThreeTries() async {
        let (first, store) = makeModel(["music.example": .ok])
        await first.login(serverURL: "https://music.example", username: "u", password: "pw")
        let (model, _) = makeModel([:], store: store)
        await model.start()
        #expect(model.state == .serverUnreachable)
        #expect(model.client == nil)
        #expect(model.active != nil)
    }

    @Test func switchingChecksTheOtherServer() async {
        let (model, _) = makeModel(["a.example": .ok, "b.example": .ok])
        await model.login(serverURL: "https://a.example", username: "u", password: "pa")
        await model.login(serverURL: "https://b.example", username: "u", password: "pb")
        let a = try! #require(model.savedProfiles.first { $0.serverURL == "https://a.example" })
        await model.switchTo(a)
        #expect(model.state == .authenticated)
        #expect(model.active?.id == a.id)
        #expect(model.client?.config.password == "pa")
    }

    @Test func logoutKeepsSavedServers() async {
        let (model, store) = makeModel(["music.example": .ok])
        await model.login(serverURL: "https://music.example", username: "u", password: "pw")
        model.logout()
        #expect(model.state == .unauthenticated)
        #expect(model.active == nil)
        #expect(store.activeProfile == nil)
        #expect(model.savedProfiles.count == 1)
        #expect(store.password(for: model.savedProfiles[0]) == "pw")
    }

    @Test func renameRenamesInPlace() async {
        let (model, store) = makeModel(["music.example": .ok])
        await model.login(serverURL: "https://music.example", username: "u", password: "pw")
        let profile = try! #require(model.active)
        model.rename(profile, to: "Home")
        #expect(model.savedProfiles.map(\.name) == ["Home"])
        #expect(model.savedProfiles.map(\.id) == [profile.id])
        #expect(model.active?.name == "Home")
        #expect(store.activeProfile?.name == "Home")
        #expect(store.password(for: model.savedProfiles[0]) == "pw")
    }

    @Test func sameAddressTypedTwoWaysIsOneProfile() async {
        let (store, _) = makeStore()
        // Saved before addresses were stored in one form: it still matches itself.
        let old = store.save(ServerProfile(serverURL: "https://music.example/", username: "u"), password: "pw")
        let (model, _) = makeModel(["music.example": .ok], store: store)
        await model.login(serverURL: "HTTPS://Music.Example//", username: "u", password: "pw")
        await model.login(serverURL: " https://music.example ", username: "u", password: "pw")
        #expect(model.savedProfiles.map(\.id) == [old.id])
        #expect(model.active?.serverURL == "https://music.example")
    }

    @Test func refusedSavedPasswordAsksForItAgain() async {
        let (first, store) = makeModel(["music.example": .ok])
        await first.login(serverURL: "https://music.example", username: "u", password: "old")
        let saved = try! #require(first.active)
        let (model, _) = makeModel(["music.example": .wrongPassword], store: store)
        await model.start()
        #expect(model.state == .error)
        #expect(model.error == "Wrong username or password")
        #expect(model.active == nil && model.client == nil)
        #expect(model.prefill?.id == saved.id)
        // The stored login is left as it was, and signing in again keeps the same profile (and its downloads).
        #expect(store.activeProfile?.id == saved.id)
        let (again, _) = makeModel(["music.example": .ok], store: store)
        await again.login(serverURL: "https://music.example", username: "u", password: "new")
        #expect(again.active?.id == saved.id && store.activePassword == "new")
    }

    @Test func missingPasswordAsksForItAndKeepsTheActivePair() async {
        let (model, store) = makeModel(["a.example": .ok, "b.example": .ok])
        await model.login(serverURL: "https://a.example", username: "u", password: "pa")
        let a = try! #require(model.active)
        // Restored to a new device: the profile is back, its password isn't.
        let b = store.save(ServerProfile(serverURL: "https://b.example", username: "u"), password: nil)
        await model.switchTo(b)
        #expect(model.state == .error)
        #expect(model.error == AccountModel.passwordMissingMessage)
        #expect(model.prefill?.id == b.id && model.active == nil)
        #expect(store.activeProfile?.id == a.id && store.activePassword == "pa")

        // At launch too.
        store.clearActive()
        store.setActive(b, password: nil)
        let (fresh, _) = makeModel([:], store: store)
        await fresh.start()
        #expect(fresh.state == .error && fresh.prefill?.id == b.id)
    }

    @Test func loginFailsWhenThePasswordCannotBeSaved() async {
        let defaults = UserDefaults(suiteName: "AccountTests.\(UUID().uuidString)")!
        let store = ProfileStore(defaults: defaults, secrets: FailingSecretStore())
        let (model, _) = makeModel(["music.example": .ok], store: store)
        let error = await model.login(serverURL: "https://music.example", username: "u", password: "pw")
        #expect(error == AccountModel.passwordNotSavedMessage)
        #expect(model.state == .error && model.active == nil)
    }

    @Test func editingTheAddressKeepsTheSameProfile() async {
        let (model, store) = makeModel(["old.example": .ok, "new.example": .ok])
        await model.login(serverURL: "https://old.example", homeNetworkURL: "http://lan.example", username: "u", password: "pw", profileName: "Home")
        let saved = try! #require(model.active)
        #expect(model.savedPassword(for: saved) == "pw")
        let error = await model.login(
            serverURL: "https://new.example", username: "u", password: "pw", profileName: "Home", replacing: saved
        )
        #expect(error == nil)
        #expect(model.state == .authenticated)
        #expect(model.active?.id == saved.id && model.active?.serverURL == "https://new.example")
        // The LAN address the login screen has no field for stays.
        #expect(model.active?.homeNetworkURL == "http://lan.example")
        #expect(model.savedProfiles.map(\.id) == [saved.id])
        #expect(store.activeProfile?.serverURL == "https://new.example")
        #expect(model.client?.baseURL.host() == "new.example")
    }

    @Test func anEditThatDoesNotAnswerChangesNothing() async {
        let (model, store) = makeModel(["old.example": .ok])
        await model.login(serverURL: "https://old.example", username: "u", password: "pw")
        let saved = try! #require(model.active)
        let error = await model.login(serverURL: "https://gone.example", username: "u", password: "pw", replacing: saved)
        #expect(error != nil)
        #expect(model.state == .authenticated && model.active == saved)
        #expect(store.savedProfiles == [saved] && store.activeProfile == saved)
    }

    @Test func editingToMatchAnotherLoginDoesNotTakeItOver() async {
        let (model, _) = makeModel(["a.example": .ok, "b.example": .ok])
        await model.login(serverURL: "https://a.example", username: "u", password: "pa")
        let a = try! #require(model.active)
        await model.login(serverURL: "https://b.example", username: "u", password: "pb")
        let b = try! #require(model.active)
        await model.login(serverURL: "https://b.example", username: "u", password: "pa", replacing: a)
        #expect(model.active?.id == a.id)
        #expect(Set(model.savedProfiles.map(\.id)) == [a.id, b.id])
        #expect(model.savedPassword(for: b) == "pb")
    }

    /// The re-check, item 15: a refused login, then another server typed on the login screen: a login of
    /// its own, and the refused one's saved entry stays. At its own address it's still that profile (D139).
    @Test func aRefusedLoginThenAnotherServerLeavesTheRefusedOneSaved() async {
        let (first, store) = makeModel(["old.example": .ok])
        await first.login(serverURL: "https://old.example", username: "u", password: "pw")
        let saved = try! #require(first.active)
        let (model, _) = makeModel(["old.example": .wrongPassword, "new.example": .ok], store: store)
        await model.start()
        let prefill = try! #require(model.prefill)
        // The login screen is filled in with everything, the password too.
        #expect(model.savedPassword(for: prefill) == "pw")
        #expect(AccountModel.replaced(editing: nil, prefill: prefill, serverURL: "HTTPS://old.example/", username: " U ")?.id == saved.id)
        let replacing = AccountModel.replaced(editing: nil, prefill: prefill, serverURL: "https://new.example", username: "u")
        #expect(replacing == nil)
        await model.login(serverURL: "https://new.example", username: "u", password: "pw", replacing: replacing)
        #expect(model.state == .authenticated && model.active?.id != saved.id)
        #expect(Set(store.savedProfiles.map(\.serverURL)) == ["https://old.example", "https://new.example"])
        #expect(store.password(for: saved) == "pw")
        // Edit Server keeps its own rule: the edited login, whatever address was typed.
        #expect(AccountModel.replaced(editing: saved, prefill: nil, serverURL: "https://new.example", username: "v")?.id == saved.id)
    }

    /// A refused login, then another account at the same address typed on the login screen: a login of its
    /// own, and the refused one's saved entry, ID and password stay.
    @Test func aRefusedLoginThenAnotherUsernameAtItsAddressLeavesTheRefusedOneSaved() async {
        let (first, store) = makeModel(["old.example": .ok])
        await first.login(serverURL: "https://old.example", username: "u", password: "pw")
        let saved = try! #require(first.active)
        let (refused, _) = makeModel(["old.example": .wrongPassword], store: store)
        await refused.start()
        let prefill = try! #require(refused.prefill)
        let replacing = AccountModel.replaced(editing: nil, prefill: prefill, serverURL: "https://old.example", username: "v")
        #expect(replacing == nil)
        // The other account's password is right (a server that answers it).
        let (model, _) = makeModel(["old.example": .ok], store: store)
        await model.login(serverURL: "https://old.example", username: "v", password: "pv", replacing: replacing)
        #expect(model.state == .authenticated && model.active?.id != saved.id)
        #expect(Set(store.savedProfiles.map(\.username)) == ["u", "v"])
        #expect(store.savedProfiles.contains { $0.id == saved.id && $0.username == "u" })
        #expect(store.password(for: saved) == "pw")
    }

    /// D213: removing the server signed in to signs out of it (as Sign Out: its downloads and key go) and
    /// it's gone from the list; the other saved server and its password stay.
    @Test func removingTheActiveServerSignsOutAndRemovesIt() async {
        let (store, _) = makeStore()
        let (model, _) = makeModel(["a.example": .ok, "b.example": .ok], store: store)
        var removed: [String] = []
        var forgotten: [UUID] = []
        model.removeDownloads = { removed.append($0) }
        model.forgetKey = { forgotten.append($0) }
        await model.login(serverURL: "https://a.example", username: "u", password: "pw-a")
        await model.login(serverURL: "https://b.example", username: "u", password: "pw-b")
        let a = try! #require(model.savedProfiles.first { $0.serverURL == "https://a.example" })
        let b = try! #require(model.active)
        model.delete(b)
        #expect(model.state == .unauthenticated && model.active == nil)
        #expect(model.savedProfiles.map(\.id) == [a.id])
        #expect(model.switcherProfiles.map(\.id) == [a.id])
        #expect(removed == [b.id.uuidString] && forgotten == [b.id])
        #expect(store.activeProfile == nil && store.activePassword == nil)
        #expect(store.password(for: b) == nil)
        #expect(store.password(for: a) == "pw-a")
    }
}

struct ServerProfileTests {
    @Test func displayNames() {
        var profile = ServerProfile(serverURL: "http://music.example:4533", username: "u")
        #expect(profile.shownServerName == "Navidrome / Subsonic")
        #expect(profile.displayURL == "music.example")
        #expect(profile.chipLabel == "u@music.example")
        profile.serverType = "navidrome"
        #expect(profile.shownServerName == "navidrome")
        profile.name = "  Home "
        #expect(profile.shownServerName == "Home")
        #expect(ServerProfile(serverURL: "", username: "u").displayURL == "Not configured")
    }
}

struct SignInFailureTests {
    @Test func messagesMatchFlutter() {
        #expect(SignInFailure.message(for: SubsonicError.cannotConnect)
            == "Cannot connect to server. Check the URL and your internet connection.")
        #expect(SignInFailure.message(for: SubsonicError.timedOut) == "Connection timed out. Check your server URL.")
        #expect(SignInFailure.message(for: SubsonicError.unauthorized) == "Invalid username or password.")
        #expect(SignInFailure.message(for: SubsonicError.notFound) == "Server not found. Check your URL path.")
        #expect(SignInFailure.message(for: SubsonicError.certificate) == "SSL certificate error. Check the server's certificate.")
        #expect(SignInFailure.message(for: SubsonicError.api(code: 40, message: "Wrong username or password"))
            == "Wrong username or password")
        #expect(SignInFailure.message(for: SubsonicError.invalidURL) == "Invalid server URL format.")
        #expect(SignInFailure.message(for: SubsonicError.forbidden)
            == "Access denied (HTTP 403). The server or its proxy refused the request.")
        #expect(SignInFailure.message(for: SubsonicError.secureConnection)
            == "Could not make a secure connection. Check whether the server uses https.")
        #expect(SignInFailure.kind(of: "Invalid server URL format.") == .format)
        #expect(SignInFailure.format("Exception: Something odd") == "Something odd")
    }

    /// Flutter's categories, except Navidrome's "Wrong username or password" (credentials here) and
    /// HTTP statuses, which Flutter's "http" phrase gave the address hint.
    @Test func kindsMatchFlutter() {
        #expect(SignInFailure.kind(of: "Cannot connect to server. Check the URL and your internet connection.") == .connection)
        #expect(SignInFailure.kind(of: "Connection timed out. Check your server URL.") == .timeout)
        #expect(SignInFailure.kind(of: "Invalid username or password.") == .credentials)
        #expect(SignInFailure.kind(of: "Server not found. Check your URL path.") == .notFound)
        #expect(SignInFailure.kind(of: "SSL certificate error. Check the server's certificate.") == .ssl)
        #expect(SignInFailure.kind(of: "Request failed (HTTP 418).") == .generic)
        #expect(SignInFailure.kind(of: "Access denied (HTTP 403). The server or its proxy refused the request.") == .generic)
        #expect(SignInFailure.kind(of: "Wrong username or password") == .credentials)
        #expect(SignInFailure.kind(of: "Could not make a secure connection. Check whether the server uses https.") == .ssl)
        #expect(SignInFailure.kind(of: "URL must start with http:// or https://") == .format)
        #expect(SignInFailure.kind(of: "Something odd") == .generic)
        #expect(SignInFailure.Kind.ssl.hint == nil)
    }

    @Test(arguments: [
        ("http://music.example.com", true),
        ("https://music.example.com", false),
        ("http://localhost:4533", false),
        ("http://nas.local:4533", false),
        ("http://192.168.0.2:4533", false),
        ("http://10.0.0.2", false),
        ("http://172.16.0.2", false),
        ("http://172.32.0.2", true),
    ])
    func insecureHTTPWarning(url: String, warns: Bool) {
        #expect(SignInFailure.isPlainHTTPOffNetwork(url) == warns)
    }
}

/// A server that's down until told otherwise (C10's way back online), and then may refuse the
/// password; it counts the requests. With `lanHost`, that host answers only while the LAN is up.
private final class FlakyTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var isUp = false
    private var refuses = false
    private var isLANUp = false
    private var count = 0
    private let lanHost: String?

    init(lanHost: String? = nil) { self.lanHost = lanHost }

    func setUp(_ up: Bool, refusing: Bool = false) { lock.withLock { isUp = up; refuses = refusing } }
    func setLANUp(_ up: Bool) { lock.withLock { isLANUp = up } }
    var requestCount: Int { lock.withLock { count } }

    func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let isLAN = lanHost != nil && url.host() == lanHost
        let (up, refusing) = lock.withLock {
            count += 1
            return (isLAN ? isLANUp : isUp, refuses)
        }
        guard up else { throw URLError(.cannotConnectToHost) }
        let body = refusing
            ? #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":40,"message":"Wrong username or password"}}}"#
            : #"{"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.64.2"}}"#
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// C10: offline mode, Logout and Disconnect.
@MainActor
struct AccountOfflineTests {
    private func signedIn(_ transport: some HTTPTransport, store: ProfileStore, reconnect: Duration = .seconds(60)) async -> AccountModel {
        let model = AccountModel(store: store, transport: transport, verifyAttempts: 1, verifyTimeout: .seconds(2), retryDelay: .milliseconds(1), reconnectInterval: reconnect)
        return model
    }

    @Test func offlineModeIsOfferedWhenTheServerHasDownloads() async {
        let (store, _) = makeStore()
        let profile = store.save(ServerProfile(serverURL: "https://music.example", username: "u"), password: "pw")
        store.setActive(profile, password: "pw")
        let model = await signedIn(FlakyTransport(), store: store)
        model.hasDownloads = { $0 == profile.id.uuidString }
        await model.start()
        #expect(model.state == .serverUnreachable)
        #expect(model.hasAnythingOffline)
        model.switchToOffline()
        #expect(model.isOffline)
        #expect(model.client == nil)
    }

    @Test func offlineModeChosenWhileConnectingStays() async throws {
        let (store, _) = makeStore()
        let profile = store.save(ServerProfile(serverURL: "https://music.example", username: "u"), password: "pw")
        store.setActive(profile, password: "pw")
        let model = AccountModel(store: store, transport: FlakyTransport(), verifyAttempts: 3, verifyTimeout: .seconds(2), retryDelay: .milliseconds(100))
        model.hasDownloads = { _ in true }
        let starting = Task { await model.start() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.state == .authenticating)
        model.switchToOffline()
        await starting.value
        #expect(model.state == .offlineMode)
    }

    @Test func offlineModeGoesBackOnlineByItself() async throws {
        let (store, _) = makeStore()
        let profile = store.save(ServerProfile(serverURL: "https://music.example", username: "u"), password: "pw")
        store.setActive(profile, password: "pw")
        let transport = FlakyTransport()
        let model = await signedIn(transport, store: store, reconnect: .milliseconds(50))
        model.hasDownloads = { _ in true }
        await model.start()
        model.switchToOffline()
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.isOffline)
        transport.setUp(true)
        for _ in 0..<100 where model.state != .authenticated { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.state == .authenticated)
        #expect(model.client != nil)
    }

    /// A password the server refuses while offline: the tries stop, the user stays offline and is
    /// told once.
    @Test func aRefusedPasswordWhileOfflineStopsTheTriesAndSaysSoOnce() async throws {
        let (store, _) = makeStore()
        let profile = store.save(ServerProfile(serverURL: "https://music.example", username: "u"), password: "pw")
        store.setActive(profile, password: "pw")
        let transport = FlakyTransport()
        let model = await signedIn(transport, store: store, reconnect: .milliseconds(50))
        model.hasDownloads = { _ in true }
        var messages: [String] = []
        model.onMessage = { messages.append($0) }
        await model.start()
        model.switchToOffline()
        transport.setUp(true, refusing: true)
        for _ in 0..<100 where messages.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(messages == [AccountModel.passwordRefusedOfflineMessage])
        let count = transport.requestCount
        try await Task.sleep(for: .milliseconds(300))
        #expect(transport.requestCount == count)
        #expect(model.isOffline && messages.count == 1)
    }

    /// The network changed: the LAN address is chosen again without a reconnect, both ways.
    @Test func aNetworkChangeChoosesTheAddressAgain() async {
        let (store, _) = makeStore()
        let profile = store.save(
            ServerProfile(serverURL: "https://music.example", homeNetworkURL: "http://lan.example:4533", username: "u"), password: "pw"
        )
        store.setActive(profile, password: "pw")
        let transport = FlakyTransport(lanHost: "lan.example")
        transport.setUp(true)
        transport.setLANUp(true)
        let model = await signedIn(transport, store: store)
        await model.start()
        #expect(model.client?.baseURL.host() == "lan.example")
        transport.setLANUp(false)
        await model.chooseAddressAgain()
        #expect(model.state == .authenticated && model.client?.baseURL.host() == "music.example")
        transport.setLANUp(true)
        await model.chooseAddressAgain()
        #expect(model.client?.baseURL.host() == "lan.example")
    }

    /// Add Server from offline mode: online on the new server, with its client.
    @Test func addServerWhileOfflineGoesOnline() async {
        let (store, _) = makeStore()
        let home = store.save(ServerProfile(serverURL: "https://home.example", username: "u"), password: "pw")
        store.setActive(home, password: "pw")
        let model = AccountModel(store: store, transport: StubTransport(answers: ["other.example": .ok]), verifyAttempts: 1, verifyTimeout: .seconds(2), retryDelay: .milliseconds(1))
        model.hasDownloads = { _ in true }
        await model.start()
        model.switchToOffline()
        #expect(model.isOffline)
        let error = await model.login(serverURL: "https://other.example", username: "u", password: "pw")
        #expect(error == nil)
        #expect(model.state == .authenticated && !model.isOffline)
        #expect(model.active?.id != home.id)
        #expect(model.client?.baseURL.host() == "other.example")
    }

    @Test func logoutDeletesThisServersDownloadsAndDisconnectKeepsThem() async {
        let (model, _) = makeModel(["music.example": .ok])
        var removed: [String] = []
        model.removeDownloads = { removed.append($0) }
        await model.login(serverURL: "https://music.example", username: "u", password: "pw")
        let id = try! #require(model.active).id.uuidString
        model.disconnect()
        #expect(model.state == .unauthenticated)
        #expect(removed.isEmpty)

        await model.login(serverURL: "https://music.example", username: "u", password: "pw")
        model.logout()
        #expect(removed == [id])
    }
}

/// `ping` ok everywhere but where told to refuse; `getUser` says administrator for the username "boss".
private struct AccountsTransport: HTTPTransport {
    var refusing: Set<String> = []

    func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let host = url.host() ?? ""
        let body: String
        if refusing.contains(host) {
            body = #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":40,"message":"Wrong username or password"}}}"#
        } else if url.lastPathComponent == "getUser" {
            let admin = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .contains { $0.name == "username" && $0.value == "boss" } ?? false
            body = #"{"subsonic-response":{"status":"ok","version":"1.16.1","user":{"username":"x","adminRole":\#(admin)}}}"#
        } else {
            body = #"{"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.64.2"}}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// The re-check of 2026-11-15, items 10, 16, 17 and 18.
@MainActor
struct AccountRecheckTests {
    private func makeAccount(_ transport: some HTTPTransport, store: ProfileStore) -> AccountModel {
        AccountModel(store: store, transport: transport, verifyAttempts: 1, verifyTimeout: .seconds(2), retryDelay: .milliseconds(1))
    }

    /// Item 10: a music server at the home-network address that refuses the login, on another network:
    /// the main address takes it, and the home one isn't used again for this session.
    @Test func aHomeAddressThatRefusesTheLoginFallsBackToTheMainOne() async {
        let (store, _) = makeStore()
        let model = makeAccount(AccountsTransport(refusing: ["lan.example"]), store: store)
        let failure = await model.login(
            serverURL: "https://music.example", homeNetworkURL: "http://lan.example:4533", username: "u", password: "pw"
        )
        #expect(failure == nil)
        #expect(model.state == .authenticated)
        #expect(model.client?.baseURL.host() == "music.example")
        // The saved login keeps its home-network address for the next session.
        #expect(model.active?.homeNetworkURL == "http://lan.example:4533")
        await model.chooseAddressAgain()
        #expect(model.client?.baseURL.host() == "music.example")
    }

    /// Item 10: the main address refuses too: the password really is wrong.
    @Test func bothAddressesRefusingIsAWrongPassword() async {
        let (store, _) = makeStore()
        let model = makeAccount(AccountsTransport(refusing: ["lan.example", "music.example"]), store: store)
        let failure = await model.login(
            serverURL: "https://music.example", homeNetworkURL: "http://lan.example:4533", username: "u", password: "pw"
        )
        #expect(failure == SignInFailure.message(for: SubsonicError.api(code: 40, message: "Wrong username or password")))
        #expect(model.state == .error)
    }

    /// Item 16: Add Server's sign-in, overtaken by a switch, says it was superseded, not that it worked.
    @Test func aSupersededSignInIsNotReportedAsDone() async throws {
        let (store, _) = makeStore()
        let model = AccountModel(
            store: store, transport: StubTransport(answers: ["home.example": .ok, "slow.example": .slow]),
            verifyAttempts: 1, verifyTimeout: .seconds(2), retryDelay: .milliseconds(1)
        )
        #expect(await model.signIn(serverURL: "https://home.example", username: "u", password: "pw") == .done)
        let home = try #require(model.active)
        let adding = Task { await model.signIn(serverURL: "https://slow.example", username: "u", password: "pw") }
        try await Task.sleep(for: .milliseconds(50))
        await model.switchTo(home)
        #expect(await adding.value == .superseded)
        #expect(model.active?.id == home.id)
        #expect(model.savedProfiles.map(\.id) == [home.id])
    }

    /// Item 17: Edit Server changes the account behind the same profile: the flag is asked again.
    @Test func theAdminFlagIsAskedAgainAfterAnEdit() async throws {
        let (store, _) = makeStore()
        let model = makeAccount(AccountsTransport(), store: store)
        await model.login(serverURL: "https://music.example", username: "boss", password: "pw")
        let profile = try #require(model.active)
        #expect(await model.isAdmin())
        await model.login(serverURL: "https://music.example", username: "guest", password: "pw", replacing: profile)
        #expect(model.active?.id == profile.id)
        #expect(!(await model.isAdmin()))
    }

    /// Item 18: Disconnect from a server already removed from the saved list: it goes back on the list, so
    /// its downloads are still wanted and the next sign-in is the same profile.
    @Test func disconnectKeepsAnUnsavedServersDownloads() async throws {
        let (store, _) = makeStore()
        let model = makeAccount(AccountsTransport(), store: store)
        var removed: [String] = []
        model.removeDownloads = { removed.append($0) }
        await model.login(serverURL: "https://music.example", username: "u", password: "pw")
        let profile = try #require(model.active)
        // Off the saved list while still signed in (`delete` signs out of it since D213).
        store.delete(profile)
        #expect(store.savedProfiles.isEmpty)
        model.disconnect()
        #expect(model.state == .unauthenticated)
        #expect(removed.isEmpty)
        #expect(model.savedProfiles.map(\.id) == [profile.id])
        #expect(store.password(for: profile) == "pw")
        await model.login(serverURL: "https://music.example", username: "u", password: "pw")
        #expect(model.active?.id == profile.id)
        #expect(model.profilesWithDownloads?.contains(profile.id.uuidString) == true)
    }
}

/// The main address always takes the login; the home-network one is down, refuses the login (another
/// music server at that private address), or takes it.
private final class HomeAddressTransport: HTTPTransport, @unchecked Sendable {
    enum Home { case down, refusing, ok }
    private let lock = NSLock()
    private var home = Home.down
    private var homeCount = 0

    func set(_ home: Home) { lock.withLock { self.home = home } }
    var homeRequests: Int { lock.withLock { homeCount } }

    func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        var answer = Home.ok
        if url.host() == "lan.example" {
            answer = lock.withLock {
                homeCount += 1
                return home
            }
        }
        let body: String
        switch answer {
        case .down: throw URLError(.cannotConnectToHost)
        case .refusing: body = #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":40,"message":"Wrong username or password"}}}"#
        case .ok: body = #"{"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.64.2"}}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// The audit after C55, items A2 and A3.
@MainActor
struct AccountAuditTests {
    /// A2: after a network change, a home-network address that answers the unsigned probe but refuses the
    /// login isn't switched to; the main address alone is used from then on.
    @Test func aNetworkChangeDoesntSwitchToAHomeAddressThatRefusesTheLogin() async {
        let (store, _) = makeStore()
        let profile = store.save(
            ServerProfile(serverURL: "https://music.example", homeNetworkURL: "http://lan.example:4533", username: "u"), password: "pw"
        )
        store.setActive(profile, password: "pw")
        let transport = HomeAddressTransport()
        let model = AccountModel(store: store, transport: transport, verifyAttempts: 1, verifyTimeout: .seconds(2), retryDelay: .milliseconds(1))
        await model.start()
        #expect(model.client?.baseURL.host() == "music.example")
        #expect(model.client?.config.homeNetworkURL != nil)

        transport.set(.refusing)
        await model.chooseAddressAgain()
        #expect(model.state == .authenticated)
        #expect(model.client?.baseURL.host() == "music.example")
        #expect(model.client?.config.homeNetworkURL == nil)
        // Nothing goes to the home address again with this client, even once it would take the login.
        transport.set(.ok)
        let asked = transport.homeRequests
        await model.chooseAddressAgain()
        #expect(model.client?.baseURL.host() == "music.example")
        #expect(transport.homeRequests == asked)
    }

    /// A2: a home-network address that takes the login is switched to, as before.
    @Test func aNetworkChangeSwitchesToAHomeAddressThatTakesTheLogin() async {
        let (store, _) = makeStore()
        let profile = store.save(
            ServerProfile(serverURL: "https://music.example", homeNetworkURL: "http://lan.example:4533", username: "u"), password: "pw"
        )
        store.setActive(profile, password: "pw")
        let transport = HomeAddressTransport()
        let model = AccountModel(store: store, transport: transport, verifyAttempts: 1, verifyTimeout: .seconds(2), retryDelay: .milliseconds(1))
        await model.start()
        transport.set(.ok)
        await model.chooseAddressAgain()
        #expect(model.client?.baseURL.host() == "lan.example")
    }

    /// A3: removing, from the login screen, the server still stored as the signed-in login clears that
    /// slot too, so the next launch doesn't sign back in to it.
    @Test func removingTheStoredLoginFromTheLoginScreenClearsIt() async {
        let (store, _) = makeStore()
        let profile = store.save(ServerProfile(serverURL: "https://music.example", username: "u"), password: "pw")
        store.setActive(profile, password: "pw")
        // The saved password refused at launch: the login screen, nobody signed in, the slot kept.
        let (model, _) = makeModel(["music.example": .wrongPassword], store: store)
        await model.start()
        #expect(model.active == nil && model.state == .error)
        #expect(store.activeProfile?.id == profile.id)
        model.delete(profile)
        #expect(store.activeProfile == nil)
        #expect(store.activePassword == nil)
        #expect(model.savedProfiles.isEmpty)
        let (next, _) = makeModel(["music.example": .ok], store: store)
        await next.start()
        #expect(next.state == .unauthenticated)
    }

    /// A3: another saved server removed there leaves the stored login alone.
    @Test func removingAnotherServerKeepsTheStoredLogin() async {
        let (store, _) = makeStore()
        let profile = store.save(ServerProfile(serverURL: "https://music.example", username: "u"), password: "pw")
        let other = store.save(ServerProfile(serverURL: "https://other.example", username: "u"), password: "pw")
        store.setActive(profile, password: "pw")
        let (model, _) = makeModel(["music.example": .wrongPassword], store: store)
        await model.start()
        model.delete(other)
        #expect(store.activeProfile?.id == profile.id)
    }
}

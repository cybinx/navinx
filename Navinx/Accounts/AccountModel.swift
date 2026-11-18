import DeviceIdentity
import Foundation
import Observation
import SubsonicKit

/// The signed-in server and the app's connection state: the Flutter `AuthProvider`
/// (`lib/providers/auth_provider.dart`), Subsonic only. `RootView` shows a screen per `State`,
/// as Flutter's `AuthWrapper` does.
@Observable
final class AccountModel {
    enum State: Equatable {
        /// Before `start()` has read the saved login.
        case unknown
        case unauthenticated
        /// Logging in, or checking the saved server.
        case authenticating
        case authenticated
        /// Browsing downloads without the server (C10).
        case offlineMode
        /// The saved server didn't answer `ping` (after three tries).
        case serverUnreachable
        /// The last login failed; `error` says why.
        case error
    }

    private(set) var state: State = .unknown
    /// Why the last login from the login screen failed.
    private(set) var error: String?
    /// The signed-in profile (Flutter's `config`). Every connection presents its device certificate at
    /// its main address, where it has one (C45).
    private(set) var active: ServerProfile? {
        didSet {
            guard active != oldValue else { return }
            devices?.certificates?.use(profile: active?.id, server: active.flatMap(Self.mainAddress))
        }
    }
    /// A server that approves each device (C45): its screens, shown over everything while they're up.
    private(set) var approval: DeviceEnrolment?
    /// The client for the signed-in server, once it has answered.
    private(set) var client: SubsonicClient?
    private(set) var savedProfiles: [ServerProfile] = []
    /// The login the login screen fills in: one whose saved password was refused or isn't here.
    private(set) var prefill: ServerProfile?
    /// True when the server has downloads, so the connecting and unreachable screens offer offline mode.
    private(set) var hasAnythingOffline = false
    /// Browsing downloads with no server (Flutter `AuthState.offlineMode`).
    var isOffline: Bool { state == .offlineMode }
    /// The signed-in server, or before `start()` the one saved as signed in (Siri's and Shortcuts'
    /// look at the saved library, which mustn't sign in, C39).
    var storedProfileID: UUID? { active?.id ?? (state == .unknown ? store.activeProfile?.id : nil) }

    /// Downloads (C10): whether a server (by profile ID) has any, and deleting them on logout.
    @ObservationIgnored var hasDownloads: (String) -> Bool = { _ in false }
    @ObservationIgnored var removeDownloads: (String) -> Void = { _ in }
    /// A message for the user that no screen shows: a toast (the server refusing the password in
    /// offline mode).
    @ObservationIgnored var onMessage: (String) -> Void = { _ in }
    /// Every sign-out (the hub's session ends), and a profile's own key, removed with its downloads.
    @ObservationIgnored var onSignOut: () -> Void = {}
    @ObservationIgnored var forgetKey: (UUID) -> Void = { _ in }

    private let store: ProfileStore
    private let transport: any HTTPTransport
    /// Nil: no server is ever asked whether it approves devices (the tests that don't say otherwise).
    private let devices: DeviceServices?
    /// What follows the approval screens: the sign-in finishing, or tried again.
    @ObservationIgnored private var afterApproval: (() async -> Void)?
    /// The sessions of the sign-in check the approval screens follow (`LoginSessions`), kept until they close;
    /// nil for screens over the shared sessions (a saved login checked at launch, already signed in).
    @ObservationIgnored private var approvalSessions: LoginSessions?
    private let verifyAttempts: Int
    private let verifyTimeout: Duration
    private let retryDelay: Duration
    private let reconnectInterval: Duration
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var networkCheck: Task<Void, Never>?
    /// Bumped by every sign-in, switch, check and sign-out: only the newest applies what it finds, so
    /// a slower one finishing late doesn't overwrite a faster one.
    @ObservationIgnored private var generation = 0
    /// Sign-ins from a form still checking (Add Server's keep the state `authenticated` meanwhile).
    @ObservationIgnored private var loginsInFlight = 0

    /// Flutter `_verifyConnection`: three pings, 10 s each, 2 s apart.
    init(
        store: ProfileStore = ProfileStore(),
        transport: any HTTPTransport = URLSessionTransport(),
        verifyAttempts: Int = 3,
        verifyTimeout: Duration = .seconds(10),
        retryDelay: Duration = .seconds(2),
        reconnectInterval: Duration = .seconds(10),
        devices: DeviceServices? = nil
    ) {
        self.store = store
        self.transport = transport
        self.devices = devices
        self.verifyAttempts = verifyAttempts
        self.verifyTimeout = verifyTimeout
        self.retryDelay = retryDelay
        self.reconnectInterval = reconnectInterval
        savedProfiles = store.savedProfiles
    }

    // MARK: Start-up

    /// Reads the saved login and checks the server (Flutter `_loadSavedConfig`).
    func start() async {
        guard state == .unknown else { return }
        let ticket = nextGeneration()
        adoptDeviceOrigins()
        guard let profile = store.activeProfile else {
            state = .unauthenticated
            return
        }
        guard let password = store.activePassword, !password.isEmpty else {
            askForPassword(profile, message: Self.passwordMissingMessage)
            return
        }
        guard profile.config(password: password).isValid else {
            state = .unauthenticated
            return
        }
        active = profile
        // Known before the check, so the connecting screen can offer offline mode too.
        hasAnythingOffline = hasDownloads(profile.id.uuidString)
        await connectAndVerify(profile, password: password, ticket: ticket)
    }

    /// The unreachable screen's Retry (Flutter `retryConnection`).
    func retry() async {
        guard let active else { return }
        let ticket = nextGeneration()
        guard let password = store.activePassword, !password.isEmpty else {
            askForPassword(active, message: Self.passwordMissingMessage)
            return
        }
        await connectAndVerify(active, password: password, ticket: ticket)
    }

    private func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    /// Flutter `enterOfflineMode`. Unlike Flutter, which stays offline until relaunched, it goes back
    /// online by itself once the server answers again, as Apple Music does (C10).
    func switchToOffline() {
        guard let active else { return }
        state = .offlineMode
        client = nil
        reconnectTask?.cancel()
        let password = store.activePassword ?? ""
        let interval = reconnectInterval
        reconnectTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled, self.state == .offlineMode, self.active?.id == active.id else { return }
                if await self.reconnect(active, password: password) { return }
            }
        }
    }

    /// One quiet try at the server, from offline mode. True when the tries stop: back online, or
    /// the password was refused, which asking again every 10 s won't change.
    private func reconnect(_ profile: ServerProfile, password: String) async -> Bool {
        let ticket = generation
        let config = profile.config(password: password)
        let salt = store.coverArtSalt
        let client: SubsonicClient
        do {
            (client, _) = try await withTimeout(verifyTimeout) { [transport] in
                try await SubsonicClient.connectAndPing(config: config, coverArtSalt: salt, transport: transport)
            }
        } catch let error as SubsonicError where error.isAuthenticationFailure {
            guard ticket == generation, state == .offlineMode, active?.id == profile.id else { return false }
            passwordRefusedWhileOffline()
            return true
        } catch {
            return false
        }
        guard ticket == generation, state == .offlineMode, active?.id == profile.id else { return false }
        self.client = client
        state = .authenticated
        renewCertificateIfDue(profile, password: password)
        return true
    }

    /// The server refused the saved password while offline: the user stays offline, with the
    /// downloads, and is told once. The next launch checks again and asks for the password.
    private func passwordRefusedWhileOffline() {
        reconnectTask?.cancel()
        onMessage(Self.passwordRefusedOfflineMessage)
    }

    // MARK: Logging in

    /// Flutter `login`: pings the server and, if it answers, signs in to it and saves it as a
    /// profile. Returns the error message on failure.
    ///
    /// From the login screen (nobody signed in) the state goes `authenticating` and then `error`
    /// on failure, as in Flutter. With someone signed in (Add Server), a failure leaves the
    /// current server signed in; Flutter dropped to the login screen there (the user's call, C2).
    ///
    /// `replacing` (D139): the login screen opened for a saved login, to edit it (Edit Server) or
    /// because its password was refused or is missing. Whatever was changed, the address too, it stays
    /// that profile (its ID, so its downloads, caches and LAN address), and is signed in once it answers.
    /// A device approval doesn't follow the main address to a new one (C49): it goes once the edit is saved.
    /// (The login screen passes a refused or missing login only for its own address and username: `replaced(editing:…)`.)
    @discardableResult
    func login(
        serverURL: String,
        homeNetworkURL: String? = nil,
        username: String,
        password: String,
        sendsPlainPassword: Bool = false,
        profileName: String? = nil,
        replacing: ServerProfile? = nil
    ) async -> String? {
        let outcome = await signIn(
            serverURL: serverURL, homeNetworkURL: homeNetworkURL, username: username, password: password,
            sendsPlainPassword: sendsPlainPassword, profileName: profileName, replacing: replacing
        )
        if case .failed(let message) = outcome { return message }
        return nil
    }

    /// How a sign-in from a form ended.
    enum SignInOutcome: Equatable {
        /// Signed in, or the device approval's screens are up (`approval`).
        case done
        case failed(String)
        /// A newer sign-in, switch or sign-out took over, or the sign-in was cancelled: nothing was signed
        /// in, and nothing failed either (the re-check, item 16: Add Server mustn't say "Connected").
        case superseded
    }

    /// `login`, telling a superseded sign-in from one that worked.
    func signIn(
        serverURL: String,
        homeNetworkURL: String? = nil,
        username: String,
        password: String,
        sendsPlainPassword: Bool = false,
        profileName: String? = nil,
        replacing: ServerProfile? = nil
    ) async -> SignInOutcome {
        let signedIn = active != nil
        // The username and password have their own fields: in the address they'd be saved and shown with it.
        if ServerConfig.hasUserInfo(serverURL) || homeNetworkURL.map(ServerConfig.hasUserInfo) == true {
            let message = SignInFailure.message(for: SubsonicError.invalidURL)
            if !signedIn { error = message; state = .error }
            return .failed(message)
        }
        // One form per address, so "https://host/" and "HTTPS://host" are one profile, not two of the five.
        let address = ServerConfig.normalize(serverURL, defaultScheme: "https")
        let candidate = ServerProfile(serverURL: address, homeNetworkURL: homeNetworkURL, username: username, name: profileName)
        // A new login at the limit is refused; signing in again to a saved one just updates it.
        if replacing == nil, !canAddServer, !switcherProfiles.contains(where: { $0.isSameLogin(as: candidate) }) {
            if !signedIn { error = Self.limitMessage; state = .error }
            return .failed(Self.limitMessage)
        }
        let ticket = nextGeneration()
        loginsInFlight += 1
        defer { loginsInFlight -= 1 }
        // A device record kept before C49 is stamped with the address it was made at before anything compares.
        if let replacing { adoptDeviceOrigin(replacing) }
        if !signedIn {
            state = .authenticating
            error = nil
        }
        // The login screen has no LAN field (nil): signing in again to a saved login keeps its LAN
        // address. Add Server has one, and sends "" when it's left empty, which clears it.
        let lan: String?
        if let homeNetworkURL {
            lan = homeNetworkURL.trimmingCharacters(in: .whitespaces).isEmpty ? nil : homeNetworkURL
        } else if let replacing {
            lan = replacing.homeNetworkURL
        } else {
            lan = ([prefill, active].compactMap { $0 } + savedProfiles)
                .first { $0.isSameLogin(as: candidate) }?.homeNetworkURL
        }
        var profile = ServerProfile(
            serverURL: address,
            homeNetworkURL: lan,
            username: username,
            sendsPlainPassword: sendsPlainPassword,
            name: profileName
        )
        // The active server may have been removed from the saved list: signing in to it again is still
        // the same profile, so its downloads stay with it.
        if let replacing {
            profile.id = replacing.id
        } else if let active, active.isSameLogin(as: profile) {
            profile.id = active.id
        } else if let saved = savedProfiles.first(where: { $0.isSameLogin(as: profile) }) {
            // The ID saving would give it anyway; known now, so its device key and request are found (C45).
            profile.id = saved.id
        }
        // Edit Server to another main address (D139): the device's approval was for the old one and doesn't
        // come along (C49). Until the edit is saved nothing at the new address can use or remove it (no
        // hello is sent there, and the certificate is presented only where it was issued); once the edit
        // is saved it goes. A cancelled or failed edit leaves it.
        let movesDevice = holdsDevice(profile.id, elsewhereThan: Self.deviceOrigin(profile))
        // Edit Server to another username at the same address (the audit after C55, A5): the approval held
        // may be for the old account only, so the new one's `hello` would remove it, and a cancelled edit
        // would lose it. As after a move, `hello` is asked only once the edit is saved, and a failed check
        // asks nothing; unlike a move, the approval goes only if that `hello`, confirmed on a new connection,
        // says it's no longer approved.
        let renamesAccount = !movesDevice && replacing.map { $0.username != username } == true && holdsDevice(profile.id)
        // The check goes over sessions of its own, which present only this login's certificate, where it holds
        // one issued at this address (C45), whoever is signed in; the shared sessions go on presenting the
        // signed-in account's and aren't reset (the review after C56). Each sign-in has its own, so one that a
        // newer one overtook ends only its own. They end when this returns, unless the approval screens took
        // them over (`approvalSessions`).
        let check = devices?.certificates.map {
            LoginSessions(certificates: $0, profile: profile.id, server: Self.mainAddress(profile))
        }
        defer { if let check, approvalSessions !== check { check.end() } }
        do {
            // A home-network address that refuses the login is checked against the main one first (item 10).
            let (checked, info) = try await SubsonicClient.connectAndPing(
                config: profile.config(password: password),
                coverArtSalt: store.coverArtSalt,
                transport: check.map { transport.using($0) } ?? transport
            )
            // Once signed in, the client goes over the shared sessions, as every other request does.
            let client = checked.using(transport)
            // A newer sign-in, switch or sign-out took over while this one waited.
            guard ticket == generation else { return .superseded }
            profile.serverType = info.type
            profile.serverVersion = info.serverVersion
            let answeredAtMain = client.baseURL.absoluteString == profile.config(password: password).normalizedURL
            if movesDevice || renamesAccount {
                // Saved first; then the old address's key, certificate and request go, and the new address
                // is asked as after any sign-in from the form (C49). A new username at the same address is
                // asked the same way, keeping what it holds unless that answer removes it (A5).
                if let failure = finishLogin(profile, client: client, password: password, byIDOnly: replacing != nil, signedIn: signedIn) {
                    return .failed(failure)
                }
                if movesDevice { forgetDevice(profile.id) }
                if answeredAtMain, let saved = active, saved.id == profile.id,
                   let hello = await deviceHello(saved, password: password, over: check), ticket == generation,
                   active?.id == saved.id {
                    showApproval(for: saved, password: password, hello: hello, signedIn: true, over: check) {}
                }
                return .done
            }
            // A server that approves each device and hasn't approved this one yet (asked at its main
            // address only; the home-network one never is, C45): its screens first, then the sign-in finishes.
            if answeredAtMain {
                let hello = await deviceHello(profile, password: password, over: check)
                guard ticket == generation else { return .superseded }
                if let hello {
                    let found = profile
                    let byIDOnly = replacing != nil
                    showApproval(for: found, password: password, hello: hello, signedIn: signedIn, over: check) { [weak self] in
                        guard let self, ticket == self.generation else { return }
                        _ = self.finishLogin(found, client: client, password: password, byIDOnly: byIDOnly, signedIn: signedIn)
                    }
                    return .done
                }
            }
            if let failure = finishLogin(profile, client: client, password: password, byIDOnly: replacing != nil, signedIn: signedIn) {
                return .failed(failure)
            }
            return .done
        } catch is CancellationError {
            if ticket == generation, !signedIn { state = .unauthenticated }
            return .superseded
        } catch {
            guard ticket == generation else { return .superseded }
            // No answer from a server that lets in only approved devices: its screens, then this sign-in
            // again, presenting the new certificate (C45).
            if !movesDevice, !renamesAccount, !((error as? SubsonicError)?.isAuthenticationFailure ?? false) {
                let hello = await deviceHello(profile, password: password, over: check)
                guard ticket == generation else { return .superseded }
                if let hello {
                    let found = profile
                    showApproval(for: found, password: password, hello: hello, signedIn: signedIn, over: check) { [weak self] in
                        await self?.login(
                            serverURL: serverURL, homeNetworkURL: homeNetworkURL, username: username, password: password,
                            sendsPlainPassword: sendsPlainPassword, profileName: profileName, replacing: found
                        )
                    }
                    return .done
                }
            }
            let message = SignInFailure.message(for: error)
            if !signedIn {
                self.error = message
                state = .error
            }
            return .failed(message)
        }
    }

    /// The saved login the sign-in screen's Connect replaces (D139): the one being edited, whatever was
    /// changed; else the one whose password was refused or is missing (`prefill`), but only while both the
    /// address and the username are still its own (the username ignoring case and spaces around it).
    /// Another server, or another account on the same server, typed there is a login of its own, and
    /// mustn't overwrite the refused one's saved entry, ID, password, home-network address, downloads or
    /// device approval (the re-check, item 15).
    static func replaced(
        editing: ServerProfile?, prefill: ServerProfile?, serverURL: String, username: String
    ) -> ServerProfile? {
        if let editing { return editing }
        guard let prefill,
              ServerConfig.normalize(prefill.serverURL, defaultScheme: "https")
                  == ServerConfig.normalize(serverURL, defaultScheme: "https"),
              prefill.username.trimmingCharacters(in: .whitespaces).lowercased()
                  == username.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        return prefill
    }

    /// The end of a sign-in the server answered: the login saved and signed in.
    private func finishLogin(
        _ found: ServerProfile, client: SubsonicClient, password: String, byIDOnly: Bool, signedIn: Bool
    ) -> String? {
        let profile = store.save(found, password: password, byIDOnly: byIDOnly)
        // A Keychain write that failed would leave the next launch without the password.
        guard store.password(for: profile) == password else {
            savedProfiles = store.savedProfiles
            if !signedIn {
                self.error = Self.passwordNotSavedMessage
                state = .error
            }
            return Self.passwordNotSavedMessage
        }
        reconnectTask?.cancel()
        store.setActive(profile, password: password)
        active = profile
        self.client = client
        savedProfiles = store.savedProfiles
        hasAnythingOffline = hasDownloads(profile.id.uuidString)
        prefill = nil
        error = nil
        // From offline mode too (Add Server there): online now, on the new server.
        state = .authenticated
        renewCertificateIfDue(profile, password: password)
        return nil
    }

    /// Flutter `switchProfile`: makes `profile` the active login and checks it. The root shows the
    /// connecting screen, then the app or the unreachable screen.
    func switchTo(_ profile: ServerProfile) async {
        let ticket = nextGeneration()
        reconnectTask?.cancel()
        // Not on this device (a restore brings the profiles back, not this-device-only Keychain items):
        // the login screen asks for it, and the active slot keeps a matching login and password.
        guard let password = store.password(for: profile), !password.isEmpty else {
            askForPassword(profile, message: Self.passwordMissingMessage)
            return
        }
        active = profile
        client = nil
        store.setActive(profile, password: password)
        store.save(profile, password: password)
        savedProfiles = store.savedProfiles
        hasAnythingOffline = hasDownloads(profile.id.uuidString)
        await connectAndVerify(profile, password: password, ticket: ticket)
    }

    /// The network changed (home Wi-Fi left or joined, say): the long-lived sessions start new connections,
    /// as on a certificate change, so nothing new goes onto one the old path left dead (C68, D225). For a
    /// server with a LAN address, the LAN or main address is chosen again and the client swapped if it
    /// changed. No connecting screen, and the player and downloads follow the new address (`RootView`).
    func networkChanged() {
        devices?.certificates?.resetConnections()
        guard active?.homeNetworkURL?.trimmingCharacters(in: .whitespaces).isEmpty == false else { return }
        networkCheck?.cancel()
        networkCheck = Task { [weak self] in await self?.chooseAddressAgain() }
    }

    func chooseAddressAgain() async {
        // Not while a sign-in or switch is checking: it chooses for itself.
        guard state == .authenticated, loginsInFlight == 0, let active, let current = client,
              current.config.normalizedHomeNetworkURL != nil else { return }
        let ticket = generation
        guard let fresh = try? await SubsonicClient.connect(
            config: current.config, coverArtSalt: current.coverArtSalt, transport: transport
        ), !Task.isCancelled else { return }
        guard ticket == generation, state == .authenticated, self.active?.id == active.id,
              client?.baseURL == current.baseURL, fresh.baseURL != current.baseURL else { return }
        // Back to the main address: as before, no check (it's where the login was accepted).
        guard fresh.baseURL.absoluteString != current.config.normalizedURL else {
            client = fresh
            return
        }
        // To the home-network address: its probe carries no login, so any music server there answers it. The
        // signed login goes there only once it's accepted; one that's refused means another server at that
        // private address, and the main address alone is used from then on, as `connectAndPing` does (the
        // audit after C55, A2). No answer leaves the client as it was.
        let accepted: Bool
        do {
            _ = try await fresh.ping()
            accepted = true
        } catch let error as SubsonicError where error.isAuthenticationFailure {
            accepted = false
        } catch {
            return
        }
        guard !Task.isCancelled, ticket == generation, state == .authenticated, self.active?.id == active.id,
              client?.baseURL == current.baseURL else { return }
        if accepted {
            client = fresh
            return
        }
        var mainOnly = current.config
        mainOnly.homeNetworkURL = nil
        guard let main = try? SubsonicClient(config: mainOnly, coverArtSalt: current.coverArtSalt, transport: transport) else { return }
        client = main
    }

    /// The profiles whose downloads are still wanted: the saved ones and the active one. Nil when the
    /// saved list can't be read, so nothing is swept on a guess.
    var profilesWithDownloads: Set<String>? {
        guard let active, store.canReadSavedProfiles else { return nil }
        return Set((store.savedProfiles + [active]).map(\.id.uuidString))
    }

    /// Sign Out's question, in Settings and in the server picker: what `logout()` really removes and keeps
    /// (C54, the second App Store check; Flutter said "all cached data"). "Sign out" since D210.
    static let logoutQuestion = "Sign out of this server? Its downloads and the app's cached data are removed from this iPhone. The server stays in your saved list."

    /// Flutter `logout`: signs out and clears the caches and this server's downloads. **Saved servers
    /// stay** and show as chips on the login screen: Flutter wiped all storage (the user's call, C2).
    /// `RootView` stops the player when the server goes.
    func logout() {
        ArtworkCache.shared.clear()
        LibraryCache.standard.removeAll()
        if let active {
            removeDownloads(active.id.uuidString)
            forgetKey(active.id)
            // The device stays approved for a login still saved; one that goes with the logout goes too.
            if !store.savedProfiles.contains(where: { $0.id == active.id }) { forgetDevice(active.id) }
        }
        signOut()
    }

    /// The unreachable screen's Disconnect (Flutter `disconnect`): signs out, but keeps the caches and
    /// the downloads, which are there again on the next sign-in to this server (D58, correcting D15).
    /// A server already removed from the saved list goes back on it (the re-check, item 18): signed out and
    /// unsaved, nothing would know its ID, so its downloads would be swept and the next sign-in would be a new
    /// profile without them.
    func disconnect() {
        if let active, store.canReadSavedProfiles, !store.savedProfiles.contains(where: { $0.id == active.id }) {
            store.save(active, password: store.activePassword, byIDOnly: true)
        }
        signOut()
    }

    private func signOut() {
        generation += 1
        approval = nil
        afterApproval = nil
        endApprovalSessions()
        reconnectTask?.cancel()
        networkCheck?.cancel()
        store.clearActive()
        active = nil
        client = nil
        error = nil
        hasAnythingOffline = false
        prefill = nil
        savedProfiles = store.savedProfiles
        state = .unauthenticated
        onSignOut()
    }

    /// The saved password was refused, or isn't on this device: the login screen, filled in with
    /// `profile`, shows `message`. The stored active login is left as it was (a matching pair).
    private func askForPassword(_ profile: ServerProfile, message: String) {
        reconnectTask?.cancel()
        active = nil
        client = nil
        hasAnythingOffline = false
        savedProfiles = store.savedProfiles
        prefill = profile
        error = message
        state = .error
    }

    // MARK: Managing profiles

    /// Flutter `renameProfile`, renaming in place (the user's call, C2; Flutter saved a copy).
    func rename(_ profile: ServerProfile, to newName: String) {
        var renamed = profile
        renamed.name = newName
        store.update(renamed)
        if active?.id == profile.id {
            active = renamed
            store.setActive(renamed, password: nil)
        }
        savedProfiles = store.savedProfiles
    }

    /// The password saved for a login on this device, for the login screen opened for it (D139).
    func savedPassword(for profile: ServerProfile) -> String? {
        if profile.id == store.activeProfile?.id, let password = store.activePassword, !password.isEmpty {
            return password
        }
        return store.password(for: profile)
    }

    /// Whether `delete` removes this profile's downloads too (the remove alert says so): the active
    /// login's go with its sign-out, another's with it (D213).
    func deleteRemovesDownloads(_ profile: ServerProfile) -> Bool {
        hasDownloads(profile.id.uuidString)
    }

    /// Whether `delete` signs out first: the profile is the login in use (the remove alert says so, D213).
    func deleteSignsOut(_ profile: ServerProfile) -> Bool {
        profile.id == active?.id
    }

    /// Removes a saved profile. The active one is signed out of first, as Sign Out does (its downloads,
    /// key and device go, and the caches), and then is gone from the list (D213; before, it stayed signed
    /// in and the switcher still showed it). Other profiles' saved sign-ins are untouched.
    func delete(_ profile: ServerProfile) {
        if deleteSignsOut(profile) {
            // Off the saved list first, so `logout` forgets its device too (it keeps a saved login's).
            store.delete(profile)
            logout()
            return
        }
        LibraryCache.standard.remove(key: profile.id.uuidString)
        if profile.id != active?.id {
            removeDownloads(profile.id.uuidString)
            forgetKey(profile.id)
            forgetDevice(profile.id)
        }
        // Nobody signed in (the login screen, its password refused or missing) but still the stored login:
        // the next launch would sign back in to the server just removed, without its downloads or approval
        // (the audit after C55, A3).
        if active == nil, store.activeProfile?.id == profile.id { store.clearActive() }
        store.delete(profile)
        savedProfiles = store.savedProfiles
    }

    /// Whether this account is a Navidrome administrator, asked once per account (`getUser`).
    /// A failed answer reads as "no" and is asked again next time.
    func isAdmin() async -> Bool {
        guard let active, let client else { return false }
        let account = AdminKey(active)
        if let known = adminByAccount[account] { return known }
        guard let info = try? await client.accountInfo() else { return false }
        adminByAccount[account] = info.isAdmin
        return info.isAdmin
    }

    /// The account an answer is for: Edit Server keeps the profile's ID while changing its address or
    /// username, so the ID alone would keep the old account's answer (the re-check, item 17).
    struct AdminKey: Hashable {
        let profile: UUID
        let server: String
        let username: String

        init(_ profile: ServerProfile) {
            self.profile = profile.id
            server = ServerConfig.normalize(profile.serverURL, defaultScheme: "https")
            username = profile.username
        }
    }

    @ObservationIgnored private var adminByAccount: [AdminKey: Bool] = [:]

    /// At most this many servers can be saved (the user, C30 bug 5). Anyone with more keeps them.
    static let maxProfiles = 5
    static let limitMessage = "You can save up to 5 servers. Remove one to add another."
    static let passwordMissingMessage = "Enter the password for this server."
    static let passwordNotSavedMessage = "Could not save the password. Try again."
    static let passwordRefusedOfflineMessage = "The server refused the saved password. Restart the app to sign in again."
    static let deviceRevokedMessage = "This device is no longer approved for this server."

    /// False once five servers are saved: the Add buttons are disabled.
    var canAddServer: Bool { switcherProfiles.count < Self.maxProfiles }

    /// The switcher's list: the saved profiles, with the active login first if it isn't saved.
    var switcherProfiles: [ServerProfile] {
        guard let active, !savedProfiles.contains(where: { $0.id == active.id }) else { return savedProfiles }
        return [active] + savedProfiles
    }

    /// The unreachable screen's Switch Server list: saved logins to another address or user.
    var otherProfiles: [ServerProfile] {
        savedProfiles.filter { $0.serverURL != active?.serverURL || $0.username != active?.username }
    }

    // MARK: Device approval (C45)

    /// A profile's main address: the only one a device certificate is presented to, or enrolment asked at.
    nonisolated static func mainAddress(_ profile: ServerProfile) -> URL? {
        URL(string: ServerConfig.normalize(profile.serverURL, defaultScheme: "https"))
    }

    /// The main address as device approval sees it: https only (C49). Nil for a plain-http main address,
    /// which is treated exactly as a server that doesn't approve devices (no hello, no screens, no key).
    nonisolated static func deviceOrigin(_ profile: ServerProfile) -> DeviceOrigin? {
        mainAddress(profile).flatMap(DeviceOrigin.init)
    }

    /// The enrolment routes at the login's main address, only where that is https (C49). Over a sign-in
    /// check's own sessions where one is given (`check`), else the shared ones.
    private func enrolAPI(_ profile: ServerProfile, password: String, over check: LoginSessions? = nil) -> (any EnrollAPI)? {
        guard let devices, Self.deviceOrigin(profile) != nil,
              let api = devices.api(profile.config(password: password)) else { return nil }
        return check.map { api.using($0) } ?? api
    }

    /// Whether the profile holds a certificate or a waiting request for an address other than `origin`
    /// (its main address before an edit, C49): nothing at `origin` may use, replace or remove them.
    private func holdsDevice(_ id: UUID, elsewhereThan origin: DeviceOrigin?) -> Bool {
        guard let devices else { return false }
        let record = devices.records.record(for: id)
        return !record.belongs(to: origin) && (record.request != nil || devices.keys.hasCertificate(for: id))
    }

    /// Whether the profile holds a certificate or a waiting request, for any address.
    private func holdsDevice(_ id: UUID) -> Bool {
        guard let devices else { return false }
        return devices.records.record(for: id).request != nil || devices.keys.hasCertificate(for: id)
    }

    /// A device record kept before C49 has no address: it's for the profile's main address as saved, and
    /// is stamped with it the first time it's seen (at launch, or when its login is edited). Nothing else
    /// in it changes.
    private func adoptDeviceOrigin(_ profile: ServerProfile) {
        guard let devices, let origin = Self.deviceOrigin(profile) else { return }
        var record = devices.records.record(for: profile.id)
        guard record.origin == nil,
              record.request != nil || devices.keys.hasCertificate(for: profile.id) else { return }
        record.origin = origin.text
        devices.records.set(record, for: profile.id)
    }

    /// Every login kept here: the signed-in one first (it's what the app opens), then the saved list.
    private func adoptDeviceOrigins() {
        guard devices != nil else { return }
        for profile in [store.activeProfile].compactMap({ $0 }) + store.savedProfiles {
            adoptDeviceOrigin(profile)
        }
    }

    /// `hello` at the login's main address, when the server approves devices and this one isn't approved
    /// there; nil for every other server (a stock music server's own answer, no answer, legacy
    /// authentication, which has no signed login to send, a plain-http address), which then carries on
    /// exactly as before. Never asked where the profile's approval is for another address (C49). `check`:
    /// a sign-in check's own sessions, which ask it and confirm it.
    private func deviceHello(_ profile: ServerProfile, password: String, over check: LoginSessions? = nil) async -> EnrollHello? {
        guard let devices, let origin = Self.deviceOrigin(profile), !holdsDevice(profile.id, elsewhereThan: origin),
              let api = enrolAPI(profile, password: password, over: check),
              case .answer(let hello) = await api.hello(), hello.devices != .off, !hello.approved else { return nil }
        // A certificate the server no longer takes (revoked, or run out): it goes, and the device applies
        // again; only when it was issued at this address, and only once a new connection says so too.
        if devices.keys.hasCertificate(for: profile.id) {
            guard devices.records.record(for: profile.id).belongs(to: origin),
                  let confirmed = await confirmRevoked(api, over: check) else { return nil }
            forgetDevice(profile.id)
            return confirmed
        }
        return hello
    }

    /// "Not approved" for a device holding a certificate may have come over a connection opened before the
    /// certificate was stored, which never presented it (the re-check, item 1): `hello` is asked again on a
    /// new connection, which does. The answer when it confirms the revocation; nil keeps the certificate.
    /// A sign-in check's new connection is one of its own sessions' (`check`); else the shared ones are reset.
    private func confirmRevoked(_ api: any EnrollAPI, over check: LoginSessions? = nil) async -> EnrollHello? {
        let certificates = devices?.certificates
        return await DeviceRevocation.confirm(api: api) {
            if let check {
                check.freshConnections()
            } else {
                certificates?.resetConnections()
            }
        }
    }

    /// The approval screens for `profile`, over whatever shows; `then` runs once approved (or skipped
    /// where the server doesn't require it yet). `check`: the sign-in check's own sessions, which the
    /// screens go on using until they close (`approvalSessions`), so they present this login's own
    /// certificate only, none until it's stored.
    private func showApproval(
        for profile: ServerProfile, password: String, hello: EnrollHello, signedIn: Bool,
        over check: LoginSessions? = nil, then: @escaping () async -> Void
    ) {
        guard let devices, let origin = Self.deviceOrigin(profile),
              let api = enrolAPI(profile, password: password, over: check) else { return }
        let flow = DeviceEnrolment(
            profile: profile.id, origin: origin, username: profile.username, hello: hello, api: api, keys: devices.keys,
            records: devices.records, certificates: devices.certificates, device: devices.device,
            deviceName: devices.deviceName, attesting: devices.attesting
        )
        flow.onFiled = { [weak self] in
            // Kept as a saved login, so the request is found again after the app closes.
            guard let self else { return }
            self.store.save(profile, password: password, byIDOnly: true)
            self.savedProfiles = self.store.savedProfiles
        }
        flow.onApproved = { [weak self] in
            Task { await self?.approvalFinished() }
        }
        if !signedIn, state == .authenticating {
            state = .unauthenticated
            error = nil
        }
        afterApproval = then
        // Screens shown before these, with their sessions, are gone.
        if approvalSessions !== check { endApprovalSessions() }
        approvalSessions = check
        approval = flow
    }

    private func approvalFinished() async {
        approval = nil
        endApprovalSessions()
        let then = afterApproval
        afterApproval = nil
        await then?()
    }

    /// The approval screens closed: their check's sessions go.
    private func endApprovalSessions() {
        approvalSessions?.end()
        approvalSessions = nil
    }

    /// "Not Now", where the server lets in devices without a certificate for now (`optional`): the
    /// sign-in finishes as it would have.
    func skipApproval() async {
        guard approval?.rule == .optional else { return }
        await approvalFinished()
    }

    /// "Cancel": the screens go, the request (if one was filed) is kept for next time.
    func cancelApproval() {
        approval = nil
        afterApproval = nil
        endApprovalSessions()
    }

    /// The saved server didn't answer: a server that approves devices may be turning this one away.
    /// True when that was it (the approval screens, or the login screen for a device revoked there).
    private func deviceCheckAfterNoAnswer(_ profile: ServerProfile, password: String, ticket: Int) async -> Bool {
        guard let devices, let origin = Self.deviceOrigin(profile), !holdsDevice(profile.id, elsewhereThan: origin),
              let api = enrolAPI(profile, password: password),
              case .answer(let hello) = await api.hello(), hello.devices != .off, !hello.approved,
              ticket == generation, active?.id == profile.id, state != .offlineMode else { return false }
        if devices.keys.hasCertificate(for: profile.id) {
            // Only the address that issued it can say it's no longer approved (C49), and only once a new
            // connection, presenting it, says so too (item 1).
            guard devices.records.record(for: profile.id).belongs(to: origin),
                  await confirmRevoked(api) != nil,
                  ticket == generation, active?.id == profile.id, state != .offlineMode else { return false }
            forgetDevice(profile.id)
            askForPassword(profile, message: Self.deviceRevokedMessage)
            return true
        }
        client = nil
        hasAnythingOffline = hasDownloads(profile.id.uuidString)
        state = .serverUnreachable
        showApproval(for: profile, password: password, hello: hello, signedIn: true) { [weak self] in
            await self?.retry()
        }
        return true
    }

    /// A certificate past its `renewAfter` is renewed in the background, over the approved connection.
    private func renewCertificateIfDue(_ profile: ServerProfile, password: String) {
        guard let devices, let origin = Self.deviceOrigin(profile), devices.keys.hasCertificate(for: profile.id),
              devices.records.record(for: profile.id).belongs(to: origin),
              DeviceRenewal.isDue(devices.records.record(for: profile.id), now: Date()),
              let api = enrolAPI(profile, password: password) else { return }
        let (keys, records, certificates, id) = (devices.keys, devices.records, devices.certificates, profile.id)
        Task {
            await DeviceRenewal.renewIfDue(
                profile: id, origin: origin, api: api, keys: keys, records: records, certificates: certificates
            )
        }
    }

    /// A profile's device key, certificate and request go (the profile removed, or the device revoked).
    private func forgetDevice(_ id: UUID) {
        guard let devices else { return }
        devices.keys.remove(profile: id)
        devices.records.set(nil, for: id)
        devices.certificates?.refresh()
    }

    // MARK: Checking the server

    /// Flutter `configure` + `_verifyConnection`.
    private func connectAndVerify(_ profile: ServerProfile, password: String, ticket: Int) async {
        state = .authenticating
        let config = profile.config(password: password)
        let salt = store.coverArtSalt
        var answer: (SubsonicClient, ServerInfo)?
        var refusal: SubsonicError?
        for attempt in 1...max(verifyAttempts, 1) {
            do {
                // A home-network address that refuses the login is checked against the main one (item 10).
                answer = try await withTimeout(verifyTimeout) { [transport] in
                    try await SubsonicClient.connectAndPing(config: config, coverArtSalt: salt, transport: transport)
                }
            } catch let error as SubsonicError where error.isAuthenticationFailure {
                // A wrong password (changed on the server) won't come right by asking again.
                refusal = error
            } catch {}
            if answer != nil || refusal != nil || Task.isCancelled { break }
            if attempt < verifyAttempts {
                try? await Task.sleep(for: retryDelay)
            }
        }
        // A newer sign-in, switch or logout took over while this one waited.
        guard ticket == generation, active?.id == profile.id else { return }
        if let refusal {
            // Offline mode chosen while this waited stays, and the user is told (the tries stop).
            if state == .offlineMode {
                passwordRefusedWhileOffline()
            } else {
                askForPassword(profile, message: SignInFailure.message(for: refusal))
            }
            return
        }
        guard let (client, info) = answer else {
            // Offline mode chosen while this waited ("Open in offline mode" on the connecting screen) stays
            // (Flutter dropped back to the unreachable screen).
            if state == .offlineMode { return }
            if await deviceCheckAfterNoAnswer(profile, password: password, ticket: ticket) { return }
            self.client = nil
            hasAnythingOffline = hasDownloads(profile.id.uuidString)
            state = .serverUnreachable
            return
        }
        if info.type != profile.serverType || info.serverVersion != profile.serverVersion {
            var updated = profile
            updated.serverType = info.type
            updated.serverVersion = info.serverVersion
            active = updated
            store.setActive(updated, password: nil)
            store.update(updated)
            savedProfiles = store.savedProfiles
        }
        self.client = client
        state = .authenticated
        renewCertificateIfDue(active ?? profile, password: password)
    }
}

/// Runs `operation`, throwing `SubsonicError.timedOut` if it takes longer than `limit`.
nonisolated func withTimeout<T: Sendable>(
    _ limit: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw SubsonicError.timedOut
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw SubsonicError.timedOut }
        return result
    }
}

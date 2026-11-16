import Foundation
import PlaybackKit
import SubsonicKit
import UIKit

/// What the player and downloads follow: the server, the connection state and the client in use.
/// `RootView` applies every change of it (as it always has); a Siri or Shortcuts request applies it
/// through `PlaybackReadiness`, which works with no window (C39, D156).
struct PlaybackConnection: Equatable {
    var profileID: UUID?
    var state: AccountModel.State
    var config: ServerConfig?
    var baseURL: URL?
    /// Which account (`AccountKey`): Edit Server can make the profile another account and keep its ID.
    /// Without one (the tests'), the profile ID stands for it.
    var account: String?

    init(
        profileID: UUID?, state: AccountModel.State, config: ServerConfig? = nil, baseURL: URL? = nil,
        account: String? = nil
    ) {
        self.profileID = profileID
        self.state = state
        self.config = config
        self.baseURL = baseURL
        self.account = account ?? profileID?.uuidString
    }

    init(_ account: AccountModel) {
        self.init(
            profileID: account.active?.id,
            state: account.state,
            config: account.client?.config,
            baseURL: account.client?.baseURL,
            account: account.active?.accountKey.mark
        )
    }

    enum Step: Equatable {
        case resetPlayer, deactivateDownloads
        /// Signed in: the player and downloads on the client. `full`: also another device's queue
        /// (C36) and the Smart Downloads catch-up (C37); never on a launch with no window.
        case connect(full: Bool)
        case connectOffline
        /// A removed server's downloads (only with a window, where the profiles were certainly read).
        case sweepOrphans
    }

    /// What going from `old` to `new` does, in order: the old server's reset always comes before the
    /// new one's connect (Add Server changes the server while the state stays signed in).
    static func steps(from old: Self, to new: Self, windowless: Bool) -> [Step] {
        var steps: [Step] = []
        // Whichever way the server changed (switcher, Add Server, logout, the unreachable screen),
        // Flutter's `resetForServerSwitch`; also Edit Server to another account. Signing in from nothing
        // isn't a change.
        if old.account != new.account {
            if old.account != nil { steps.append(.resetPlayer) }
            if new.profileID == nil { steps.append(.deactivateDownloads) }
        }
        guard new.profileID != nil else { return steps }
        if new.state == .authenticated, new.config != nil {
            steps.append(.connect(full: !windowless))
            if !windowless { steps.append(.sweepOrphans) }
        } else if new.state == .offlineMode {
            steps.append(.connectOffline)
        }
        return steps
    }

    /// Carries out `steps(from:to:windowless:)` on the app's models.
    static func apply(
        from old: Self,
        to new: Self,
        windowless: Bool,
        account: AccountModel,
        player: PlayerModel,
        downloads: DownloadModel
    ) {
        // Signed out, or another server: its albums, artists and playlists leave Spotlight (a launch's
        // first sign-in, from nothing, keeps what this server indexed before).
        if old.account != new.account, old.account != nil { SpotlightIndex.serverChanged() }
        // A page still waiting to open was asked for on the old server, or by nobody signed in (C47).
        if (old.account != nil && old.account != new.account) || new.state == .unauthenticated {
            AppNavigator.shared.clear()
        }
        // The widgets follow too (C40): signed out, another server, or signed in again.
        WidgetSnapshotWriter.shared?.connectionChanged(from: old, to: new)
        for step in steps(from: old, to: new, windowless: windowless) {
            switch step {
            case .resetPlayer:
                player.reset()
            case .deactivateDownloads:
                downloads.deactivate()
            case .connect(let full):
                guard let active = account.active, let client = account.client else { continue }
                let profileID = active.id.uuidString
                player.connect(client: client, profileID: profileID, checksServerQueue: full)
                downloads.activate(profileID: profileID, client: client, catchesUp: full)
                if full { SpotlightIndex.refresh(profileID: profileID, account: active.accountKey.mark) }
            case .connectOffline:
                guard let active = account.active else { continue }
                let profileID = active.id.uuidString
                player.connectOffline(profileID: profileID)
                downloads.activate(profileID: profileID, client: nil)
                if !windowless { SpotlightIndex.refresh(profileID: profileID, account: active.accountKey.mark) }
            case .sweepOrphans:
                // A removed server's downloads, once it's no longer the active one either: nothing
                // lists them any more. Only here, signed in, where the profiles were certainly read
                // (a launch before the phone's first unlock reads none, and would sweep everything).
                if let wanted = account.profilesWithDownloads { DownloadStore.removeOrphans(keeping: wanted) }
            }
        }
    }
}

/// Where a Siri, Shortcuts or quick-action request finds the app (C39, D156).
enum Readiness: Equatable {
    case online, offline
    /// The server didn't answer in time; offline mode is possible (there are downloads).
    case unreachable(canGoOffline: Bool)
    /// Nobody signed in, or the saved password was refused.
    case signedOut
    /// Before the phone's first unlock: the login can't be read.
    case locked
}

/// Brings the app to "ready to play" with or without a window: the sign-in `RootView` starts, then
/// the same connection `RootView` applies, minus what playing doesn't need when there's no window.
@MainActor
final class PlaybackReadiness {
    private let account: AccountModel
    /// The connection as playing needs it (`windowless`): with a window, `RootView` applies the rest.
    private let apply: @MainActor () -> Void
    /// True before the phone's first unlock since it was switched on: the Keychain and the saved
    /// profiles can't be read, and a sign-in then would leave the app signed out for the rest of the
    /// process. **Not "the phone is locked":** locked again later, everything still reads, and a
    /// request from the lock screen, AirPods or CarPlay plays (C46, D163). `isProtectedDataAvailable`
    /// alone is false on every lock, so the Keychain is asked which of the two it is.
    var isBeforeFirstUnlock: @MainActor () -> Bool = {
        !UIApplication.shared.isProtectedDataAvailable && KeychainSecretStore().isLockedUntilFirstUnlock
    }
    /// How long a request waits for the server (Siri won't wait for three slow pings).
    var limit: Duration = .seconds(10)

    init(account: AccountModel, apply: @escaping @MainActor () -> Void) {
        self.account = account
        self.apply = apply
    }

    /// Safe to call any number of times, from anywhere.
    func ensureReady() async -> Readiness {
        if account.state == .unknown {
            // Only a start reads the saved login: an app already running has it, locked or not.
            guard !isBeforeFirstUnlock() else { return .locked }
            // Not awaited: a server that doesn't answer takes three pings, longer than a request waits.
            Task { await account.start() }
        }
        let deadline = ContinuousClock.now + limit
        while isChecking, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        switch account.state {
        case .authenticated where account.client != nil:
            apply()
            return .online
        case .offlineMode:
            apply()
            return .offline
        case .serverUnreachable, .authenticating where account.active != nil:
            return .unreachable(canGoOffline: account.hasAnythingOffline)
        case .unknown:
            return .unreachable(canGoOffline: false)
        default:
            return .signedOut
        }
    }

    /// The server is out of reach and there are downloads: offline mode, as the connecting screen's
    /// "Open in offline mode" does (it goes back online by itself, C10).
    func goOffline() -> Readiness {
        account.switchToOffline()
        guard account.state == .offlineMode else { return .signedOut }
        apply()
        return .offline
    }

    /// Still reading the login or checking the saved server (not the login screen's own sign-in).
    private var isChecking: Bool {
        account.state == .unknown || (account.state == .authenticating && account.active != nil)
    }
}

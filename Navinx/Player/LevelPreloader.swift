import Observation
import HubKit
import PlaybackKit
import SubsonicKit
import SwiftUI

extension EnvironmentValues {
    /// The equalizer bars' real levels (C20); nil (previews) leaves the bars on their loop.
    @Entry var levelMeter: LevelMeter?
}

/// Keeps the levels of the current song and the next three ready (C20, D89): it follows the queue
/// itself (not a view), so it carries on with the screen off and the next song's levels are there
/// when it starts.
@MainActor
final class LevelPreloader {
    let meter: LevelMeter
    private let player: PlayerModel

    /// `client` gives the signed-in account's client (its address in use and its signed login), nil when
    /// signed out or offline; `profile` its profile's id, whose key proves the sign-in comes from the app.
    /// The session is the hub's own (`HubSessions.shared`): one sign-in serves both.
    init(
        player: PlayerModel, client: @escaping @MainActor () -> SubsonicClient?,
        profile: @escaping @MainActor () -> UUID? = { nil }, sessions: HubSessions = .shared
    ) {
        self.player = player
        self.meter = LevelMeter { songID in
            try await LevelPreloader.fetch(songID, client: client(), profile: profile(), sessions: sessions)
        }
        follow()
    }

    private func follow() {
        let ids = withObservationTracking {
            LevelMeter.songsToPreload(
                queue: player.queue.map(\.id), currentIndex: player.currentIndex, wraps: player.repeatMode == .all
            )
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        meter.preload(ids)
    }

    /// The server's levels for a song, asked as the signed-in account at its own address (D100, D101,
    /// C27). Every way it can't help (signed out, offline, legacy auth, a server without the route)
    /// leaves the bars on their loop.
    static func fetch(
        _ songID: String, client: SubsonicClient?, profile: UUID? = nil, sessions: HubSessions = .shared
    ) async throws -> LevelFetch {
        guard let client else { return .unavailable }
        // No signed login for this address: nothing is sent, neither a sign-in nor the old way.
        guard let login = client.signedLoginQuery(for: MeterClient.url(base: client.baseURL, songID: songID)) else {
            return .unavailable
        }
        // The tab's own digest of the login (`HubIdentity`), so the levels and the tab share one session
        // and one sign-in.
        let account = HubAccount(
            baseURL: client.baseURL, username: client.config.username, login: login,
            loginDigest: HubIdentity(client).account, keys: AppKey.provider(for: profile)
        )
        switch try await MeterClient(account: account, sessions: sessions).levels(songID: songID) {
        case .levels(let data): return .levels(data)
        case .none: return .none
        case .unavailable: return .unavailable
        case .failed: return .failed
        }
    }
}

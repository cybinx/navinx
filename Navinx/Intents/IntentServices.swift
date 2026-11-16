import AppIntents
import Foundation
import PlaybackKit
import SharedKit
import SubsonicKit

/// What Siri, Shortcuts, Spotlight and the icon's quick actions reach the app through (C39): the
/// app's own models, made once in `NavinxApp.init` and registered with `AppDependencyManager`.
@MainActor
final class IntentServices: IntentActions {
    /// The app's (the scene delegate and the entity queries have no `@Dependency`).
    private(set) static var shared: IntentServices?

    let account: AccountModel
    let player: PlayerModel
    let downloads: DownloadModel
    let toasts: ToastCenter
    let navigator: AppNavigator
    let readiness: PlaybackReadiness

    init(account: AccountModel, player: PlayerModel, downloads: DownloadModel, toasts: ToastCenter, navigator: AppNavigator) {
        self.account = account
        self.player = player
        self.downloads = downloads
        self.toasts = toasts
        self.navigator = navigator
        // Only what playing needs: with a window `RootView` has applied (or will apply) the rest itself.
        readiness = PlaybackReadiness(account: account) {
            let now = PlaybackConnection(account)
            PlaybackConnection.apply(
                from: now, to: now, windowless: true, account: account, player: player, downloads: downloads
            )
        }
    }

    /// Makes these the app's, for intents (`@Dependency`) and the scene delegate.
    func register() {
        Self.shared = self
        AppDependencyManager.shared.add(dependency: self)
        // `SharedKit`'s intents (the widgets' and controls', C40) and its playlist query.
        IntentHost.actions = self
    }

    // MARK: Playing

    /// `SharedKit`'s since C40 (the widgets' intents carry them).
    typealias Request = PlayRequest
    typealias Answer = IntentAnswer

    /// Brings the app to "ready to play" (signing in with no window if need be), finds the songs and
    /// plays them. A server out of reach plays what's downloaded, in offline mode (D146).
    func play(_ request: Request) async throws(Answer) {
        var isOnline: Bool
        switch await readiness.ensureReady() {
        case .online: isOnline = true
        case .offline: isOnline = false
        case .locked: throw .locked
        case .signedOut: throw .signIn
        case .unreachable(let canGoOffline):
            guard canGoOffline, readiness.goOffline() == .offline else { throw .unreachable }
            isOnline = false
        }
        if request == .resume {
            try await resume()
            return
        }
        let client = isOnline ? account.client : nil
        let songs = try await songs(for: request, client: client)
        guard !songs.isEmpty else { throw client == nil ? .notDownloaded : .nothingToPlay }
        switch request {
        case .album(_, let shuffle), .artist(_, let shuffle), .playlist(_, let shuffle), .favorites(let shuffle):
            shuffle ? player.playShuffled(songs) : player.playInOrder(songs)
        case .library, .resume:
            player.playShuffled(songs)
        }
    }

    /// The player's song, once it has one: right after a sign-in the kept song may still be on its way.
    private func resume() async throws(Answer) {
        let deadline = ContinuousClock.now + .seconds(3)
        while player.currentSong == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard player.currentSong != nil else { throw .nothingToPlay }
        if !player.isPlaying { player.play() }
    }

    /// Online, the server's songs; offline (no client), only the downloaded ones.
    private func songs(for request: Request, client: SubsonicClient?) async throws(Answer) -> [Song] {
        do {
            switch request {
            case .album(let id, _):
                guard let client else { return OfflineLogic.sortedTracks(downloads.songsByAlbum[id] ?? []) }
                return try await client.albumSongs(albumID: id)
            case .playlist(let id, _):
                guard let client else {
                    return (downloads.playlist(id: id)?.songs ?? []).filter { downloads.isDownloaded($0.id) }
                }
                return try await client.playlist(id: id).songs ?? []
            case .artist(let id, _):
                guard let client else {
                    return OfflineLogic.sortedTracks(downloads.offlineSongs.filter { $0.artistID == id })
                }
                // The artist page's Play: the top songs; with none from the server, all of theirs.
                let top = (try? await client.topSongs(artistID: id)) ?? []
                if !top.isEmpty { return top }
                let saved = await SavedLibrary.shared.allSongs().filter { $0.artistID == id }
                if !saved.isEmpty { return saved }
                var songs: [Song] = []
                for album in try await client.artistAlbums(artistID: id) {
                    songs += try await client.albumSongs(albumID: album.id)
                }
                return songs
            case .favorites:
                // The favourites are the server's list (Favorites says the same offline).
                guard let client else { throw Answer.needsServer }
                return try await client.starred().songs
            case .library:
                guard let client else { return downloads.offlineSongs }
                let saved = await SavedLibrary.shared.allSongs()
                return saved.isEmpty ? try await client.randomSongs(size: 500) : saved
            case .resume:
                return []
            }
        } catch let answer as Answer {
            throw answer
        } catch {
            throw .failed
        }
    }

    // MARK: Simple controls (no sign-in: they act on what's in the player)

    func pause() { player.pause() }
    /// The widget's Next with the app closed starts the app with nothing loaded: it's brought to
    /// "ready to play" first, as Resume is, then goes to the next song, still paused (C47, the
    /// check's E1). With a song loaded it only skips.
    func next() async {
        if player.currentSong == nil { _ = await readiness.ensureReady() }
        player.skipNext()
    }
    func previous() { player.skipPrevious() }

    // MARK: Opening pages

    /// The app is coming forward: a page waits for the tabs. Signed out, it says so.
    func open(_ destination: AppDestination) async throws(Answer) {
        switch await readiness.ensureReady() {
        case .locked: throw .locked
        case .signedOut: throw .signIn
        case .online, .offline, .unreachable: break
        }
        navigator.open(destination)
    }

    // MARK: The widgets (C40)

    func refreshWidgets() async {
        await WidgetSnapshotWriter.shared?.flush()
    }

    // MARK: Playlists, for `SharedKit`'s `PlaylistQuery` in the app

    /// The saved library's; one it doesn't have yet (made since the last sync, or only downloaded)
    /// from the list the widgets were given, which is where the Playlist widget's choice came from,
    /// else from the server (C47, the check's E2). Playing needs only the ID.
    func playlists(withIDs ids: [String]) async -> [PlaylistEntity] {
        let saved = await SavedLibrary.shared.lists()?.playlists ?? []
        var known = Dictionary(saved.map { ($0.id, PlaylistEntity($0)) }, uniquingKeysWith: { first, _ in first })
        if ids.contains(where: { known[$0] == nil }) {
            for item in WidgetStore.shared?.read()?.playlists ?? [] where known[item.id] == nil {
                known[item.id] = PlaylistEntity(id: item.id, name: item.name)
            }
        }
        if ids.contains(where: { known[$0] == nil }), let fetched = try? await account.client?.playlists() {
            for playlist in fetched where known[playlist.id] == nil { known[playlist.id] = PlaylistEntity(playlist) }
        }
        return ids.compactMap { known[$0] }
    }

    func playlists(matching text: String) async -> [PlaylistEntity] {
        var playlists = await SavedLibrary.shared.lists()?.playlists ?? []
        if playlists.isEmpty, let client = account.client, let fetched = try? await client.playlists() {
            playlists = fetched
        }
        return LibraryMatching.rank(playlists, name: \.name, matching: text).map(PlaylistEntity.init)
    }

    func suggestedPlaylists() async -> [PlaylistEntity] {
        (await SavedLibrary.shared.lists()?.playlists ?? []).map(PlaylistEntity.init)
    }
}

import PlaybackKit
import SharedKit
import SubsonicKit
import UIKit
import WidgetKit

/// What the Home Screen widgets show (C40): the app writes `SharedKit`'s snapshot into the App Group's
/// folder, with the covers as plain picture files beside it, and asks WidgetKit to redraw. Written on
/// a song change, on play and pause, and when the library's recent albums or playlists load; never for
/// the playing position (the widgets' reload budget is small). Signing out, Disconnect and another
/// server clear it. No login and no address goes in: the extension never signs in.
@MainActor
final class WidgetSnapshotWriter {
    /// The app's, once `install()` ran; nil in a build without the App Group.
    private(set) static var shared: WidgetSnapshotWriter?

    /// The covers' size in pixels: the largest a widget shows (the Playlist and Now Playing covers).
    static let coverPixels = 480

    private let store: WidgetStore
    private let player: PlayerModel
    private let account: AccountModel
    private var snapshot: WidgetSnapshot
    /// The song and its playing state the snapshot was last asked to show.
    private var shownSong: SongKey?
    private var nowPlayingTask: Task<Void, Never>?
    private var libraryTask: Task<Void, Never>?
    /// Covers saved for a snapshot still being made, which a write meanwhile must not remove: counted,
    /// since two snapshots being made (now playing and the library) can hold the same cover, and the
    /// first to finish mustn't free it for the other.
    private var coversInProgress: [String: Int] = [:]
    /// The account (`AccountKey.mark`) whose playlists were last written in this run, so a sign back in
    /// to it can keep the Playlist widget's choice while they load again (`WidgetSnapshot.playlistsReloading`).
    private var playlistsAccount: String?

    private struct SongKey: Equatable {
        var id: String
        var isPlaying: Bool
    }

    init?(player: PlayerModel, account: AccountModel, store: WidgetStore? = WidgetStore.shared) {
        guard let store else { return nil }
        self.store = store
        self.player = player
        self.account = account
        snapshot = store.read() ?? .signedOut
        // An app only just started is never playing. A snapshot left saying so (the app was quit or
        // killed mid-song) would keep the widget on Pause, where its buttons do nothing (C47, the
        // check's E1).
        if snapshot.nowPlaying?.isPlaying == true {
            update(kinds: [WidgetKind.nowPlaying]) { $0.nowPlaying?.isPlaying = false }
        }
    }

    /// Follows the player and the sign-out, after `SystemMediaBridge` took the player's hook: both
    /// hooks are chained, never replaced.
    func install() {
        Self.shared = self
        let nowPlaying = player.onNowPlayingChange
        player.onNowPlayingChange = { [weak self] in
            nowPlaying?()
            self?.playerChanged()
        }
        let signOut = account.onSignOut
        account.onSignOut = { [weak self] in
            signOut()
            self?.clear()
        }
    }

    // MARK: The player

    /// Called about 25 times in a song (seeks, modes, the clock's stops): only a new song or a play or
    /// pause goes on, after a moment's wait so a skip's in-between states aren't written.
    private func playerChanged() {
        let key = currentKey
        guard key != shownSong else { return }
        shownSong = key
        nowPlayingTask?.cancel()
        nowPlayingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.writeNowPlaying()
        }
    }

    /// At once (a widget's button ran): the system redraws the widget when its intent returns.
    func flush() async {
        nowPlayingTask?.cancel()
        shownSong = currentKey
        await writeNowPlaying()
    }

    private var currentKey: SongKey? {
        player.currentSong.map { SongKey(id: $0.id, isPlaying: player.isPlaying) }
    }

    private func writeNowPlaying() async {
        guard account.active != nil else { return }
        let song = player.currentSong
        var shared: WidgetSong?
        var cover: String?
        defer { release([cover]) }
        if let song {
            cover = await saveCover(song.coverArt ?? song.id)
            guard player.currentSong?.id == song.id else { return }
            shared = WidgetSong(
                id: song.id, title: song.title, artist: song.artist, album: song.album,
                cover: cover, isPlaying: player.isPlaying
            )
        }
        update(kinds: [WidgetKind.nowPlaying]) {
            $0.signedIn = true
            $0.nowPlaying = shared
        }
    }

    // MARK: The library

    /// The library's recent albums and playlists loaded or changed (`LibraryModel`), for `account`
    /// (`AccountKey.mark`).
    func libraryChanged(latestAlbums: [Album], playlists: [Playlist], account mark: String) {
        guard account.active?.accountKey.mark == mark else { return }
        libraryTask?.cancel()
        libraryTask = Task { [weak self] in
            await self?.writeLibrary(latestAlbums: latestAlbums, playlists: playlists, account: mark)
        }
    }

    private func writeLibrary(latestAlbums: [Album], playlists: [Playlist], account mark: String) async {
        var albums: [WidgetItem] = []
        var lists: [WidgetItem] = []
        defer { release((albums + lists).map(\.cover)) }
        for album in latestAlbums.prefix(WidgetSnapshot.recentLimit) {
            let cover = await saveCover(album.coverArt ?? album.id)
            albums.append(WidgetItem(id: album.id, name: album.name, subtitle: album.artist, cover: cover))
            if Task.isCancelled { return }
        }
        for (index, playlist) in playlists.enumerated() {
            let cover = index < WidgetSnapshot.playlistCoverLimit ? await saveCover(playlist.coverArt) : nil
            lists.append(WidgetItem(id: playlist.id, name: playlist.name, cover: cover))
            if Task.isCancelled { return }
        }
        guard account.active?.accountKey.mark == mark else { return }
        playlistsAccount = mark
        update(kinds: [WidgetKind.recentlyPlayed, WidgetKind.playlist]) {
            $0.signedIn = true
            $0.latestAlbums = albums
            $0.playlists = lists
            $0.playlistsReloading = false
        }
    }

    // MARK: Signing in and out

    /// Every change of the server or the connection (`PlaybackConnection.apply`).
    func connectionChanged(from old: PlaybackConnection, to new: PlaybackConnection) {
        if new.profileID == nil {
            // Signed out (also at a launch with nobody signed in, or whose saved password is missing:
            // the login screen with its error); not the moment before a launch's sign-in.
            if new.state == .unauthenticated || new.state == .error || old.profileID != nil { clear() }
        } else if old.account != nil, old.account != new.account {
            // Another server or account (Edit Server can keep the profile): nothing of the last one's
            // stays; the new one's arrives as it loads.
            reset(signedIn: true)
        } else if !snapshot.signedIn {
            // Back in to the account the last playlists were for: the widget's choice is still its own.
            let isSameAccount = new.account == playlistsAccount
            update(kinds: [WidgetKind.nowPlaying, WidgetKind.recentlyPlayed, WidgetKind.playlist]) {
                $0.signedIn = true
                $0.playlistsReloading = isSameAccount && $0.playlists.isEmpty
            }
        }
    }

    private func clear() {
        reset(signedIn: false)
    }

    private func reset(signedIn: Bool) {
        nowPlayingTask?.cancel()
        libraryTask?.cancel()
        shownSong = nil
        update(kinds: [WidgetKind.nowPlaying, WidgetKind.recentlyPlayed, WidgetKind.playlist]) {
            $0 = WidgetSnapshot(signedIn: signedIn)
        }
    }

    // MARK: Writing

    /// Changes the snapshot; if anything changed, writes it and redraws `kinds`.
    private func update(kinds: [String], _ change: (inout WidgetSnapshot) -> Void) {
        var next = snapshot
        change(&next)
        guard next != snapshot || store.read() == nil else { return }
        snapshot = next
        do {
            try store.write(next, keeping: Set(coversInProgress.keys))
        } catch {
            return
        }
        for kind in kinds { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
    }

    /// The covers a finished (or abandoned) snapshot no longer needs kept.
    private func release(_ names: [String?]) {
        for name in names.compactMap({ $0 }) { releaseCover(name) }
    }

    /// One hold on `name` fewer; the last one lets it go.
    private func releaseCover(_ name: String) {
        guard let count = coversInProgress[name] else { return }
        coversInProgress[name] = count > 1 ? count - 1 : nil
    }

    /// The cover's file name, saving the picture first if it isn't there yet; nil when there's none
    /// to be had (offline and never cached, say). The picture comes from a download's file, else the
    /// image cache, else the server, through the app's own cache (`ArtworkCache`).
    private func saveCover(_ coverArt: String?) async -> String? {
        guard let coverArt, !coverArt.isEmpty, let name = WidgetStore.coverName(for: coverArt) else { return nil }
        // Kept from removal until the caller's snapshot names it (`release`).
        coversInProgress[name, default: 0] += 1
        if store.hasCover(name) { return name }
        let size = Self.coverPixels
        let client = account.client
        let url = OfflineCovers.shared.file(for: coverArt) ?? client?.coverArtURL(coverArt, size: size)
            ?? ArtworkCache.shared.offlineURL(coverArt, size: size, profileID: account.active?.id.uuidString)
        if let url, let image = await ArtworkCache.shared.image(url: url, maxPixel: size, cacheOnly: client == nil),
           let data = image.jpegData(compressionQuality: 0.8), (try? store.saveCover(data, name: name)) != nil {
            return name
        }
        releaseCover(name)
        return nil
    }
}

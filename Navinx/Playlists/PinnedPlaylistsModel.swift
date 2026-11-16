import Foundation
import Observation
import SubsonicKit

/// Flutter `FavoritePlaylistsService`: which playlists are favourites, kept on the phone (the server
/// has no such thing), and the songs of each for Home's rows.
@Observable
final class PinnedPlaylistsModel {
    /// C11's switch, "Favorite playlists on Home". Off by default, as in Flutter.
    static let showOnHomeKey = "home_show_favorite_playlists"

    private(set) var ids: Set<String>
    /// Each favourite's songs, as `getPlaylists` carries none, with its `changed` in that list when
    /// they were fetched.
    private var fetched: [String: (changed: Date?, songs: [Song])] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "favorite_playlist_ids"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func isFavorite(_ id: String) -> Bool { ids.contains(id) }

    func toggle(_ id: String) {
        if ids.remove(id) == nil { ids.insert(id) }
        save()
    }

    /// When a playlist is deleted.
    func remove(_ id: String) {
        guard ids.remove(id) != nil else { return }
        fetched[id] = nil
        save()
    }

    /// Flutter `_buildFavoritePlaylistRows`: most recently changed first, each with its songs.
    /// A playlist whose songs haven't arrived, or that has none, has no row.
    func homeRows(_ playlists: [Playlist]) -> [Playlist] {
        playlists
            .filter { ids.contains($0.id) }
            .sorted { Self.lastUpdate($0) > Self.lastUpdate($1) }
            .compactMap { fetchedVersion(of: $0) }
            .filter { !($0.songs ?? []).isEmpty }
    }

    /// What `loadSongs` depends on.
    func loadKey(_ playlists: [Playlist]) -> String {
        playlists
            .filter { ids.contains($0.id) }
            .map { "\($0.id)@\($0.changed?.timeIntervalSince1970 ?? 0)" }
            .sorted()
            .joined(separator: "|")
    }

    /// Fetches each favourite once, and again only when the server reports a newer `changed` (Flutter
    /// `_refreshSongsIfStale`). A failed fetch is tried again the next time the key changes.
    func loadSongs(_ playlists: [Playlist], client: SubsonicClient?) async {
        guard let client else { return }
        for playlist in playlists where ids.contains(playlist.id) && fetchedVersion(of: playlist) == nil {
            if let full = try? await client.playlist(id: playlist.id) {
                fetched[playlist.id] = (playlist.changed, full.songs ?? [])
            }
        }
    }

    private func fetchedVersion(of playlist: Playlist) -> Playlist? {
        guard let version = fetched[playlist.id], version.changed == playlist.changed else { return nil }
        var row = playlist
        row.songs = version.songs
        return row
    }

    private static func lastUpdate(_ playlist: Playlist) -> Date {
        playlist.changed ?? playlist.created ?? .distantPast
    }

    private func save() {
        defaults.set(Array(ids), forKey: Self.key)
    }
}

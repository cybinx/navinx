import Foundation
import SubsonicKit

/// What the pages show offline (C10, D52): everything known, with what isn't downloaded greyed out;
/// Search looks through the downloads; Home keeps only what's downloaded.
nonisolated enum OfflineLogic {
    /// An album page with no server: the album as downloaded with all its songs, else the saved
    /// library's album with every song it knows, else what the downloads have of it.
    static func album(id: String, downloaded: Album?, isComplete: Bool, libraryAlbums: [Album], librarySongs: [Song]) -> Album? {
        if let downloaded, isComplete { return downloaded }
        let songs = librarySongs.filter { $0.albumID == id }
        if var album = libraryAlbums.first(where: { $0.id == id }) ?? downloaded {
            let known = songs.count >= (downloaded?.songs.count ?? 0) ? songs : downloaded?.songs ?? []
            album.songs = sortedTracks(known)
            return album
        }
        return nil
    }

    static func sortedTracks(_ songs: [Song]) -> [Song] {
        songs.enumerated()
            .sorted { ($0.element.track ?? Int.max, $0.offset) < ($1.element.track ?? Int.max, $1.offset) }
            .map(\.element)
    }

    /// The artist page's albums from the saved library, Flutter's order (newest first, as the server
    /// gives `getArtist`'s), and by name where there's no year.
    static func artistAlbums(artistID: String, libraryAlbums: [Album]) -> [Album] {
        libraryAlbums.filter { $0.artistID == artistID || $0.artists?.contains { $0.id == artistID } == true }
            .sorted { ($0.year ?? 0, $1.name.lowercased()) > ($1.year ?? 0, $0.name.lowercased()) }
    }

    /// Flutter `_searchLocal`: the title, artist or album contains the text, 50 songs at most.
    static func search(_ songs: [Song], query: String) -> [Song] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        return Array(songs.filter {
            $0.title.lowercased().contains(query)
                || ($0.artist?.lowercased().contains(query) ?? false)
                || ($0.album?.lowercased().contains(query) ?? false)
        }.prefix(50))
    }

    /// Flutter's offline Home (`home_screen.dart`, `isOffline`): recent albums with a downloaded
    /// song, playlists with every song downloaded, and song rows of downloaded songs only. Artists
    /// stay as they are.
    struct Home: Equatable {
        var latestAlbums: [Album]
        var playlists: [Playlist]
        var feed: HomeFeed
    }

    static func home(
        latestAlbums: [Album],
        playlists: [Playlist],
        feed: HomeFeed,
        downloadedIDs: Set<String>,
        downloadedAlbumIDs: Set<String>,
        isPlaylistDownloaded: (Playlist) -> Bool
    ) -> Home {
        func keep(_ songs: [Song]) -> [Song] { songs.filter { downloadedIDs.contains($0.id) } }
        var filtered = feed
        filtered.personalized = keep(feed.personalized)
        filtered.replayPicks = keep(feed.replayPicks)
        filtered.heavyRotation = keep(feed.heavyRotation)
        filtered.mixes = feed.mixes.compactMap { mix in
            var mix = mix
            mix.songs = keep(mix.songs)
            return mix.songs.isEmpty ? nil : mix
        }
        return Home(
            latestAlbums: latestAlbums.filter { downloadedAlbumIDs.contains($0.id) },
            playlists: playlists.filter(isPlaylistDownloaded),
            feed: filtered
        )
    }

    /// Offline, a list played from a page holds only what can play; the tapped song keeps its place.
    static func playable(_ list: [Song], tapped index: Int?, isDownloaded: (String) -> Bool) -> (songs: [Song], index: Int?) {
        var songs: [Song] = []
        var newIndex: Int?
        for (position, song) in list.enumerated() where isDownloaded(song.id) {
            if position == index { newIndex = songs.count }
            songs.append(song)
        }
        return (songs, newIndex)
    }
}

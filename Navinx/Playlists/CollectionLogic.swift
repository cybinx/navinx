import Foundation
import SubsonicKit

/// Editing a playlist's songs, which go by place since a playlist can hold a song twice.
nonisolated enum PlaylistEditing {
    /// The playlist with these songs, its count and length brought up to date.
    static func updated(_ playlist: Playlist, songs: [Song]) -> Playlist {
        var playlist = playlist
        playlist.songs = songs
        playlist.songCount = songs.count
        playlist.duration = songs.reduce(0) { $0 + ($1.duration ?? 0) }
        return playlist
    }

    static func removing(_ indexes: Set<Int>, from songs: [Song]) -> [Song] {
        songs.enumerated().filter { !indexes.contains($0.offset) }.map(\.element)
    }

    /// The selection once one row has gone: the rows below it have moved up one.
    static func selection(_ selected: Set<Int>, afterRemoving index: Int) -> Set<Int> {
        Set(selected.compactMap { $0 == index ? nil : ($0 > index ? $0 - 1 : $0) })
    }

    /// An ID per row that stays with its song when others are removed, even for a song listed twice.
    static func rowIDs(_ songs: [Song]) -> [String] {
        var seen: [String: Int] = [:]
        return songs.map { song in
            let count = seen[song.id, default: 0]
            seen[song.id] = count + 1
            return "\(song.id)#\(count)"
        }
    }
}

nonisolated enum SongCollectionLogic {
    /// Flutter `FormatUtils.formatDurationSummary`: "1 hr 5 min", "2 hr", "42 min".
    static func durationSummary(_ songs: [Song]) -> String {
        let total = songs.reduce(0) { $0 + ($1.duration ?? 0) }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours) hr \(minutes) min" : "\(hours) hr" }
        return "\(minutes) min"
    }

    /// Flutter's History: songs played at least once and still in the library, latest first, at most 100.
    static func history(profiles: [String: ListeningRecord], allSongs: [Song]) -> [Song] {
        let byID = Dictionary(allSongs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return profiles.values
            .filter { $0.playCount > 0 && byID[$0.songID] != nil }
            .sorted { $0.lastPlayed > $1.lastPlayed }
            .prefix(100)
            .compactMap { byID[$0.songID] }
    }

    /// Whether this iPhone has played anything, whatever the library holds (History's own records).
    static func hasPlays(_ profiles: [String: ListeningRecord]) -> Bool {
        profiles.values.contains { $0.playCount > 0 }
    }

    /// What History shows when its list is empty.
    enum EmptyPage: Equatable {
        /// The library is still being loaded: the page's spinner.
        case loading
        /// Flutter's text: the library has nothing to list.
        case noSongs
        /// Only when nothing was ever played here (C54).
        case nothingPlayed

        var text: String? {
            switch self {
            case .loading: nil
            case .noSongs: "No songs available. Please load your library first."
            case .nothingPlayed: "Nothing played on this iPhone yet."
            }
        }
    }

    /// History says "Nothing played" only when its own records are empty; with plays the list is empty
    /// because the library isn't loaded yet or no longer has those songs, and the page says what it says
    /// for any empty list (C54 part 4).
    static func emptyPage(hasPlays: Bool, libraryReady: Bool) -> EmptyPage {
        if !hasPlays { return .nothingPlayed }
        return libraryReady ? .noSongs : .loading
    }

    /// The same, off the main actor: it looks at every song in the library.
    @concurrent static func historyInBackground(profiles: [String: ListeningRecord], allSongs: [Song]) async -> [Song] {
        history(profiles: profiles, allSongs: allSongs)
    }
}

/// The album pages' A–Z index.
nonisolated enum AlbumIndex {
    static let letters = (65...90).map { String(UnicodeScalar($0)) } + ["#"]
    /// Flutter shows the index from this many albums.
    static let minimumAlbums = 8

    /// The first album under a letter, in the list's own order; "#" is whatever doesn't start with A–Z.
    static func firstAlbum(_ letter: String, in albums: [Album]) -> Album? {
        albums.first { album in
            let name = album.name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard let first = name.first else { return false }
            return letter == "#" ? !("A"..."Z").contains(String(first)) : name.hasPrefix(letter)
        }
    }
}

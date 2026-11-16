import Foundation
import SubsonicKit

/// Search's filter chips, in Flutter's order.
nonisolated enum SearchFilter: CaseIterable, Hashable {
    case all, songs, artists, albums, playlists

    var title: String {
        switch self {
        case .all: "All"
        case .songs: "Songs"
        case .artists: "Artists"
        case .albums: "Albums"
        case .playlists: "Playlists"
        }
    }
}

/// What Flutter `_buildSearchResults` shows for a result and a filter.
nonisolated struct SearchSections: Equatable {
    enum TopResult: Equatable {
        case artist(Artist), song(Song), album(Album)
    }

    var topResult: TopResult?
    var songs: [Song] = []
    var artists: [Artist] = []
    var albums: [Album] = []
    var playlists: [Playlist] = []
    /// Nothing matched at all, whatever the filter: Flutter's "No results found".
    var isEmpty = false

    /// Nothing to show under the chosen filter, though another one may have matches.
    var showsNothing: Bool {
        topResult == nil && songs.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty
    }

    init(result: SearchResult, playlists allPlaylists: [Playlist], query: String, filter: SearchFilter) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matching = allPlaylists.filter { $0.name.lowercased().contains(query) }
        isEmpty = result.isEmpty && matching.isEmpty
        guard !isEmpty else { return }

        // Flutter shows a top result under All and Songs only; under Songs, artists can't take it.
        if filter == .all || filter == .songs {
            if filter == .all, let artist = result.artists.first {
                topResult = .artist(artist)
            } else if let song = result.songs.first {
                topResult = .song(song)
            } else if let album = result.albums.first {
                topResult = .album(album)
            }
        }
        if filter == .all || filter == .songs { songs = Array(result.songs.prefix(filter == .all ? 5 : 20)) }
        if filter == .all || filter == .artists { artists = result.artists }
        if filter == .all || filter == .albums { albums = result.albums }
        if filter == .all || filter == .playlists { playlists = matching }
    }
}

/// What Search shows with nothing searched (D210): the recent searches when there are any, otherwise
/// a quiet prompt saying what can be searched.
nonisolated enum SearchIdleState: Equatable {
    case recents
    case prompt(detail: String)

    static let promptTitle = "Search your library"

    /// `searchesServer` is whether a search goes to the server; without one it looks through the
    /// downloaded songs and the playlists kept from the last sync, by name.
    init(hasRecents: Bool, searchesServer: Bool) {
        if hasRecents {
            self = .recents
        } else {
            self = .prompt(detail: searchesServer ? "Songs, albums, artists and playlists" : "Downloaded songs and playlists")
        }
    }
}

/// Flutter's recent searches: newest first, at most 8, for this run of the app.
nonisolated struct RecentSearches: Equatable {
    private(set) var queries: [String] = []

    /// A search that is run again moves to the front instead of staying where it was.
    mutating func add(_ query: String) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        queries.removeAll { $0 == query }
        queries.insert(query, at: 0)
        if queries.count > 8 { queries.removeLast() }
    }

    mutating func remove(_ query: String) {
        queries.removeAll { $0 == query }
    }

    mutating func clear() {
        queries = []
    }
}

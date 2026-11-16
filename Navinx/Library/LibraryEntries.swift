import Foundation
import SubsonicKit

/// How the Library's playlists are ordered (D21); what has no such information keeps the server's
/// order, after what has it.
/// - `recents`: by last changed.
/// - `latestAdditions`: newest first.
/// - `creator`: by owner, then name.
nonisolated enum LibrarySort: CaseIterable, Hashable {
    case recents, latestAdditions, alphabetical, creator

    var title: String {
        switch self {
        case .recents: "Recents"
        case .latestAdditions: "Recently added"
        case .alphabetical: "Alphabetical"
        case .creator: "Creator"
        }
    }
}

nonisolated struct LibraryEntry: Identifiable {
    enum Kind {
        case heartedSongs, offlineSongs
        case playlist(Playlist)
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
}

/// The Library tab's rows (D210): Liked Songs, Downloaded Songs, then the account's playlists.
nonisolated enum LibraryEntries {
    /// What the list is built from. Equatable, so the Library builds it again only when one changes.
    struct Source: Equatable, Sendable {
        var playlists: [Playlist] = []
        /// How many songs are downloaded, for the Downloaded Songs row.
        var downloadedCount = 0
    }

    static func build(sort: LibrarySort, source: Source) -> [LibraryEntry] {
        var items: [LibraryEntry] = [
            .init(id: "heartedSongs", kind: .heartedSongs, title: "Liked Songs", subtitle: "Playlist • Favorites"),
            .init(
                id: "offlineSongs",
                kind: .offlineSongs,
                title: "Downloaded Songs",
                subtitle: "\(CountText.of(source.downloadedCount, "song")) saved offline"
            ),
        ]
        items += sortedPlaylists(source.playlists, sort).map {
            .init(id: "playlist-\($0.id)", kind: .playlist($0), title: $0.name, subtitle: "Playlist • \(CountText.of($0.songCount ?? 0, "song"))")
        }
        return items
    }

    /// The same, off the main actor.
    @concurrent static func buildInBackground(sort: LibrarySort, source: Source) async -> [LibraryEntry] {
        build(sort: sort, source: source)
    }

    /// Offline, Liked Songs (the server's list) is greyed out, and opens to say it needs the server
    /// (D52). Downloaded Songs and the playlists stay as they are.
    static func isGreyed(_ kind: LibraryEntry.Kind, isOffline: Bool) -> Bool {
        guard isOffline else { return false }
        if case .heartedSongs = kind { return true }
        return false
    }

    // MARK: Sorting

    private static func sortedPlaylists(_ list: [Playlist], _ sort: LibrarySort) -> [Playlist] {
        switch sort {
        case .recents: ordered(list, descending: true) { $0.changed }
        case .latestAdditions: ordered(list, descending: true) { $0.created }
        case .alphabetical: ordered(list) { $0.name.lowercased() }
        case .creator: ordered(list) { creatorKey($0.owner, $0.name) }
        }
    }

    private static func creatorKey(_ creator: String?, _ name: String) -> String? {
        creator.map { "\($0.lowercased())\u{0}\(name.lowercased())" }
    }

    /// A stable sort on a key worked out once per item; items without a key go last, in their order.
    private static func ordered<T, Key: Comparable>(_ list: [T], descending: Bool = false, by key: (T) -> Key?) -> [T] {
        list.enumerated()
            .map { (item: $0.element, offset: $0.offset, key: key($0.element)) }
            .sorted { a, b in
                switch (a.key, b.key) {
                case let (x?, y?) where x != y: descending ? x > y : x < y
                case (_?, nil): true
                case (nil, _?): false
                default: a.offset < b.offset
                }
            }
            .map(\.item)
    }
}

extension Artist {
    /// The artist's identity in a list (`ForEach`, a row's ID). The server's ID alone isn't one:
    /// `SubsonicClient.artists()` turns a combined name ("Simon & Garfunkel") into one artist per
    /// name, all with that entry's ID. Names are unique there, so ID and name together are. Pages
    /// and requests still use `id`.
    nonisolated var listKey: String { "\(id)\u{0}\(name)" }
}

extension [LibraryRoute] {
    /// Pushes `route` unless it is already on top: a second tap on a toolbar button while its page
    /// is still sliding in would push it twice.
    mutating func pushOnce(_ route: LibraryRoute) {
        if last != route { append(route) }
    }
}

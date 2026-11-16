import AppIntents
import CoreSpotlight
import Foundation
import SharedKit
import SubsonicKit

// The library as Siri, Shortcuts and Spotlight see it (C39): albums, artists and playlists, found in
// the saved library first (so it answers offline and at once), then on the server when signed in.
// No entity carries an address: a cover is the cached picture's bytes or nothing (a server's cover
// address holds the login).

nonisolated struct AlbumEntity: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Album"
    static let defaultQuery = AlbumQuery()

    let id: String
    let name: String
    let artist: String?
    /// A small cover for Spotlight, only when indexing.
    var artwork: Data?

    init(id: String, name: String, artist: String?, artwork: Data? = nil) {
        self.id = id
        self.name = name
        self.artist = artist
        self.artwork = artwork
    }

    init(_ album: Album) {
        self.init(id: album.id, name: album.name, artist: album.artist)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: artist.map { "\($0)" },
            image: artwork.map { DisplayRepresentation.Image(data: $0) }
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.title = name
        set.displayName = name
        set.artist = artist
        set.album = name
        set.thumbnailData = artwork
        return set
    }
}

nonisolated struct ArtistEntity: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Artist"
    static let defaultQuery = ArtistQuery()

    /// One per name: `SubsonicClient.artists()` gives each name of a combined one ("Simon & Garfunkel")
    /// the entry's server ID, so the ID alone would make them one entity and one Spotlight item. A
    /// Shortcut saved before carries the server ID alone, which still finds the artist (`ArtistQuery`).
    let id: String
    /// The server's ID, which the page and the songs are asked by.
    let artistID: String
    let name: String
    var artwork: Data?

    init(artistID: String, name: String, artwork: Data? = nil) {
        id = Self.identifier(artistID: artistID, name: name)
        self.artistID = artistID
        self.name = name
        self.artwork = artwork
    }

    init(_ artist: Artist) {
        self.init(artistID: artist.id, name: artist.name)
    }

    static func identifier(artistID: String, name: String) -> String { "\(artistID)|\(name)" }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: artwork.map { DisplayRepresentation.Image(data: $0) })
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.title = name
        set.displayName = name
        set.artist = name
        set.thumbnailData = artwork
        return set
    }
}

// `PlaylistEntity` and its query are `SharedKit`'s (C40): the Playlist widget offers them too.
extension PlaylistEntity {
    nonisolated init(_ playlist: Playlist) {
        self.init(id: playlist.id, name: playlist.name)
    }
}

// MARK: Queries

nonisolated struct AlbumQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [AlbumEntity] {
        guard let library = await SavedLibrary.shared.lists() else { return [] }
        let byID = Dictionary(library.albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { byID[$0].map(AlbumEntity.init) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [AlbumEntity] {
        let saved = await SavedLibrary.shared.lists()?.albums ?? []
        var found = LibraryMatching.rank(saved, name: \.name, matching: string)
        if found.isEmpty, let client = IntentServices.shared?.account.client,
           let result = try? await client.search(string, artistCount: 0, albumCount: 20, songCount: 0) {
            found = LibraryMatching.rank(result.albums, name: \.name, matching: string, keepsUnmatched: true)
        }
        return found.map(AlbumEntity.init)
    }

    /// The albums played most recently, as Home shows them.
    @MainActor
    func suggestedEntities() async throws -> [AlbumEntity] {
        (await SavedLibrary.shared.lists()?.latestAlbums ?? []).prefix(20).map(AlbumEntity.init)
    }
}

nonisolated struct ArtistQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ArtistEntity] {
        guard let library = await SavedLibrary.shared.lists() else { return [] }
        return Self.resolve(identifiers, among: library.artists.map(ArtistEntity.init))
    }

    /// The whole key first; then the server ID alone (a Shortcut saved before the entities had one
    /// per name), or the key's part before its first `|` (the artist renamed since): its first name.
    static func resolve(_ identifiers: [String], among entities: [ArtistEntity]) -> [ArtistEntity] {
        let byKey = Dictionary(entities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byID = Dictionary(entities.map { ($0.artistID, $0) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { identifier in
            byKey[identifier] ?? byID[identifier]
                ?? identifier.split(separator: "|", maxSplits: 1).first.flatMap { byID[String($0)] }
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [ArtistEntity] {
        let saved = await SavedLibrary.shared.lists()?.artists ?? []
        var found = LibraryMatching.rank(saved, name: \.name, matching: string)
        if found.isEmpty, let client = IntentServices.shared?.account.client,
           let result = try? await client.search(string, artistCount: 20, albumCount: 0, songCount: 0) {
            found = LibraryMatching.rank(result.artists, name: \.name, matching: string, keepsUnmatched: true)
        }
        return found.map(ArtistEntity.init)
    }

    /// The artists of the albums played most recently.
    @MainActor
    func suggestedEntities() async throws -> [ArtistEntity] {
        guard let library = await SavedLibrary.shared.lists() else { return [] }
        return LibraryMatching.recentArtists(library).map(ArtistEntity.init)
    }
}

// MARK: The saved library

/// The lists of the saved library (`LibraryCache`) of the server signed in, read without a
/// `LibraryModel`, so they answer with no window and offline. The songs aren't kept here.
@MainActor
final class SavedLibrary {
    static let shared = SavedLibrary()

    nonisolated struct Lists: Sendable {
        var albums: [Album]
        var latestAlbums: [Album]
        var artists: [Artist]
        var playlists: [Playlist]
    }

    /// Whose library is read: the profile (the saved copy's name) and, once signed in, which account
    /// it is (`AccountKey.mark`), so a copy another account left under the same profile isn't used.
    nonisolated struct Owner: Equatable {
        var profileID: String
        var account: String?
    }

    private var kept: (owner: Owner, lists: Lists)?
    /// The one signed in, or the one saved as signed in (before the sign-in, with no account to check).
    var owner: @MainActor () -> Owner? = {
        guard let account = IntentServices.shared?.account, let id = account.storedProfileID else { return nil }
        return Owner(profileID: id.uuidString, account: account.active?.accountKey.mark)
    }

    func lists() async -> Lists? {
        guard let owner = owner() else { return nil }
        if let kept, kept.owner == owner { return kept.lists }
        guard let snapshot = await LibraryCache.standard.load(key: owner.profileID, account: owner.account) else { return nil }
        let lists = Self.lists(from: snapshot)
        kept = (owner, lists)
        return lists
    }

    /// Every song of the saved library, read afresh (Shuffle Library).
    func allSongs() async -> [Song] {
        guard let owner = owner() else { return [] }
        return await LibraryCache.standard.load(key: owner.profileID, account: owner.account)?.allSongs ?? []
    }

    /// After a sync's save or a sign-out.
    func forget() {
        kept = nil
    }

    nonisolated static func lists(from snapshot: LibrarySnapshot) -> Lists {
        Lists(
            albums: LibraryMatching.unique(snapshot.allAlbums + snapshot.latestAlbums),
            latestAlbums: snapshot.latestAlbums,
            artists: snapshot.artists,
            playlists: snapshot.playlists
        )
    }
}

/// Finding a spoken or typed name among the library's (pure, for the tests).
nonisolated enum LibraryMatching {
    /// The items whose name holds `text` (case and accents ignored): the same name first, then names
    /// starting with it, then the rest; at most `limit`. `keepsUnmatched`: the server's search found them,
    /// so those it found by other words come last rather than going.
    static func rank<Item>(
        _ items: [Item],
        name: (Item) -> String,
        matching text: String,
        limit: Int = 50,
        keepsUnmatched: Bool = false
    ) -> [Item] {
        let wanted = fold(text)
        guard !wanted.isEmpty else { return [] }
        var ranked: [(rank: Int, index: Int)] = []
        for (index, item) in items.enumerated() {
            let candidate = fold(name(item))
            let rank: Int
            if candidate == wanted {
                rank = 0
            } else if candidate.hasPrefix(wanted) {
                rank = 1
            } else if candidate.contains(wanted) {
                rank = 2
            } else if keepsUnmatched {
                rank = 3
            } else {
                continue
            }
            ranked.append((rank, index))
        }
        return ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.prefix(limit).map { items[$0.index] }
    }

    /// Lowercased, without accents or the spaces at either end.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first of each ID, in order.
    static func unique<Item: Identifiable>(_ items: [Item]) -> [Item] where Item.ID == String {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    /// The artists of the recent albums, in their order, that the library lists; at most 20. A combined
    /// name's album brings each of its names (they share its ID, `Artist.listKey`).
    static func recentArtists(_ lists: SavedLibrary.Lists) -> [Artist] {
        let byID = Dictionary(grouping: lists.artists, by: \.id)
        let ids = lists.latestAlbums.compactMap(\.artistID)
        var seenIDs = Set<String>()
        var seenKeys = Set<String>()
        let artists = ids.filter { seenIDs.insert($0).inserted }
            .flatMap { byID[$0] ?? [] }
            .filter { seenKeys.insert($0.listKey).inserted }
        return Array(artists.prefix(20))
    }
}

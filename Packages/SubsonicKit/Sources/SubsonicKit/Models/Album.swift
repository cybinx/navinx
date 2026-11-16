import Foundation

/// An album (ID3 `album`). Flutter: `lib/models/album.dart`. `songs` is filled by `getAlbum` and
/// empty in lists.
public struct Album: Sendable, Hashable, Identifiable, Decodable {
    public var id: String
    public var name: String
    public var artist: String?
    public var artistID: String?
    public var coverArt: String?
    public var songCount: Int?
    /// Seconds.
    public var duration: Int?
    public var year: Int?
    public var genre: String?
    public var created: Date?
    /// Credited artists (OpenSubsonic `artists`), with combined names split; nil if none.
    public var artists: [ArtistCredit]?
    public var starred: Bool
    public var songs: [Song]

    public init(
        id: String,
        name: String,
        artist: String? = nil,
        artistID: String? = nil,
        coverArt: String? = nil,
        songCount: Int? = nil,
        duration: Int? = nil,
        year: Int? = nil,
        genre: String? = nil,
        created: Date? = nil,
        artists: [ArtistCredit]? = nil,
        starred: Bool = false,
        songs: [Song] = []
    ) {
        self.id = id
        self.name = name
        self.artist = artist
        self.artistID = artistID
        self.coverArt = coverArt
        self.songCount = songCount
        self.duration = duration
        self.year = year
        self.genre = genre
        self.created = created
        self.artists = artists
        self.starred = starred
        self.songs = songs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        id = c.string("id") ?? ""
        name = c.string("name") ?? c.string("album") ?? "Unknown Album"
        artist = c.string("artist")
        artistID = c.string("artistId")
        coverArt = c.string("coverArt")
        songCount = c.int("songCount")
        duration = c.int("duration")
        year = c.int("year")
        genre = c.string("genre")
        created = c.date("created")
        artists = ArtistCredit.expand(c.list("artists"))
        starred = c.has("starred")
        songs = c.list("song") ?? []
    }

    /// `m:ss`, or empty without a duration (Flutter `Album.formattedDuration`).
    public var formattedDuration: String {
        guard let duration else { return "" }
        return "\(duration / 60):" + String(format: "%02d", duration % 60)
    }

    /// The artists to show: credited artists, else `artist` split, else `artistID`.
    public var displayArtists: [ArtistCredit] {
        ArtistCredit.list(artists, fallbackName: artist, fallbackID: artistID)
    }
}

/// The `getAlbumList2` orders the Flutter app uses.
public enum AlbumListType: String, Sendable, CaseIterable {
    case recent
    case newest
    case frequent
    case highest
    case random
    case starred
    case alphabeticalByName
}

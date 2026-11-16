import Foundation

/// An artist (ID3 `artist`). Flutter: `lib/models/artist.dart`. `albums` is filled by `getArtist`
/// and empty in lists.
public struct Artist: Sendable, Hashable, Identifiable, Decodable {
    public var id: String
    public var name: String
    public var coverArt: String?
    public var albumCount: Int?
    /// A full image URL from the server (Navidrome's `/share/img/…`), not a cover-art ID.
    public var artistImageURL: String?
    public var artists: [ArtistCredit]?
    public var albums: [Album]

    public init(
        id: String,
        name: String,
        coverArt: String? = nil,
        albumCount: Int? = nil,
        artistImageURL: String? = nil,
        artists: [ArtistCredit]? = nil,
        albums: [Album] = []
    ) {
        self.id = id
        self.name = name
        self.coverArt = coverArt
        self.albumCount = albumCount
        self.artistImageURL = artistImageURL
        self.artists = artists
        self.albums = albums
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        id = c.string("id") ?? ""
        name = c.string("name") ?? "Unknown Artist"
        coverArt = c.string("coverArt")
        albumCount = c.int("albumCount")
        artistImageURL = c.string("artistImageUrl")
        artists = ArtistCredit.expand(c.list("artists"))
        albums = c.list("album") ?? []
    }
}

/// Biography and images from `getArtistInfo2` (Last.fm through the server).
/// Flutter: `lib/models/artist_info.dart`.
public struct ArtistInfo: Sendable, Hashable, Decodable {
    public var biography: String?
    public var musicBrainzID: String?
    public var lastFmURL: String?
    public var smallImageURL: String?
    public var mediumImageURL: String?
    public var largeImageURL: String?
    /// Artists like this one that are in the library (`getArtistInfo2`'s `similarArtist`, filled by
    /// the server from Last.fm); empty when it sends none. Entries with no ID are dropped.
    public var similarArtists: [Artist]

    public init(
        biography: String? = nil,
        musicBrainzID: String? = nil,
        lastFmURL: String? = nil,
        smallImageURL: String? = nil,
        mediumImageURL: String? = nil,
        largeImageURL: String? = nil,
        similarArtists: [Artist] = []
    ) {
        self.biography = biography
        self.musicBrainzID = musicBrainzID
        self.lastFmURL = lastFmURL
        self.smallImageURL = smallImageURL
        self.mediumImageURL = mediumImageURL
        self.largeImageURL = largeImageURL
        self.similarArtists = similarArtists
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        biography = c.string("biography")
        musicBrainzID = c.string("musicBrainzId")
        lastFmURL = c.string("lastFmUrl")
        smallImageURL = c.string("smallImageUrl")
        mediumImageURL = c.string("mediumImageUrl")
        largeImageURL = c.string("largeImageUrl")
        // "-1" is how Navidrome marks an artist not in the library (asked for with `includeNotPresent`).
        similarArtists = (c.list("similarArtist", of: Artist.self) ?? []).filter { !$0.id.isEmpty && $0.id != "-1" }
    }
}

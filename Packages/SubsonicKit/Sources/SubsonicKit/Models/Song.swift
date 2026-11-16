import Foundation

/// ReplayGain values in dB (gains) and linear peaks. Flutter: the `replayGain*` fields on `Song`.
public struct ReplayGain: Sendable, Hashable {
    public var trackGain: Double?
    public var albumGain: Double?
    public var trackPeak: Double?
    public var albumPeak: Double?

    public init(trackGain: Double? = nil, albumGain: Double? = nil, trackPeak: Double? = nil, albumPeak: Double? = nil) {
        self.trackGain = trackGain
        self.albumGain = albumGain
        self.trackPeak = trackPeak
        self.albumPeak = albumPeak
    }

    public var isEmpty: Bool {
        trackGain == nil && albumGain == nil && trackPeak == nil && albumPeak == nil
    }
}

/// A song (Subsonic "child"). Flutter: `lib/models/song.dart`, without its local-files `isLocal` (D4).
public struct Song: Sendable, Hashable, Identifiable, Decodable {
    public var id: String
    public var title: String
    public var album: String?
    public var albumID: String?
    public var artist: String?
    public var artistID: String?
    public var track: Int?
    /// The disc, on a set of more than one (C19: the next track of the same album stays gapless).
    public var discNumber: Int?
    public var year: Int?
    public var genre: String?
    public var coverArt: String?
    /// Seconds.
    public var duration: Int?
    /// kbps.
    public var bitRate: Int?
    public var suffix: String?
    public var contentType: String?
    /// Bytes.
    public var size: Int?
    public var path: String?
    public var starred: Bool
    public var userRating: Int?
    public var replayGain: ReplayGain
    /// Credited artists (OpenSubsonic `artists`), with combined names split; nil if none.
    public var artists: [ArtistCredit]?
    public var created: Date?
    public var hasDolbyAtmos: Bool?
    /// How often this user has played it, from every app that scrobbles (Navidrome's all-time count;
    /// C23's Playback ranks by it). Nil when the server doesn't say.
    public var playCount: Int?
    /// When this user last played it (Navidrome's `played`).
    public var played: Date?
    /// Hz (OpenSubsonic). Navidrome sends 0 for what it doesn't know.
    public var samplingRate: Int?
    /// Bits per sample (OpenSubsonic). Navidrome sends 0 for lossy files such as MP3.
    public var bitDepth: Int?
    /// OpenSubsonic `channelCount`: 1 mono, 2 stereo.
    public var channelCount: Int?

    public init(
        id: String,
        title: String,
        album: String? = nil,
        albumID: String? = nil,
        artist: String? = nil,
        artistID: String? = nil,
        track: Int? = nil,
        discNumber: Int? = nil,
        year: Int? = nil,
        genre: String? = nil,
        coverArt: String? = nil,
        duration: Int? = nil,
        bitRate: Int? = nil,
        suffix: String? = nil,
        contentType: String? = nil,
        size: Int? = nil,
        path: String? = nil,
        starred: Bool = false,
        userRating: Int? = nil,
        replayGain: ReplayGain = ReplayGain(),
        artists: [ArtistCredit]? = nil,
        created: Date? = nil,
        hasDolbyAtmos: Bool? = nil,
        playCount: Int? = nil,
        played: Date? = nil,
        samplingRate: Int? = nil,
        bitDepth: Int? = nil,
        channelCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.album = album
        self.albumID = albumID
        self.artist = artist
        self.artistID = artistID
        self.track = track
        self.discNumber = discNumber
        self.year = year
        self.genre = genre
        self.coverArt = coverArt
        self.duration = duration
        self.bitRate = bitRate
        self.suffix = suffix
        self.contentType = contentType
        self.size = size
        self.path = path
        self.starred = starred
        self.userRating = userRating
        self.replayGain = replayGain
        self.artists = artists
        self.created = created
        self.hasDolbyAtmos = hasDolbyAtmos
        self.playCount = playCount
        self.played = played
        self.samplingRate = samplingRate
        self.bitDepth = bitDepth
        self.channelCount = channelCount
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        id = c.string("id") ?? ""
        title = c.string("title") ?? "Unknown Title"
        album = c.string("album")
        albumID = c.string("albumId")
        artist = c.string("artist")
        artistID = c.string("artistId")
        track = c.int("track")
        discNumber = c.int("discNumber")
        year = c.int("year")
        genre = c.string("genre")
        coverArt = c.string("coverArt")
        duration = c.int("duration")
        bitRate = c.int("bitRate")
        suffix = c.string("suffix")
        contentType = c.string("contentType")
        size = c.int("size")
        path = c.string("path")
        starred = c.has("starred")
        userRating = c.int("userRating")

        // OpenSubsonic's `replayGain` object first, then the flat names other servers use.
        let nested = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("replayGain"))
        func gain(_ nestedKey: String, _ flatKeys: String...) -> Double? {
            if let value = nested?.double(nestedKey) { return value }
            for key in flatKeys {
                if let value = c.double(key) { return value }
            }
            return nil
        }
        replayGain = ReplayGain(
            trackGain: gain("trackGain", "replayGainTrackGain", "trackGain", "rgTrackGain"),
            albumGain: gain("albumGain", "replayGainAlbumGain", "albumGain", "rgAlbumGain"),
            trackPeak: gain("trackPeak", "replayGainTrackPeak", "trackPeak", "rgTrackPeak"),
            albumPeak: gain("albumPeak", "replayGainAlbumPeak", "albumPeak", "rgAlbumPeak")
        )

        artists = ArtistCredit.expand(c.list("artists"))
        created = c.date("created")
        hasDolbyAtmos = c.bool("hasDolbyAtmos")
        playCount = c.int("playCount")
        played = c.date("played")
        samplingRate = c.int("samplingRate")
        bitDepth = c.int("bitDepth")
        channelCount = c.int("channelCount")
    }

    /// `m:ss`, or `0:00` without a duration (Flutter `Song.formattedDuration`).
    public var formattedDuration: String {
        guard let duration else { return "0:00" }
        return "\(duration / 60):" + String(format: "%02d", duration % 60)
    }

    /// The artists to show: credited artists, else `artist` split, else `artistID`.
    public var displayArtists: [ArtistCredit] {
        ArtistCredit.list(artists, fallbackName: artist, fallbackID: artistID)
    }
}

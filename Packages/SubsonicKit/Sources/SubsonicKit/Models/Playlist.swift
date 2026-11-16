import Foundation

/// A playlist. Flutter: `lib/models/playlist.dart`. `songs` is nil in `getPlaylists` and filled
/// by `getPlaylist`.
public struct Playlist: Sendable, Hashable, Identifiable, Decodable {
    public var id: String
    public var name: String
    public var comment: String?
    public var owner: String?
    public var isPublic: Bool?
    public var songCount: Int?
    /// Seconds.
    public var duration: Int?
    public var created: Date?
    public var changed: Date?
    public var coverArt: String?
    public var songs: [Song]?

    public init(
        id: String,
        name: String,
        comment: String? = nil,
        owner: String? = nil,
        isPublic: Bool? = nil,
        songCount: Int? = nil,
        duration: Int? = nil,
        created: Date? = nil,
        changed: Date? = nil,
        coverArt: String? = nil,
        songs: [Song]? = nil
    ) {
        self.id = id
        self.name = name
        self.comment = comment
        self.owner = owner
        self.isPublic = isPublic
        self.songCount = songCount
        self.duration = duration
        self.created = created
        self.changed = changed
        self.coverArt = coverArt
        self.songs = songs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        id = c.string("id") ?? ""
        name = c.string("name") ?? "Unknown Playlist"
        comment = c.string("comment")
        owner = c.string("owner")
        isPublic = c.bool("public")
        songCount = c.int("songCount")
        duration = c.int("duration")
        created = c.date("created")
        changed = c.date("changed")
        coverArt = c.string("coverArt")
        songs = c.list("entry")
    }

    /// `1 h 5 min` or `42 min`, or empty without a duration (Flutter `Playlist.formattedDuration`).
    public var formattedDuration: String {
        guard let duration else { return "" }
        let hours = duration / 3600
        let minutes = (duration % 3600) / 60
        return hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
    }
}

import Foundation

/// A music folder (library) from `getMusicFolders`. Flutter: `lib/models/music_folder.dart`.
public struct MusicFolder: Sendable, Hashable, Identifiable, Decodable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        id = c.string("id") ?? ""
        name = c.string("name") ?? "Unknown Folder"
    }
}

/// Artists, albums and songs together: `search3` and `getStarred2`.
public struct SearchResult: Sendable, Hashable {
    public var artists: [Artist]
    public var albums: [Album]
    public var songs: [Song]

    public init(artists: [Artist] = [], albums: [Album] = [], songs: [Song] = []) {
        self.artists = artists
        self.albums = albums
        self.songs = songs
    }

    public var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }
}

extension SearchResult: Decodable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        artists = c.list("artist") ?? []
        albums = c.list("album") ?? []
        songs = c.list("song") ?? []
    }
}

/// What `ping` says about the server. Flutter: `PingResult` in `subsonic_service.dart`.
public struct ServerInfo: Sendable, Hashable {
    /// The server's name for itself (`navidrome`, …), as the server gives it; no type but
    /// OpenSubsonic reads "OpenSubsonic". No server is known by name here (C50).
    public var type: String?
    public var serverVersion: String?
    public var isOpenSubsonic: Bool
    /// The Subsonic API version the server speaks.
    public var apiVersion: String?

    public init(type: String?, serverVersion: String?, isOpenSubsonic: Bool, apiVersion: String?) {
        self.type = type
        self.serverVersion = serverVersion
        self.isOpenSubsonic = isOpenSubsonic
        self.apiVersion = apiVersion
    }
}

// MARK: - Lyrics

/// One set of lyrics from OpenSubsonic's `getLyricsBySongId`.
public struct StructuredLyrics: Sendable, Hashable, Decodable {
    public struct Line: Sendable, Hashable, Decodable {
        /// Milliseconds from the start; nil in unsynced lyrics.
        public var start: Int?
        public var value: String

        public init(start: Int?, value: String) {
            self.start = start
            self.value = value
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.lenient()
            start = c.int("start")
            value = c.string("value") ?? ""
        }
    }

    public var displayArtist: String?
    public var displayTitle: String?
    public var lang: String?
    /// Milliseconds to add to every line's start.
    public var offset: Int
    public var synced: Bool
    public var lines: [Line]

    public init(displayArtist: String? = nil, displayTitle: String? = nil, lang: String? = nil, offset: Int = 0, synced: Bool, lines: [Line]) {
        self.displayArtist = displayArtist
        self.displayTitle = displayTitle
        self.lang = lang
        self.offset = offset
        self.synced = synced
        self.lines = lines
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        displayArtist = c.string("displayArtist")
        displayTitle = c.string("displayTitle")
        lang = c.string("lang")
        offset = c.int("offset") ?? 0
        synced = c.bool("synced") ?? false
        lines = c.list("line") ?? []
    }
}

/// Plain lyrics from the original Subsonic `getLyrics` (by artist and title).
public struct Lyrics: Sendable, Hashable, Decodable {
    public var artist: String?
    public var title: String?
    public var value: String

    public init(artist: String? = nil, title: String? = nil, value: String) {
        self.artist = artist
        self.title = title
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        artist = c.string("artist")
        title = c.string("title")
        value = c.string("value") ?? ""
    }
}

// MARK: - The saved play queue

/// The play queue the server keeps for this account (`getPlayQueue`), as the last app to save it
/// left it: another phone, or another Subsonic app on the same account (C36). One per user.
public struct ServerPlayQueue: Sendable, Hashable, Decodable {
    /// In the order they play. The server leaves out songs no longer in its library.
    public var songs: [Song]
    /// The song playing when it was saved; nil if the server no longer finds it.
    public var currentID: String?
    /// Milliseconds into the current song (the server leaves it out at 0).
    public var positionMs: Int
    /// When it was saved, by the server's clock. Navidrome moves it on every save, even of the same queue.
    public var changed: Date?
    /// The saving app's client name (`c`): "Navinx" for every copy of this app.
    public var changedBy: String?

    public init(songs: [Song], currentID: String?, positionMs: Int, changed: Date? = nil, changedBy: String? = nil) {
        self.songs = songs
        self.currentID = currentID
        self.positionMs = positionMs
        self.changed = changed
        self.changedBy = changedBy
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        songs = c.list("entry") ?? []
        currentID = c.string("current").flatMap { $0.isEmpty ? nil : $0 }
        positionMs = max(c.int("position") ?? 0, 0)
        changed = c.date("changed")
        changedBy = c.string("changedBy").flatMap { $0.isEmpty ? nil : $0 }
    }
}

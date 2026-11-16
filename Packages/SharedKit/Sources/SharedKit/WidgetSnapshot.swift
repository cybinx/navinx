import Foundation
import ImageIO

/// What the app shares with its widgets (C40): one small JSON file in the App Group's folder, with the
/// covers saved beside it as plain picture files. Never a login or an address (a server's cover
/// address carries the login); the extension never signs in.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    /// Someone is signed in (or in offline mode); false: the widgets ask to sign in.
    public var signedIn: Bool
    /// The player's song, playing or paused (the kept song too, D81); nil before anything was played.
    public var nowPlaying: WidgetSong?
    /// Home's Recently Played, at most `WidgetSnapshot.recentLimit`.
    public var latestAlbums: [WidgetItem]
    /// Every playlist (the Playlist widget's choice), the first `WidgetSnapshot.playlistCoverLimit` with covers.
    public var playlists: [WidgetItem]
    /// The playlists are on their way again for the account the last ones were for (signed out and
    /// back in): until they arrive, the Playlist widget keeps showing its chosen playlist's name. False
    /// after any other sign-in, so a playlist chosen under another account isn't shown for this one.
    public var playlistsReloading: Bool

    public static let recentLimit = 8
    public static let playlistCoverLimit = 60

    /// `snapshot.json`'s keys, as the earlier builds wrote them (C43): the app and the widgets of two
    /// builds must read each other's file, so a renamed property must not move them.
    private enum CodingKeys: String, CodingKey {
        case signedIn = "signedIn"
        case nowPlaying = "nowPlaying"
        case latestAlbums = "recentAlbums"
        case playlists = "playlists"
        case playlistsReloading = "playlistsReloading"
    }

    public init(
        signedIn: Bool,
        nowPlaying: WidgetSong? = nil,
        latestAlbums: [WidgetItem] = [],
        playlists: [WidgetItem] = [],
        playlistsReloading: Bool = false
    ) {
        self.signedIn = signedIn
        self.nowPlaying = nowPlaying
        self.latestAlbums = latestAlbums
        self.playlists = playlists
        self.playlistsReloading = playlistsReloading
    }

    /// An earlier build's file has no `playlistsReloading`: read as false.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        signedIn = try container.decode(Bool.self, forKey: .signedIn)
        nowPlaying = try container.decodeIfPresent(WidgetSong.self, forKey: .nowPlaying)
        latestAlbums = try container.decode([WidgetItem].self, forKey: .latestAlbums)
        playlists = try container.decode([WidgetItem].self, forKey: .playlists)
        playlistsReloading = try container.decodeIfPresent(Bool.self, forKey: .playlistsReloading) ?? false
    }

    public static let signedOut = WidgetSnapshot(signedIn: false)

    /// Every cover file the snapshot names.
    public var coverNames: Set<String> {
        var names = Set((latestAlbums + playlists).compactMap(\.cover))
        if let cover = nowPlaying?.cover { names.insert(cover) }
        return names
    }
}

public struct WidgetSong: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var artist: String?
    public var album: String?
    /// A file name in the covers folder.
    public var cover: String?
    public var isPlaying: Bool

    public init(id: String, title: String, artist: String?, album: String?, cover: String?, isPlaying: Bool) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.cover = cover
        self.isPlaying = isPlaying
    }
}

/// An album or a playlist.
public struct WidgetItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// The album's artist; none for a playlist.
    public var subtitle: String?
    /// A file name in the covers folder.
    public var cover: String?

    public init(id: String, name: String, subtitle: String? = nil, cover: String? = nil) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.cover = cover
    }
}

/// The widgets' and controls' kinds, as WidgetKit knows them (a change loses the widgets people added).
public enum WidgetKind {
    public static let nowPlaying = "NowPlaying"
    public static let recentlyPlayed = "RecentlyPlayed"
    public static let playlist = "Playlist"
    public static let shuffleLibrary = "ShuffleLibraryControl"
    public static let playFavorites = "PlayFavoritesControl"
    public static let search = "SearchControl"
}

/// The snapshot's folder: `Widgets/` in the App Group's container, `snapshot.json` and `Covers/`.
public struct WidgetStore: Sendable {
    public static let appGroup = "group.com.cybinx.navinx.shared"

    /// The App Group's, or nil when the build has no App Group (then nothing is shared).
    public static var shared: WidgetStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .map { WidgetStore(directory: $0.appending(path: "Widgets", directoryHint: .isDirectory)) }
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    var snapshotFile: URL { directory.appending(path: "snapshot.json") }
    var coversDirectory: URL { directory.appending(path: "Covers", directoryHint: .isDirectory) }

    /// What the app wrote last; nil if it never did (a new install: the widgets ask to sign in).
    public func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: snapshotFile) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Replaces the snapshot, then removes the covers it no longer names (but `keeping`: covers saved
    /// for a snapshot still being made).
    public func write(_ snapshot: WidgetSnapshot, keeping: Set<String> = []) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: snapshotFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        removeCovers(except: snapshot.coverNames.union(keeping))
    }

    /// Signed out: the widgets ask to sign in, and no cover stays behind.
    public func clear() {
        try? write(.signedOut)
    }

    public func coverURL(_ name: String) -> URL {
        coversDirectory.appending(path: name)
    }

    public func hasCover(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: coverURL(name).path)
    }

    public func saveCover(_ data: Data, name: String) throws {
        try FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
        try data.write(to: coverURL(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// A cover's file name from its Subsonic cover ID (letters, digits, `-` and `_` only).
    public static func coverName(for coverArt: String) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = String(coverArt.map { allowed.contains($0) ? $0 : "_" }.prefix(120))
        guard !cleaned.isEmpty, cleaned.contains(where: { $0 != "_" }) else { return nil }
        return "cover-\(cleaned).jpg"
    }

    /// A cover decoded at no more than `maxPixel` on its long side (a widget has little memory).
    public func coverImage(_ name: String?, maxPixel: Int) -> CGImage? {
        guard let name, let source = CGImageSourceCreateWithURL(coverURL(name) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func removeCovers(except kept: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: coversDirectory.path)) ?? []
        for file in files where !kept.contains(file) {
            try? FileManager.default.removeItem(at: coverURL(file))
        }
    }
}

/// What each widget shows for a snapshot (pure, for the tests).
public enum WidgetContent {
    public enum NowPlaying: Equatable {
        case signedOut
        /// Signed in, nothing played yet.
        case nothing
        case song(WidgetSong)
    }

    public enum Albums: Equatable {
        case signedOut
        case nothing
        case albums([WidgetItem])
    }

    public enum Playlist: Equatable {
        case signedOut
        /// None chosen yet, or the chosen one is gone from the server.
        case choose
        case playlist(WidgetItem)
    }

    public static func nowPlaying(_ snapshot: WidgetSnapshot?) -> NowPlaying {
        guard let snapshot, snapshot.signedIn else { return .signedOut }
        return snapshot.nowPlaying.map(NowPlaying.song) ?? .nothing
    }

    /// The first `count` recent albums.
    public static func latestAlbums(_ snapshot: WidgetSnapshot?, count: Int) -> Albums {
        guard let snapshot, snapshot.signedIn else { return .signedOut }
        let albums = Array(snapshot.latestAlbums.prefix(count))
        return albums.isEmpty ? .nothing : .albums(albums)
    }

    /// The chosen playlist as the snapshot has it now (its name and cover may have changed). While the
    /// same account's playlists are loading again (`playlistsReloading`), the chosen one's name; after
    /// another account's sign-in, "Choose a playlist" until the chosen one turns up in its list.
    public static func playlist(_ snapshot: WidgetSnapshot?, chosen: (id: String, name: String)?) -> Playlist {
        guard let snapshot, snapshot.signedIn else { return .signedOut }
        guard let chosen else { return .choose }
        if let found = snapshot.playlists.first(where: { $0.id == chosen.id }) { return .playlist(found) }
        let isReloading = snapshot.playlists.isEmpty && snapshot.playlistsReloading
        return isReloading ? .playlist(WidgetItem(id: chosen.id, name: chosen.name)) : .choose
    }
}

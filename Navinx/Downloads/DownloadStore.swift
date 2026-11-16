import Foundation
import Lyrics
import SubsonicKit

/// A downloaded song: its details as they were, so the app can show and play it with no server.
nonisolated struct SongRecord: Codable, Sendable, Equatable {
    var song: Song
    /// The audio file's name in `songs/`.
    var file: String
    var downloadedAt: Date
    /// Fetched by Smart Downloads (C37, D144), not asked for by the user: only such a song is ever
    /// removed by them, once nothing wants it. Nil for every song the user downloaded (and before C37).
    var automatic: Bool? = nil
}

/// An album or playlist asked to download (Flutter keys its "playlist downloads" by either ID), or
/// a batch of songs (Favorites' Download All). It keeps the songs it had when asked, and the page's
/// details, so the page can show offline.
nonisolated struct CollectionRecord: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case album, playlist, songs }

    var id: String
    var kind: Kind
    var name: String
    var coverArt: String?
    var songs: [Song]
    /// The album's details, without its songs (they're `songs`).
    var album: Album?
    /// The playlist's details, without its songs.
    var playlist: Playlist?

    init(album: Album, songs: [Song]) {
        var details = album
        details.songs = []
        id = album.id
        kind = .album
        name = album.name
        coverArt = album.coverArt
        self.songs = songs
        self.album = details
    }

    init(playlist: Playlist, songs: [Song]) {
        var details = playlist
        details.songs = nil
        id = playlist.id
        kind = .playlist
        name = playlist.name
        coverArt = playlist.coverArt
        self.songs = songs
        self.playlist = details
    }

    init(batchID: String, name: String, songs: [Song]) {
        id = batchID
        kind = .songs
        self.name = name
        self.songs = songs
    }

    /// The album as the album page wants it, with its songs.
    var fullAlbum: Album? {
        guard var album else { return nil }
        album.songs = songs
        return album
    }

    var fullPlaylist: Playlist? {
        guard var playlist else { return nil }
        playlist.songs = songs
        return playlist
    }
}

/// Everything one server's downloads know, saved as one JSON file.
nonisolated struct DownloadRecords: Codable, Sendable, Equatable {
    var songs: [String: SongRecord] = [:]
    var collections: [String: CollectionRecord] = [:]
    /// Collections waiting to download, oldest first, the running one included. A collection that
    /// ended incomplete stays here, and tries again on the next launch.
    var queue: [String] = []
    /// Covers saved, by their `coverArt` ID.
    var covers: Set<String> = []
    /// Smart Downloads' favourite albums (C37): each album's song IDs as last fetched, so an album
    /// whose songs are all here isn't asked of the server again at every catch-up.
    var smartAlbums: [String: [String]] = [:]
    /// Songs whose download the user removed by hand while Smart Downloads still want them (C47):
    /// they aren't fetched again until the user downloads or favourites them again.
    var removedByHand: Set<String> = []
    /// The file listed songs this build couldn't read (not saved): their files aren't for `tidy` to delete.
    private(set) var hasUnreadableSongs = false

    nonisolated private enum CodingKeys: String, CodingKey { case songs, collections, queue, covers, smartAlbums, removedByHand }

    init() {}

    /// Written as before, but read leniently: a record that can't be read (a kind this build doesn't
    /// know, say) is skipped, not the whole list with it.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let listed = try? container.decodeIfPresent([String: Lenient<SongRecord>].self, forKey: .songs)
        songs = listed?.compactMapValues { $0.value } ?? [:]
        hasUnreadableSongs = listed.map { $0.count != songs.count } ?? container.contains(.songs)
        collections = (try? container.decodeIfPresent([String: Lenient<CollectionRecord>].self, forKey: .collections))?
            .compactMapValues { $0.value } ?? [:]
        queue = (try? container.decodeIfPresent([String].self, forKey: .queue)) ?? []
        covers = (try? container.decodeIfPresent(Set<String>.self, forKey: .covers)) ?? []
        smartAlbums = (try? container.decodeIfPresent([String: [String]].self, forKey: .smartAlbums)) ?? [:]
        removedByHand = (try? container.decodeIfPresent(Set<String>.self, forKey: .removedByHand)) ?? []
    }

    /// Written as before C47 while nothing was removed by hand: the new key is there only with
    /// something in it, so the saved form of everyone else's records doesn't move (the golden test,
    /// which C47 broke by writing an empty list every time; found at C45's join).
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(songs, forKey: .songs)
        try container.encode(collections, forKey: .collections)
        try container.encode(queue, forKey: .queue)
        try container.encode(covers, forKey: .covers)
        try container.encode(smartAlbums, forKey: .smartAlbums)
        if !removedByHand.isEmpty { try container.encode(removedByHand, forKey: .removedByHand) }
    }
}

/// Only each song record's file and size (`hasSongs`), which reads much faster than whole records.
nonisolated private struct SongFiles: Decodable {
    nonisolated struct Record: Decodable {
        var file: String
        var size: Int?

        nonisolated private enum CodingKeys: String, CodingKey { case file, song }
        nonisolated private enum SongKeys: String, CodingKey { case size }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            file = try container.decode(String.self, forKey: .file)
            size = try? container.nestedContainer(keyedBy: SongKeys.self, forKey: .song).decodeIfPresent(Int.self, forKey: .size)
        }
    }

    var songs: [String: Lenient<Record>]?
}

/// A value that reads as nil instead of failing what holds it.
nonisolated private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}

/// Where one server's downloads live: Application Support (not caches, which iOS can empty), left
/// out of backups, one folder per saved server. `records.json` lists them; `songs/`, `covers/` and
/// `lyrics/` hold the files.
nonisolated struct DownloadStore: Sendable {
    static let rootDirectory = URL.applicationSupportDirectory.appending(path: "Downloads", directoryHint: .isDirectory)

    let directory: URL

    init(profileID: String, root: URL = DownloadStore.rootDirectory) {
        directory = root.appending(path: Self.sanitized(profileID), directoryHint: .isDirectory)
    }

    var recordsFile: URL { directory.appending(path: "records.json") }
    var songsDirectory: URL { directory.appending(path: "songs", directoryHint: .isDirectory) }
    var coversDirectory: URL { directory.appending(path: "covers", directoryHint: .isDirectory) }
    var lyricsDirectory: URL { directory.appending(path: "lyrics", directoryHint: .isDirectory) }

    /// Flutter `_sanitizeId`.
    static func sanitized(_ id: String) -> String {
        String(id.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" })
    }

    /// The song's own extension, as AVFoundation may need it (Flutter named every file `.mp3`).
    static func fileName(for song: Song) -> String {
        let suffix = song.suffix.map { sanitized($0.lowercased()) }.flatMap { $0.isEmpty ? nil : $0 } ?? "mp3"
        return "\(sanitized(song.id)).\(suffix)"
    }

    func songFile(_ name: String) -> URL { songsDirectory.appending(path: name) }
    func coverFile(_ coverArt: String) -> URL { coversDirectory.appending(path: "\(Self.sanitized(coverArt)).jpg") }
    func lyricsFile(_ songID: String) -> URL { lyricsDirectory.appending(path: "\(Self.sanitized(songID)).json") }

    /// Flutter `_isFileValid`: at least the size the server gave, else at least 64 KB.
    static func isValid(_ file: URL, expectedSize: Int?) -> Bool {
        isValid(size: (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, expectedSize: expectedSize)
    }

    /// The same for a size already read (nil: no file).
    static func isValid(size: Int?, expectedSize: Int?) -> Bool {
        guard let size else { return false }
        if let expectedSize, expectedSize > 0 { return size >= expectedSize }
        return size >= 65_536
    }

    /// Each file's size in `folder`, by name: one listing, not a look at every file.
    static func fileSizes(in folder: URL) -> [String: Int] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else {
            return [:]
        }
        var sizes: [String: Int] = [:]
        for file in files {
            sizes[file.lastPathComponent] = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
        return sizes
    }

    // MARK: Records

    /// The saved records, keeping only songs whose files are really there (Flutter trusted the list).
    func load() -> DownloadRecords {
        guard let data = try? Data(contentsOf: recordsFile) else { return DownloadRecords() }
        guard var records = try? JSONDecoder().decode(DownloadRecords.self, from: data) else {
            // Moved aside, not overwritten by the next save: the files it lists are still there.
            let aside = directory.appending(path: "records-unreadable-\(Int(Date.now.timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: recordsFile, to: aside)
            return DownloadRecords()
        }
        // One listing of each folder, not a look at every file (this runs on the main thread).
        let songFiles = Self.fileSizes(in: songsDirectory)
        records.songs = records.songs.filter { _, record in
            Self.isValid(size: songFiles[record.file], expectedSize: record.song.size)
        }
        let coverFiles = Self.fileSizes(in: coversDirectory)
        records.covers = records.covers.filter { (coverFiles[coverFile($0).lastPathComponent] ?? 0) > 0 }
        records.queue = records.queue.filter { records.collections[$0] != nil }
        return records
    }

    /// Song files no record lists: a download iOS finished after the app had gone, or one cut off with
    /// it, or a record lost with the app before it was saved. One whose song a collection has is taken
    /// in (a queued collection's run takes its own, with its lyrics and cover); any other is deleted, as
    /// nothing could show or play it. Only for records read from the file (`load`'s), and not when that
    /// file had songs this build couldn't read. Returns whether `records` changed.
    func tidy(_ records: inout DownloadRecords) -> Bool {
        guard !records.hasUnreadableSongs, FileManager.default.fileExists(atPath: recordsFile.path) else { return false }
        let files = Self.fileSizes(in: songsDirectory)
        let recorded = Set(records.songs.values.map(\.file))
        let unrecorded = files.keys.filter { !recorded.contains($0) }
        guard !unrecorded.isEmpty else { return false }
        let queued = Set(records.queue)
        var known: [String: (song: Song, isQueued: Bool)] = [:]
        for collection in records.collections.values {
            let isQueued = queued.contains(collection.id)
            for song in collection.songs {
                let name = Self.fileName(for: song)
                if known[name]?.isQueued != true { known[name] = (song, isQueued) }
            }
        }
        var changed = false
        for name in unrecorded {
            if let entry = known[name], Self.isValid(size: files[name], expectedSize: entry.song.size) {
                guard !entry.isQueued, records.songs[entry.song.id] == nil else { continue }
                records.songs[entry.song.id] = SongRecord(song: entry.song, file: name, downloadedAt: .now)
                changed = true
            } else {
                try? FileManager.default.removeItem(at: songFile(name))
            }
        }
        return changed
    }

    /// The covers whose files aren't pictures (a server's error that came with HTTP 200, saved by an
    /// earlier build): taken as missing, so they're fetched again. Reads each file's header only.
    @concurrent
    func unreadableCovers(_ covers: Set<String>) async -> Set<String> {
        covers.filter { !ArtworkCache.isImage(at: coverFile($0)) }
    }

    /// Whether a cover just fetched is a picture, away from the main thread.
    @concurrent
    func isPicture(coverArt: String) async -> Bool {
        ArtworkCache.isImage(at: coverFile(coverArt))
    }

    func save(_ records: DownloadRecords) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        prepare()
        try? data.write(to: recordsFile, options: .atomic)
    }

    /// Makes the folders, and keeps them out of backups.
    func prepare() {
        let manager = FileManager.default
        for folder in [songsDirectory, coversDirectory, lyricsDirectory] {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        var root = Self.rootDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        var own = directory
        try? own.setResourceValues(values)
    }

    /// Whether this server has a downloaded song, for the unreachable screen's offline mode. Asked on
    /// the main thread, so it reads only each record's file and size, and one listing of the files.
    func hasSongs() -> Bool {
        guard let data = try? Data(contentsOf: recordsFile),
              let listed = (try? JSONDecoder().decode(SongFiles.self, from: data))?.songs, !listed.isEmpty else { return false }
        let files = Self.fileSizes(in: songsDirectory)
        return listed.values.contains { entry in
            entry.value.map { Self.isValid(size: files[$0.file], expectedSize: $0.size) } ?? false
        }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func removeEverything(root: URL = rootDirectory) {
        try? FileManager.default.removeItem(at: root)
    }

    /// Deletes the folders of servers no longer saved. `profileIDs` as `init(profileID:)` takes them;
    /// the root holds nothing but these folders.
    static func removeOrphans(keeping profileIDs: Set<String>, root: URL = rootDirectory) {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        let kept = Set(profileIDs.map(sanitized))
        for item in items where !kept.contains(item.lastPathComponent) {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            try? manager.removeItem(at: item)
        }
    }

    // MARK: Lyrics

    func saveLyrics(_ lines: [LyricLine], songID: String) {
        guard let data = try? JSONEncoder().encode(lines) else { return }
        prepare()
        try? data.write(to: lyricsFile(songID), options: .atomic)
    }

    func lyrics(songID: String) -> [LyricLine]? {
        guard let data = try? Data(contentsOf: lyricsFile(songID)) else { return nil }
        return try? JSONDecoder().decode([LyricLine].self, from: data)
    }

    /// Removes a song's audio and lyrics. Covers are shared, so they stay until everything goes.
    func removeFiles(of record: SongRecord) {
        try? FileManager.default.removeItem(at: songFile(record.file))
        try? FileManager.default.removeItem(at: lyricsFile(record.song.id))
    }

    /// Bytes on disk, for the status rows: a walk through every file, away from the main thread.
    @concurrent
    func measuredSize() async -> Int64 { totalSize() }

    /// Bytes on disk.
    func totalSize() -> Int64 {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}

/// The downloaded covers, for `AlbumArtwork` and the lock screen, which look for a file before the
/// network (Flutter's `art_<coverArt>.jpg`). Readable from any thread.
nonisolated final class OfflineCovers: @unchecked Sendable {
    static let shared = OfflineCovers()

    private let lock = NSLock()
    private var store: DownloadStore?
    private var covers: Set<String> = []

    func set(store: DownloadStore?, covers: Set<String>) {
        lock.withLock {
            self.store = store
            self.covers = covers
        }
    }

    func add(_ coverArt: String) {
        lock.withLock { _ = covers.insert(coverArt) }
    }

    func file(for coverArt: String?) -> URL? {
        guard let coverArt, !coverArt.isEmpty else { return nil }
        return lock.withLock { covers.contains(coverArt) ? store?.coverFile(coverArt) : nil }
    }
}

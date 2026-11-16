import Foundation
import Synchronization
import SubsonicKit

/// One server's library as saved between launches (Flutter keeps it in a local database).
nonisolated struct LibrarySnapshot: Codable, Sendable {
    var savedAt: Date
    var artists: [Artist]
    var latestAlbums: [Album]
    var playlists: [Playlist]
    var allAlbums: [Album]
    var allSongs: [Song]

    /// The cache file's keys, as the earlier builds wrote them (C43): a renamed property must not move
    /// them (a moved key costs one full sync). Changing one needs a move (C43's step 2).
    private enum CodingKeys: String, CodingKey {
        case savedAt = "savedAt"
        case artists = "artists"
        case latestAlbums = "recentAlbums"
        case playlists = "playlists"
        case allAlbums = "allAlbums"
        case allSongs = "allSongs"
    }
}

/// A JSON file per server in the app's caches. It's only a cache: losing it means one full sync.
nonisolated struct LibraryCache: Sendable {
    static let standard = LibraryCache(directory: URL.cachesDirectory.appending(path: "Library", directoryHint: .isDirectory))

    let directory: URL
    /// Counts the clears, so a save that started before one (logout) doesn't write after it.
    private let clears = Clears()

    nonisolated private final class Clears: Sendable {
        let count = Mutex(0)
    }

    init(directory: URL) {
        self.directory = directory
    }

    private func file(_ key: String) -> URL {
        directory.appending(path: "\(key).json")
    }

    /// Taken when a save is asked for, and passed to it: a clear since then wins over the save.
    var generation: Int { clears.count.withLock { $0 } }

    /// Writes `data`, unless the cache was cleared since `generation` (nil: now).
    private func write(_ data: Data, to url: URL, generation: Int?) {
        clears.count.withLock { count in
            guard generation.map({ $0 == count }) ?? true else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// The account (`AccountKey.mark`) the files of `key` were saved for. A profile can be pointed at
    /// another server or username and keep its ID (Edit Server), so the files say whose they are.
    private func accountFile(_ key: String) -> URL {
        directory.appending(path: "\(key)-account")
    }

    private func savedAccount(_ key: String) -> String? {
        (try? Data(contentsOf: accountFile(key))).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// False when the files of `key` were saved for another account than `account` (nil: no check).
    /// Files from before the mark (an earlier build) are taken to be the profile's current account's.
    private func belongs(_ key: String, to account: String?) -> Bool {
        guard let account, let saved = savedAccount(key) else { return true }
        return saved == account
    }

    /// Makes the files of `key` `account`'s: the ones another account saved go (a sync makes them
    /// again), and a save that began before is dropped, as after a clear.
    @concurrent
    func claim(key: String, account: String) async {
        clears.count.withLock { count in
            let saved = savedAccount(key)
            guard saved != account else { return }
            if saved != nil {
                count += 1
                try? FileManager.default.removeItem(at: file(key))
                try? FileManager.default.removeItem(at: file("\(key)-playlists"))
            }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? Data(account.utf8).write(to: accountFile(key), options: .atomic)
        }
    }

    /// The saved copy of `key`; nil if there's none, it can't be read, or it was saved for another
    /// account than `account`.
    @concurrent
    func load(key: String, account: String? = nil) async -> LibrarySnapshot? {
        guard belongs(key, to: account), let data = try? Data(contentsOf: file(key)) else { return nil }
        return try? JSONDecoder().decode(LibrarySnapshot.self, from: data)
    }

    @concurrent
    func save(_ snapshot: LibrarySnapshot, key: String, generation: Int? = nil) async {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        write(data, to: file(key), generation: generation)
    }

    /// Playlists as last opened, with their songs (C10's offline pages).
    @concurrent
    func loadPlaylists(key: String, account: String? = nil) async -> [Playlist] {
        guard belongs(key, to: account), let data = try? Data(contentsOf: file("\(key)-playlists")) else { return [] }
        return (try? JSONDecoder().decode([Playlist].self, from: data)) ?? []
    }

    @concurrent
    func savePlaylists(_ playlists: [Playlist], key: String, generation: Int? = nil) async {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        write(data, to: file("\(key)-playlists"), generation: generation)
    }

    func remove(key: String) {
        clears.count.withLock { count in
            count += 1
            try? FileManager.default.removeItem(at: file(key))
            try? FileManager.default.removeItem(at: file("\(key)-playlists"))
            try? FileManager.default.removeItem(at: accountFile(key))
        }
    }

    func removeAll() {
        clears.count.withLock { count in
            count += 1
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

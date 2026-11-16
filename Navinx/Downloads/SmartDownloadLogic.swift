import Foundation
import SubsonicKit

/// Smart Downloads' choices (C37, D144), with nothing of the app's state: what to fetch, which albums
/// to ask the server for, and which files may go. **Only a song Smart Downloads fetched itself (its
/// record's `automatic` mark) is ever removed**, and never while a downloaded album or playlist has
/// it; with the switch off nothing is fetched or removed.
nonisolated enum SmartDownloadLogic {
    /// The batch the smart downloads go through: never Favorites' own "favorites" (Download All),
    /// whose songs are the user's.
    static let batchID = "smart-downloads"

    /// The wanted songs not on the phone, each once, in order. `skipping`: the songs whose download
    /// the user removed by hand, which stay away until they download or favourite them again (C47).
    static func songsToFetch(
        _ wanted: [Song], downloaded: Set<String>, isEnabled: Bool, skipping: Set<String> = []
    ) -> [Song] {
        guard isEnabled else { return [] }
        var seen = Set<String>()
        return wanted.filter { !downloaded.contains($0.id) && !skipping.contains($0.id) && seen.insert($0.id).inserted }
    }

    /// What a catch-up found on the server.
    struct Found: Equatable {
        /// Favourite songs, then favourite albums' songs, then downloaded playlists' songs.
        var songs: [Song] = []
        var starredSongIDs: Set<String> = []
        /// Each favourite album's song IDs.
        var albums: [String: [String]] = [:]
        /// The downloaded playlists' songs, as the server has them now.
        var playlistSongIDs: Set<String> = []

        /// Everything the switch wants on the phone.
        var wantedIDs: Set<String> {
            starredSongIDs.union(albums.values.flatMap { $0 }).union(playlistSongIDs)
        }
    }

    /// A star the user changed in the app while a catch-up was reading the server (C47).
    enum StarChange: Equatable {
        case song(Song, isStarred: Bool)
        case album(id: String, songs: [Song], isStarred: Bool)
    }

    /// `found` with the stars changed in the app since its read began put on top, in the order they
    /// were made: the server was asked before them, so its answer is the older one. A song no longer
    /// wanted by anything leaves the list.
    static func applying(_ changes: [StarChange], to found: Found) -> Found {
        guard !changes.isEmpty else { return found }
        var result = found
        for change in changes {
            switch change {
            case .song(let song, true):
                result.starredSongIDs.insert(song.id)
                result.songs.append(song)
            case .song(let song, false):
                result.starredSongIDs.remove(song.id)
            case .album(let id, let songs, true):
                result.albums[id] = songs.map(\.id)
                result.songs += songs
            case .album(let id, _, false):
                result.albums[id] = nil
            }
        }
        let wanted = result.wantedIDs
        result.songs = result.songs.filter { wanted.contains($0.id) }
        return result
    }

    /// Whether a catch-up's answer may remove files. One that lists no favourite song at all (a
    /// server or proxy error can read that way) removes nothing, unless the catch-up before it in
    /// this run of the app found none either (`previous`; nil before the first).
    static func confirmsRemoval(starredSongIDs: Set<String>, previous: Set<String>?) -> Bool {
        !starredSongIDs.isEmpty || previous?.isEmpty == true
    }

    /// Each server's answer to the switch-on question (C47, D164): asked once per server. A build
    /// before C47 kept one switch for the whole app (`wasOn`): the server in use when this first runs
    /// has been answered.
    static func answers(saved: [String: Bool]?, wasOn: Bool, profileID: String?) -> [String: Bool]? {
        if let saved { return saved }
        guard let profileID else { return nil }
        return wasOn ? [profileID: true] : [:]
    }

    /// A server with no answer yet is asked only while the feature is in use on another one: it is
    /// off until switched on.
    static func needsAsking(_ answers: [String: Bool], profileID: String) -> Bool {
        answers[profileID] == nil && answers.values.contains(true)
    }

    /// The favourite albums to ask the server for: those not fetched before, or with a song missing.
    /// An album whose saved songs are all here needs no request.
    static func albumsToFetch(starred: [Album], known: [String: [String]], downloaded: Set<String>) -> [Album] {
        starred.filter { album in
            guard let ids = known[album.id], !ids.isEmpty else { return true }
            return !ids.allSatisfy(downloaded.contains)
        }
    }

    /// Every song a downloaded album or playlist has: the user's, never removed for the switch.
    static func neededByCollections(_ records: DownloadRecords) -> Set<String> {
        Set(records.collections.values.filter { $0.kind != .songs }.flatMap { $0.songs.map(\.id) })
    }

    /// The files that may go: fetched by Smart Downloads, no longer wanted (`wanted`: the favourite
    /// songs and the favourite albums' songs), and in no downloaded album or playlist. `candidates`
    /// limits it to some songs (one un-starred here); nil looks at all.
    static func removable(
        records: DownloadRecords,
        wanted: Set<String>,
        isEnabled: Bool,
        candidates: Set<String>? = nil
    ) -> Set<String> {
        guard isEnabled else { return [] }
        let needed = neededByCollections(records)
        var result = Set<String>()
        for (id, record) in records.songs where record.automatic == true {
            if let candidates, !candidates.contains(id) { continue }
            if wanted.contains(id) || needed.contains(id) { continue }
            result.insert(id)
        }
        return result
    }

    /// Bytes the songs will take, from the sizes the server gave (songs without one count as none).
    static func totalSize(_ songs: [Song]) -> Int64 {
        songs.reduce(0) { $0 + Int64($1.size ?? 0) }
    }
}

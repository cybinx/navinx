import Foundation
import SubsonicKit
import Testing
@testable import Navinx

/// Smart Downloads' choices (C37, D144), above all the ones that keep the user's files.
@Suite struct SmartDownloadLogicTests {
    private func song(_ id: String, size: Int? = nil) -> Song {
        var song = Song(id: id, title: "Song \(id)", album: "Album", albumID: "al", artist: "Band", artistID: "ar", duration: 100)
        song.size = size
        return song
    }

    private func record(_ id: String, automatic: Bool) -> SongRecord {
        SongRecord(song: song(id), file: "\(id).mp3", downloadedAt: .now, automatic: automatic ? true : nil)
    }

    /// `hand` and `smart` downloaded; `collections` as downloaded albums and playlists.
    private func records(hand: [String] = [], smart: [String] = [], album: [String]? = nil, playlist: [String]? = nil) -> DownloadRecords {
        var records = DownloadRecords()
        for id in hand { records.songs[id] = record(id, automatic: false) }
        for id in smart { records.songs[id] = record(id, automatic: true) }
        if let album {
            let details = Album(id: "album", name: "Album", songs: [])
            records.collections["album"] = CollectionRecord(album: details, songs: album.map { song($0) })
        }
        if let playlist {
            let details = Playlist(id: "list", name: "List")
            records.collections["list"] = CollectionRecord(playlist: details, songs: playlist.map { song($0) })
        }
        return records
    }

    @Test func aSongTheUserDownloadedIsNeverRemoved() {
        let records = records(hand: ["mine"])
        #expect(SmartDownloadLogic.removable(records: records, wanted: [], isEnabled: true).isEmpty)
        #expect(SmartDownloadLogic.removable(records: records, wanted: [], isEnabled: true, candidates: ["mine"]).isEmpty)
    }

    @Test func aSmartSongADownloadedAlbumOrPlaylistHasIsNeverRemoved() {
        let records = records(smart: ["inAlbum", "inList"], album: ["inAlbum"], playlist: ["inList"])
        #expect(SmartDownloadLogic.removable(records: records, wanted: [], isEnabled: true).isEmpty)
    }

    @Test func withTheSwitchOffNothingIsQueuedOrRemoved() {
        let records = records(smart: ["gone"])
        #expect(SmartDownloadLogic.removable(records: records, wanted: [], isEnabled: false).isEmpty)
        #expect(SmartDownloadLogic.songsToFetch([song("new")], downloaded: [], isEnabled: false).isEmpty)
    }

    @Test func aSmartSongNothingWantsIsRemovedAndAWantedOneStays() {
        let records = records(hand: ["mine"], smart: ["unstarred", "starred"])
        #expect(SmartDownloadLogic.removable(records: records, wanted: ["starred"], isEnabled: true) == ["unstarred"])
        // Only the songs asked about (one un-starred here).
        #expect(SmartDownloadLogic.removable(records: records, wanted: [], isEnabled: true, candidates: ["starred"]) == ["starred"])
    }

    @Test func queuesWhatIsMissingOnceInOrder() {
        let queued = SmartDownloadLogic.songsToFetch(
            [song("a"), song("here"), song("b"), song("a")], downloaded: ["here"], isEnabled: true
        )
        #expect(queued.map(\.id) == ["a", "b"])
        #expect(SmartDownloadLogic.totalSize([song("a", size: 1000), song("b"), song("c", size: 24)]) == 1024)
    }

    // MARK: C47 (the check's medium findings)

    @Test func aDownloadRemovedByHandIsNotFetchedAgain() {
        let queued = SmartDownloadLogic.songsToFetch(
            [song("a"), song("removed"), song("b")], downloaded: [], isEnabled: true, skipping: ["removed"]
        )
        #expect(queued.map(\.id) == ["a", "b"])
    }

    @Test func starsChangedWhileTheServerWasReadGoOnTopOfItsAnswer() {
        var found = SmartDownloadLogic.Found(songs: [song("s1"), song("s2"), song("a1"), song("p1")])
        found.starredSongIDs = ["s1", "s2"]
        found.albums = ["old": ["a1"]]
        found.playlistSongIDs = ["p1"]
        let merged = SmartDownloadLogic.applying([
            .song(song("s3"), isStarred: true),
            .song(song("s2"), isStarred: false),
            .album(id: "new", songs: [song("n1"), song("n2")], isStarred: true),
            .album(id: "old", songs: [], isStarred: false),
        ], to: found)
        #expect(merged.starredSongIDs == ["s1", "s3"])
        #expect(merged.albums == ["new": ["n1", "n2"]])
        // Un-starred and wanted by nothing else: gone from the list. A playlist's song stays.
        #expect(merged.songs.map(\.id) == ["s1", "p1", "s3", "n1", "n2"])
        // A song un-starred that a favourite album still has stays.
        var shared = SmartDownloadLogic.Found(songs: [song("x")])
        shared.starredSongIDs = ["x"]
        shared.albums = ["al": ["x"]]
        #expect(SmartDownloadLogic.applying([.song(song("x"), isStarred: false)], to: shared).songs.map(\.id) == ["x"])
        #expect(SmartDownloadLogic.applying([], to: found) == found)
    }

    @Test func anAnswerWithNoFavouriteSongsRemovesNothingTheFirstTime() {
        #expect(SmartDownloadLogic.confirmsRemoval(starredSongIDs: ["a"], previous: nil))
        #expect(!SmartDownloadLogic.confirmsRemoval(starredSongIDs: [], previous: nil))
        #expect(!SmartDownloadLogic.confirmsRemoval(starredSongIDs: [], previous: ["a", "b"]))
        // Seen twice in a row, it's taken as true.
        #expect(SmartDownloadLogic.confirmsRemoval(starredSongIDs: [], previous: []))
    }

    @Test func eachServerIsAskedOnce() {
        // A build before C47 had one switch: the server in use has been answered.
        #expect(SmartDownloadLogic.answers(saved: nil, wasOn: true, profileID: "a") == ["a": true])
        #expect(SmartDownloadLogic.answers(saved: nil, wasOn: false, profileID: "a") == [:])
        #expect(SmartDownloadLogic.answers(saved: nil, wasOn: true, profileID: nil) == nil)
        #expect(SmartDownloadLogic.answers(saved: ["a": false], wasOn: true, profileID: "b") == ["a": false])
        // Asked only while the feature is on somewhere, and only with no answer yet.
        #expect(SmartDownloadLogic.needsAsking(["a": true], profileID: "b"))
        #expect(!SmartDownloadLogic.needsAsking(["a": true, "b": false], profileID: "b"))
        #expect(!SmartDownloadLogic.needsAsking(["a": false], profileID: "b"))
        #expect(!SmartDownloadLogic.needsAsking([:], profileID: "b"))
    }

    @Test func asksOnlyForAlbumsNotAllHere() {
        let albums = ["new", "complete", "missing"].map { Album(id: $0, name: $0, songs: []) }
        let known = ["complete": ["1", "2"], "missing": ["3", "4"]]
        let fetched = SmartDownloadLogic.albumsToFetch(starred: albums, known: known, downloaded: ["1", "2", "3"])
        #expect(fetched.map(\.id) == ["new", "missing"])
    }
}

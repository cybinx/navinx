import Foundation
import Lyrics
import PlaybackKit
import SubsonicKit
import Testing
@testable import Navinx

/// C43, step 0 (D157): what the app saves, frozen as golden samples written by the build before C43's
/// renames. A renamed property or case must never move a saved key or value: a moved key signs
/// everyone out (D8), or loses settings, the listening history or the download records. These samples
/// must pass unchanged before and after every rename; never edit one to make a test pass.
@Suite struct SavedFormatTests {
    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func read<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    static let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static let song = Song(
        id: "s1", title: "One", album: "First", albumID: "al1", artist: "A", artistID: "ar1",
        genre: "Rock", coverArt: "c1", duration: 200
    )

    // MARK: Logins (`server_profiles`, `server_config`)

    @Test func serverProfile() throws {
        let profile = ServerProfile(
            id: UUID(uuidString: "6F0C2B2E-8F4A-4C61-9D35-1A7E2C9B5D10")!,
            serverURL: "https://music.example",
            homeNetworkURL: "http://music.home",
            username: "listener",
            sendsPlainPassword: true,
            name: "Home",
            serverType: "navidrome",
            serverVersion: "0.53.3"
        )
        let golden = #"{"id":"6F0C2B2E-8F4A-4C61-9D35-1A7E2C9B5D10","lanURL":"http:\/\/music.home","name":"Home","serverType":"navidrome","serverURL":"https:\/\/music.example","serverVersion":"0.53.3","useLegacyAuth":true,"username":"listener"}"#
        #expect(try Self.json(profile) == golden)
        #expect(try Self.read(ServerProfile.self, golden) == profile)
        #expect(try Self.read([ServerProfile].self, "[\(golden)]") == [profile])
    }

    // MARK: The library cache (`Library/<server>.json`)

    @Test func librarySnapshot() throws {
        let snapshot = LibrarySnapshot(
            savedAt: Self.date,
            artists: [Artist(id: "ar1", name: "A", albumCount: 1)],
            latestAlbums: [Album(id: "al1", name: "First", artist: "A", artistID: "ar1", coverArt: "c1", songCount: 1)],
            playlists: [Playlist(id: "p1", name: "Mix", owner: "listener", songCount: 1)],
            allAlbums: [Album(id: "al2", name: "Second", artist: "B")],
            allSongs: [Self.song]
        )
        let golden = #"{"allAlbums":[{"artist":"B","id":"al2","name":"Second"}],"allSongs":[{"album":"First","albumId":"al1","artist":"A","artistId":"ar1","coverArt":"c1","duration":200,"genre":"Rock","id":"s1","title":"One"}],"artists":[{"albumCount":1,"id":"ar1","name":"A"}],"playlists":[{"id":"p1","name":"Mix","owner":"listener","songCount":1}],"recentAlbums":[{"artist":"A","artistId":"ar1","coverArt":"c1","id":"al1","name":"First","songCount":1}],"savedAt":800000000}"#
        #expect(try Self.json(snapshot) == golden)
        #expect(try Self.json(Self.read(LibrarySnapshot.self, golden)) == golden)
    }

    // MARK: The listening history (`recommendations.json`)

    @Test func recommendationData() throws {
        var data = RecommendationData()
        let other = Song(id: "s2", title: "Two", albumID: "al1", artist: "A", artistID: "ar1", genre: "Rock", duration: 180)
        data.record(.finished(Self.song, played: 200, duration: 200, end: .ended), at: Self.date, hour: 9)
        data.record(.finished(other, played: 20, duration: 180, end: .next), at: Self.date, hour: 9)
        data.record(.starred(Self.song, true), at: Self.date, hour: 9)
        data.record(.rated(Self.song, 4), at: Self.date, hour: 9)
        data.applyDecay(at: Self.date)
        let golden = #"{"albumAffinity":{"al1":0.8999999999999999},"artistAffinity":{"A":3.2333333333333334},"artistRatingAffinity":{"A":1.25},"genreAffinity":{"Rock":2.4916666666666667},"genreRatingAffinity":{"Rock":0.9},"lastDecayApplied":800000000,"profiles":{"s1":{"albumID":"al1","artist":"A","artistID":"ar1","completedPlays":1,"coverArt":"c1","duration":200,"genre":"Rock","hourlyPlays":{"9":1},"lastPlayed":800000000,"playCount":1,"skipCount":0,"songID":"s1","title":"One","totalListenTime":200,"userRating":4}},"recentlyPlayed":["s1"],"skipCounts":{"s2":1},"starredSongs":["s1"],"timePatterns":{"9":{"Rock":1}}}"#
        #expect(try Self.json(data) == golden)
        let read = try Self.read(RecommendationData.self, golden)
        #expect(try Self.json(read) == golden)
        #expect(read.profiles["s1"]?.playCount == 1)
        #expect(read.skipCounts["s2"] == 1)
        #expect(read.starredSongs == ["s1"])
        #expect(read.lastFadeDate == Self.date)
    }

    // MARK: The download records (`Downloads/<server>/records.json`)

    @Test func downloadRecords() throws {
        var records = DownloadRecords()
        records.songs["s1"] = SongRecord(song: Self.song, file: "s1.mp3", downloadedAt: Self.date, automatic: true)
        records.collections["al1"] = CollectionRecord(
            album: Album(id: "al1", name: "First", artist: "A", coverArt: "c1", songCount: 1),
            songs: [Self.song]
        )
        records.collections["p1"] = CollectionRecord(playlist: Playlist(id: "p1", name: "Mix", songCount: 1), songs: [Self.song])
        records.collections["favorites"] = CollectionRecord(batchID: "favorites", name: "Favorites", songs: [Self.song])
        records.queue = ["al1"]
        records.covers = ["c1"]
        records.smartAlbums = ["al1": ["s1"]]
        let golden = #"{"collections":{"al1":{"album":{"artist":"A","coverArt":"c1","id":"al1","name":"First","songCount":1},"coverArt":"c1","id":"al1","kind":"album","name":"First","songs":[{"album":"First","albumId":"al1","artist":"A","artistId":"ar1","coverArt":"c1","duration":200,"genre":"Rock","id":"s1","title":"One"}]},"favorites":{"id":"favorites","kind":"songs","name":"Favorites","songs":[{"album":"First","albumId":"al1","artist":"A","artistId":"ar1","coverArt":"c1","duration":200,"genre":"Rock","id":"s1","title":"One"}]},"p1":{"id":"p1","kind":"playlist","name":"Mix","playlist":{"id":"p1","name":"Mix","songCount":1},"songs":[{"album":"First","albumId":"al1","artist":"A","artistId":"ar1","coverArt":"c1","duration":200,"genre":"Rock","id":"s1","title":"One"}]}},"covers":["c1"],"queue":["al1"],"smartAlbums":{"al1":["s1"]},"songs":{"s1":{"automatic":true,"downloadedAt":800000000,"file":"s1.mp3","song":{"album":"First","albumId":"al1","artist":"A","artistId":"ar1","coverArt":"c1","duration":200,"genre":"Rock","id":"s1","title":"One"}}}}"#
        #expect(try Self.json(records) == golden)
        #expect(try Self.read(DownloadRecords.self, golden) == records)
        #expect(CollectionRecord.Kind.allRawValues == ["album", "playlist", "songs"])
    }

    /// C47's list of downloads removed by hand: written only when there is one (so the form above
    /// is unchanged for everyone else), and read back.
    @Test func downloadRecordsWithARemovalByHand() throws {
        var records = DownloadRecords()
        records.removedByHand = ["s9"]
        let golden = #"{"collections":{},"covers":[],"queue":[],"removedByHand":["s9"],"smartAlbums":{},"songs":{}}"#
        #expect(try Self.json(records) == golden)
        #expect(try Self.read(DownloadRecords.self, golden) == records)
    }

    @Test func downloadedLyrics() throws {
        let lines = [LyricLine(text: "First line", start: 1.5, end: 3.25), LyricLine(text: "Last", start: 3.25)]
        let golden = #"[{"end":3.25,"start":1.5,"text":"First line"},{"start":3.25,"text":"Last"}]"#
        #expect(try Self.json(lines) == golden)
        #expect(try Self.read([LyricLine].self, golden) == lines)
    }

    // MARK: Settings saved by raw value

    @Test func appearanceRawValues() {
        #expect(AppearanceModel.Theme.allCases.map(\.rawValue) == ["system", "light", "dark"])
        #expect(AppearanceModel.Accent.allCases.map(\.rawValue) == ["red", "pink", "orange", "yellow", "green", "blue", "purple"])
    }
}

extension CollectionRecord.Kind {
    static var allRawValues: [String] { [Self.album, .playlist, .songs].map(\.rawValue) }
}

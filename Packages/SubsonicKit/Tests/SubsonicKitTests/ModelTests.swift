import Foundation
import Testing
@testable import SubsonicKit

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

@Suite struct SongTests {
    @Test func decodesFields() throws {
        let song = try decode(Song.self, """
        {"id":"123","title":"Test Song","album":"Test Album","artist":"Test Artist","duration":180,
         "track":5,"albumId":"al","artistId":"ar","year":2024,"genre":"Rap","coverArt":"mf-1",
         "bitRate":320,"suffix":"mp3","contentType":"audio/mpeg","size":100,"path":"a/b.mp3",
         "userRating":3,"hasDolbyAtmos":false}
        """)
        #expect(song.id == "123" && song.title == "Test Song")
        #expect(song.album == "Test Album" && song.artist == "Test Artist")
        #expect(song.duration == 180 && song.track == 5)
        #expect(song.albumID == "al" && song.artistID == "ar")
        #expect(song.year == 2024 && song.genre == "Rap" && song.coverArt == "mf-1")
        #expect(song.bitRate == 320 && song.suffix == "mp3" && song.contentType == "audio/mpeg")
        #expect(song.size == 100 && song.path == "a/b.mp3" && song.userRating == 3)
        #expect(song.hasDolbyAtmos == false)
        #expect(!song.starred)
    }

    @Test func missingFieldsAreNilAndTitleDefaults() throws {
        let song = try decode(Song.self, #"{"id":"123"}"#)
        #expect(song.title == "Unknown Title")
        #expect(song.album == nil && song.artist == nil && song.duration == nil && song.created == nil)
        #expect(song.artists == nil)
        #expect(song.replayGain.isEmpty)
    }

    @Test func numericIDAndStringNumbers() throws {
        let song = try decode(Song.self, #"{"id":42,"title":"x","track":"7","duration":"61"}"#)
        #expect(song.id == "42" && song.track == 7 && song.duration == 61)
    }

    @Test func playCountAndLastPlayed() throws {
        let song = try decode(Song.self, #"{"id":"1","playCount":15,"played":"2026-11-08T10:12:13.5Z"}"#)
        #expect(song.playCount == 15)
        #expect(song.played == Date(timeIntervalSince1970: 1_794_132_733.5))
        let lenient = try decode(Song.self, #"{"id":"1","playCount":"3","played":"not a date"}"#)
        #expect(lenient.playCount == 3 && lenient.played == nil)
        #expect(try decode(Song.self, #"{"id":"1"}"#).playCount == nil)
        // A number too big for an Int reads as nil instead of trapping; a fraction is cut off.
        #expect(try decode(Song.self, #"{"id":"1","playCount":1e19}"#).playCount == nil)
        #expect(try decode(Song.self, #"{"id":"1","playCount":3.7}"#).playCount == 3)
    }

    /// C35: OpenSubsonic's audio details, as Navidrome sends them (an MP3's bit depth is 0).
    @Test func audioDetails() throws {
        let song = try decode(Song.self, #"{"id":"1","samplingRate":44100,"bitDepth":0,"channelCount":2}"#)
        #expect(song.samplingRate == 44100 && song.bitDepth == 0 && song.channelCount == 2)
        let flac = try decode(Song.self, #"{"id":"1","samplingRate":"96000","bitDepth":24,"channelCount":1}"#)
        #expect(flac.samplingRate == 96000 && flac.bitDepth == 24 && flac.channelCount == 1)
    }

    /// A song saved before C35 (the queue file, the download records, the library cache) has none of
    /// them: they read as nil, and the rest as before.
    @Test func songSavedBeforeAudioDetails() throws {
        let song = try decode(Song.self, """
        {"id":"s","title":"T","album":"A","bitRate":320,"suffix":"mp3","size":1000,"playCount":2}
        """)
        #expect(song.samplingRate == nil && song.bitDepth == nil && song.channelCount == nil)
        #expect(song.album == "A" && song.bitRate == 320 && song.suffix == "mp3" && song.playCount == 2)
    }

    @Test func starredIsPresenceOfTheDate() throws {
        #expect(try decode(Song.self, #"{"id":"1","starred":"2026-11-04T21:00:00Z"}"#).starred)
        #expect(try !decode(Song.self, #"{"id":"1","starred":null}"#).starred)
    }

    @Test func parsesNavidromeNanosecondDates() throws {
        let song = try decode(Song.self, #"{"id":"1","created":"2026-03-18T13:37:27.257653751Z"}"#)
        let created = try #require(song.created)
        let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: created)
        #expect(parts.year == 2026 && parts.month == 3 && parts.day == 18)
        #expect(parts.hour == 13 && parts.minute == 37 && parts.second == 27)
        #expect(SubsonicDate.parse("2026-11-02T08:00:00Z") != nil)
        #expect(SubsonicDate.parse("2026-11-02T08:00:00.5Z") != nil)
        #expect(SubsonicDate.parse("2026-11-02T08:00:00+02:00") != nil)
        #expect(SubsonicDate.parse("not a date") == nil)
    }

    /// Flutter's `song_test.dart` ReplayGain cases.
    @Test func replayGainNestedNumbersOrStrings() throws {
        let song = try decode(Song.self, """
        {"id":"1","replayGain":{"trackGain":-7.2,"albumGain":"-6.5 dB","trackPeak":"0.98","albumPeak":1}}
        """)
        #expect(song.replayGain == ReplayGain(trackGain: -7.2, albumGain: -6.5, trackPeak: 0.98, albumPeak: 1))
    }

    @Test func replayGainFlatKeys() throws {
        let song = try decode(Song.self, """
        {"id":"1","replayGainTrackGain":"-3 db","albumGain":-4,"rgTrackPeak":"95%","rgAlbumPeak":0.5}
        """)
        #expect(song.replayGain == ReplayGain(trackGain: -3, albumGain: -4, trackPeak: 95, albumPeak: 0.5))
    }

    @Test func navidromeEmptyReplayGainIsEmpty() throws {
        #expect(try decode(Song.self, #"{"id":"1","replayGain":{}}"#).replayGain.isEmpty)
    }

    @Test func formattedDuration() {
        #expect(Song(id: "1", title: "t", duration: 185).formattedDuration == "3:05")
        #expect(Song(id: "1", title: "t", duration: 3600).formattedDuration == "60:00")
        #expect(Song(id: "1", title: "t").formattedDuration == "0:00")
    }

    @Test func artistsAreSplitAndDisplayFallsBack() throws {
        let song = try decode(Song.self, """
        {"id":"1","artist":"A feat. B","artists":[{"id":"x","name":"A feat. B"},{"id":"c","name":"C"}]}
        """)
        #expect(song.artists == [ArtistCredit(id: "", name: "A"), ArtistCredit(id: "", name: "B"), ArtistCredit(id: "c", name: "C")])

        let plain = Song(id: "1", title: "t", artist: "X & Y", artistID: "xy")
        #expect(plain.displayArtists == [ArtistCredit(id: "", name: "X"), ArtistCredit(id: "", name: "Y")])
        #expect(Song(id: "1", title: "t", artist: " Solo ", artistID: "s").displayArtists == [ArtistCredit(id: "s", name: "Solo")])
        #expect(Song(id: "1", title: "t", artistID: "only").displayArtists == [ArtistCredit(id: "only", name: "")])
        #expect(Song(id: "1", title: "t").displayArtists.isEmpty)
    }
}

@Suite struct ArtistNameTests {
    @Test(arguments: [
        ("A & B", ["A", "B"]),
        ("A, B, C", ["A", "B", "C"]),
        ("A feat. B", ["A", "B"]),
        ("A ft B", ["A", "B"]),
        // D12: the Flutter quirks, fixed (Flutter gives "A", "uring B" / "Y" / "Malcolm" /
        // "Confidence" / "A", "s B").
        ("A Featuring B", ["A", "B"]),
        ("X & Y", ["X", "Y"]),
        ("Malcolm X", ["Malcolm X"]),
        ("With Confidence", ["With Confidence"]),
        ("A Feats B", ["A Feats B"]),
        ("And One & B", ["And One", "B"]),
        ("A FEAT. B and C", ["A", "B", "C"]),
        ("Earth, Wind & Fire", ["Earth", "Wind", "Fire"]),
        ("A and B", ["A", "B"]),
        ("A x B", ["A", "B"]),
        ("A with B", ["A", "B"]),
        ("A / B ; C | D \\ E", ["A", "B", "C", "D", "E"]),
        ("Brandon", ["Brandon"]),
        ("Xavier", ["Xavier"]),
        ("  Solo  ", ["Solo"]),
        ("", []),
    ])
    func splits(raw: String, expected: [String]) {
        #expect(ArtistCredit.parseArtistCredits(raw) == expected)
    }

    @Test func coverToShow() {
        #expect(ArtistCredit(id: "a", name: "n", coverArt: "c").coverToShow == "c")
        #expect(ArtistCredit(id: "a", name: "n", coverArt: "").coverToShow == "a")
        #expect(ArtistCredit(id: "", name: "n").coverToShow == nil)
    }

    @Test func expandDropsEmptyRefsAndNilsAnEmptyList() {
        #expect(ArtistCredit.expand([ArtistCredit(id: "", name: "")]) == nil)
        #expect(ArtistCredit.expand([]) == nil)
        #expect(ArtistCredit.expand(nil) == nil)
    }
}

@Suite struct OtherModelTests {
    @Test func albumNameFallsBackToAlbumThenDefault() throws {
        #expect(try decode(Album.self, #"{"id":"1","album":"From album"}"#).name == "From album")
        #expect(try decode(Album.self, #"{"id":"1"}"#).name == "Unknown Album")
        #expect(try decode(Album.self, #"{"id":"1"}"#).songs.isEmpty)
    }

    @Test func albumFormattedDuration() {
        #expect(Album(id: "1", name: "n", duration: 2140).formattedDuration == "35:40")
        #expect(Album(id: "1", name: "n").formattedDuration == "")
    }

    @Test func playlistFormattedDuration() {
        #expect(Playlist(id: "1", name: "n", duration: 3900).formattedDuration == "1 h 5 min")
        #expect(Playlist(id: "1", name: "n", duration: 2520).formattedDuration == "42 min")
        #expect(Playlist(id: "1", name: "n").formattedDuration == "")
    }

    @Test func defaults() throws {
        #expect(try decode(Artist.self, #"{"id":"1"}"#).name == "Unknown Artist")
        #expect(try decode(Playlist.self, #"{"id":"1"}"#).name == "Unknown Playlist")
        #expect(try decode(Playlist.self, #"{"id":"1"}"#).songs == nil)
        #expect(try decode(MusicFolder.self, #"{"id":1}"#) == MusicFolder(id: "1", name: "Unknown Folder"))
    }
}

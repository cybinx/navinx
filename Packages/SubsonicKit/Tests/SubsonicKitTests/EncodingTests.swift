import Foundation
import Testing
@testable import SubsonicKit

/// Everything written must read back the same: the saved library depends on it.
struct EncodingTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000.25)

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private var fullSong: Song {
        var song = Song(id: "s", title: "Title")
        song.album = "Album"
        song.albumID = "a"
        song.artist = "Artist"
        song.artistID = "r"
        song.track = 3
        song.year = 2020
        song.genre = "Rock"
        song.coverArt = "c"
        song.duration = 200
        song.bitRate = 320
        song.suffix = "mp3"
        song.contentType = "audio/mpeg"
        song.size = 1000
        song.path = "a/b.mp3"
        song.starred = true
        song.userRating = 4
        song.replayGain = ReplayGain(trackGain: -6.5, albumGain: -7, trackPeak: 0.9, albumPeak: 1)
        song.artists = [ArtistCredit(id: "r", name: "Artist", coverArt: "x")]
        song.created = date
        song.hasDolbyAtmos = true
        song.playCount = 7
        song.played = date
        song.samplingRate = 44100
        song.bitDepth = 16
        song.channelCount = 2
        return song
    }

    @Test func song() throws {
        #expect(try roundTrip(fullSong) == fullSong)
        let minimal = Song(id: "s", title: "T")
        #expect(try roundTrip(minimal) == minimal)
    }

    @Test func album() throws {
        var album = Album(id: "a", name: "N", artist: "A", artistID: "r", coverArt: "c", songCount: 2, duration: 9, year: 2001, genre: "G")
        album.created = date
        album.artists = [ArtistCredit(id: "r", name: "A")]
        album.starred = true
        album.songs = [fullSong]
        #expect(try roundTrip(album) == album)
    }

    @Test func artist() throws {
        var artist = Artist(id: "r", name: "N", coverArt: "c")
        artist.albumCount = 2
        artist.artistImageURL = "http://example.test/i"
        artist.albums = [Album(id: "a", name: "A")]
        #expect(try roundTrip(artist) == artist)
    }

    @Test func playlist() throws {
        var playlist = Playlist(id: "p", name: "N", songCount: 1)
        playlist.comment = "c"
        playlist.owner = "o"
        playlist.isPublic = true
        playlist.duration = 5
        playlist.created = date
        playlist.changed = date
        playlist.coverArt = "pl-p"
        playlist.songs = [fullSong]
        #expect(try roundTrip(playlist) == playlist)
    }
}

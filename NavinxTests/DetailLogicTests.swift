import SubsonicKit
import Testing
@testable import Navinx

struct DetailLogicTests {
    @Test func filterMatchesTitleOrArtistIgnoringCase() {
        let songs = [
            Song(id: "1", title: "Morning", artist: "Band"),
            Song(id: "2", title: "Night", artist: "Morning Glory"),
            Song(id: "3", title: "Noon"),
        ]
        #expect(DetailLogic.filter(songs, query: "").count == 3)
        #expect(DetailLogic.filter(songs, query: "  ").count == 3)
        #expect(DetailLogic.filter(songs, query: " MORNING ").map(\.id) == ["1", "2"])
        #expect(DetailLogic.filter(songs, query: "zzz").isEmpty)
    }

    @Test func albumSummary() {
        let album = Album(id: "a", name: "A", year: 2020, genre: "Rock")
        let long = [Song(id: "1", title: "t", duration: 3600), Song(id: "2", title: "t", duration: 125)]
        #expect(DetailLogic.albumSummary(album: album, songs: long) == "2 songs • ROCK • 2020 • 1 HR 2 MIN")
        let short = [Song(id: "1", title: "t", duration: 200)]
        #expect(DetailLogic.albumSummary(album: Album(id: "a", name: "A"), songs: short) == "1 song • 3 MIN")
        #expect(DetailLogic.albumSummary(album: Album(id: "a", name: "A"), songs: []) == "No songs • 0 MIN")
    }

    @Test func sectionsSplitBySongCount() {
        let counts: [Int?] = [nil, 0, 2, 3, 6, 7, 20]
        let albums = counts.enumerated().map { Album(id: "\($0.offset)", name: "x", songCount: $0.element) }
        let sections = DetailLogic.sections(albums)
        #expect(sections.singles.map(\.id) == ["0", "1", "2"])
        #expect(sections.eps.map(\.id) == ["3", "4"])
        #expect(sections.albums.map(\.id) == ["5", "6"])
    }

    @Test func artistArtOrder() {
        let info = ArtistInfo(mediumImageURL: "medium", largeImageURL: "large")
        #expect(DetailLogic.artistArt(Artist(id: "1", name: "n", coverArt: "cover"), info: info) == "cover")
        #expect(DetailLogic.artistArt(Artist(id: "1", name: "n"), info: info) == "large")
        #expect(DetailLogic.artistArt(Artist(id: "1", name: "n"), info: ArtistInfo(mediumImageURL: "medium")) == "medium")
        #expect(DetailLogic.artistArt(Artist(id: "1", name: "n", artistImageURL: "image"), info: nil) == "image")
        #expect(DetailLogic.artistArt(Artist(id: "1", name: "n"), info: nil) == "ar-1")
        #expect(DetailLogic.artistArt(Artist(id: "", name: "n"), info: nil) == nil)
    }

    @Test func fallbackArtistOrder() {
        let cached = [Artist(id: "1", name: "Cached")]
        let songs = [Song(id: "s", title: "t", artist: "From Song", artistID: "1")]
        let albums = [Album(id: "a", name: "x", artist: "From Album")]
        #expect(DetailLogic.fallbackArtist(id: "1", cached: cached, songs: songs, albums: albums)?.name == "Cached")
        #expect(DetailLogic.fallbackArtist(id: "1", cached: [], songs: songs, albums: albums)?.name == "From Song")
        #expect(DetailLogic.fallbackArtist(id: "1", cached: [], songs: [], albums: albums)?.name == "From Album")
        #expect(DetailLogic.fallbackArtist(id: "1", cached: [], songs: [], albums: []) == nil)
    }

    @Test func onlyAMissingItemIsNotFound() {
        #expect(DetailLogic.isMissing(SubsonicError.api(code: 70, message: "Data not found")))
        #expect(!DetailLogic.isMissing(SubsonicError.api(code: 40, message: nil)))
        #expect(!DetailLogic.isMissing(SubsonicError.network))
        #expect(!DetailLogic.isMissing(SubsonicError.server(status: 500)))
    }

    @Test func anotherUsersPlaylistIsOnlyChangedByAnAdministrator() {
        let mine = Playlist(id: "1", name: "Mine", owner: "Alice")
        let theirs = Playlist(id: "2", name: "Theirs", owner: "bob")
        let unknown = Playlist(id: "3", name: "Unknown")
        #expect(DetailLogic.canEdit(mine, username: "alice", isAdmin: false))
        #expect(!DetailLogic.canEdit(theirs, username: "alice", isAdmin: false))
        #expect(DetailLogic.canEdit(theirs, username: "alice", isAdmin: true))
        #expect(DetailLogic.canEdit(unknown, username: "alice", isAdmin: false))
        #expect(DetailLogic.canEdit(theirs, username: nil, isAdmin: false))
    }

    @Test func aLastFmBiographyBecomesPlainText() {
        let html = "Radiohead are an English band.&nbsp; Formed in 1985 &amp; named after a song.<br>\n<br/>\n"
            + "<i>\"Creep\"</i> &quot;hit&quot; &#39;92 &#x2014; yes. <a target=\'_blank\' href=\"https://www.last.fm/music/Radiohead\">Read more on Last.fm</a>"
        let expected = "Radiohead are an English band. Formed in 1985 & named after a song.\n\n"
            + "\"Creep\" \"hit\" '92 \u{2014} yes."
        #expect(DetailLogic.plainBiography(html) == expected)
        #expect(DetailLogic.plainBiography("Fish &amp;lt; chips") == "Fish &lt; chips")
        #expect(DetailLogic.plainBiography(" <a href=\"x\">Read more on Last.fm</a> ") == "")
        #expect(DetailLogic.plainBiography("a < b and 5 > 3") == "a < b and 5 > 3")
        #expect(DetailLogic.plainBiography("One   two\n\n\n\nthree") == "One two\n\nthree")
    }
}

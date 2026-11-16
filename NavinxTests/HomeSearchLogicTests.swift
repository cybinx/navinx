import Foundation
import PlaybackKit
import SubsonicKit
import Testing
@testable import Navinx

private func song(_ id: String) -> Song { Song(id: id, title: "Song \(id)") }
private func album(_ id: String) -> Album { Album(id: id, name: "Album \(id)") }
private func artist(_ id: String) -> Artist { Artist(id: id, name: "Artist \(id)") }
private func playlist(_ name: String) -> Playlist { Playlist(id: name, name: name) }

@Suite struct HomeLogicTests {
    @Test func theChipsChooseFlutterSections() {
        #expect(HomeCategory.allCases.map(\.title) == ["All", "Music", "Made For You", "Playlists"])
        #expect(HomeCategory.all.showsMusic && HomeCategory.all.showsMadeForYou && HomeCategory.all.showsPlaylists)
        #expect(HomeCategory.music.showsMusic && !HomeCategory.music.showsMadeForYou && !HomeCategory.music.showsPlaylists)
        #expect(!HomeCategory.madeForYou.showsMusic && HomeCategory.madeForYou.showsMadeForYou && !HomeCategory.madeForYou.showsPlaylists)
        #expect(!HomeCategory.playlists.showsMusic && !HomeCategory.playlists.showsMadeForYou && HomeCategory.playlists.showsPlaylists)
    }

    @Test func aFeedComesFromTheLibraryEvenBeforeAnyListening() {
        let songs = (0..<30).map { song("\($0)") }
        let feed = HomeFeed.make(data: RecommendationData(), songs: songs, hour: 9)
        #expect(feed.personalized.count == 12)
        #expect(feed.heavyRotation.count == 10)
        #expect(feed.replayPicks.isEmpty)
        #expect(feed.mixes.map(\.name) == ["Quick Picks", "Discover Mix"])
    }

    @Test func switchedOffOrEmptyThereIsNoFeed() {
        var off = RecommendationData()
        off.isEnabled = false
        #expect(HomeFeed.make(data: off, songs: [song("a")], hour: 9) == HomeFeed())
        #expect(HomeFeed.make(data: RecommendationData(), songs: [], hour: 9) == HomeFeed())
        #expect(HomeFeed.key(data: off, songs: [song("a")]).isEmpty)
        #expect(HomeFeed.key(data: RecommendationData(), songs: []).isEmpty)
    }

    @Test func theFeedIsRankedAgainAfterEachNewSong() {
        var data = RecommendationData()
        let songs = [song("a"), song("b")]
        let before = HomeFeed.key(data: data, songs: songs)
        #expect(before == HomeFeed.key(data: data, songs: songs))
        data.record(.started(song("a")))
        #expect(before != HomeFeed.key(data: data, songs: songs))
    }
}

@Suite struct SearchLogicTests {
    private let result = SearchResult(
        artists: [artist("1"), artist("2")],
        albums: [album("1")],
        songs: (0..<25).map { song("\($0)") }
    )

    @Test func allShowsEverythingWithTheArtistOnTop() {
        let sections = SearchSections(result: result, playlists: [playlist("Rock"), playlist("Jazz")], query: " rock ", filter: .all)
        #expect(sections.topResult == .artist(artist("1")))
        #expect(sections.songs.count == 5)
        #expect(sections.artists.count == 2)
        #expect(sections.albums.count == 1)
        #expect(sections.playlists.map(\.name) == ["Rock"])
        #expect(!sections.isEmpty)
    }

    @Test func songsShowTwentyWithASongOnTop() {
        let sections = SearchSections(result: result, playlists: [playlist("Rock")], query: "rock", filter: .songs)
        #expect(sections.topResult == .song(song("0")))
        #expect(sections.songs.count == 20)
        #expect(sections.artists.isEmpty && sections.albums.isEmpty && sections.playlists.isEmpty)
    }

    @Test func theOtherFiltersShowOneSectionAndNoTopResult() {
        let artists = SearchSections(result: result, playlists: [], query: "x", filter: .artists)
        #expect(artists.topResult == nil && artists.songs.isEmpty && artists.artists.count == 2)
        let albums = SearchSections(result: result, playlists: [], query: "x", filter: .albums)
        #expect(albums.topResult == nil && albums.albums.count == 1 && albums.artists.isEmpty)
        let playlists = SearchSections(result: result, playlists: [playlist("x")], query: "x", filter: .playlists)
        #expect(playlists.topResult == nil && playlists.playlists.count == 1 && playlists.songs.isEmpty)
    }

    @Test func theTopResultFallsBackToASongThenAnAlbum() {
        let songs = SearchResult(albums: [album("1")], songs: [song("1")])
        #expect(SearchSections(result: songs, playlists: [], query: "x", filter: .all).topResult == .song(song("1")))
        let albums = SearchResult(albums: [album("1")])
        #expect(SearchSections(result: albums, playlists: [], query: "x", filter: .all).topResult == .album(album("1")))
    }

    @Test func noResultsNeedsEverythingEmptyIncludingPlaylists() {
        #expect(SearchSections(result: SearchResult(), playlists: [playlist("Jazz")], query: "rock", filter: .all).isEmpty)
        let onlyPlaylist = SearchSections(result: SearchResult(), playlists: [playlist("Rock")], query: "rock", filter: .all)
        #expect(!onlyPlaylist.isEmpty)
        #expect(onlyPlaylist.topResult == nil)
    }

    @Test func recentSearchesKeepTheNewestEight() {
        var recents = RecentSearches()
        for index in 0..<9 { recents.add("q\(index)") }
        #expect(recents.queries.count == 8)
        #expect(recents.queries.first == "q8")
        #expect(!recents.queries.contains("q0"))
        recents.remove("q8")
        #expect(recents.queries.first == "q7")
        recents.clear()
        #expect(recents.queries.isEmpty)
    }

    @Test func aSearchRunAgainMovesToTheFrontAndBlanksAreIgnored() {
        var recents = RecentSearches()
        for query in ["a", "b", "c"] { recents.add(query) }
        recents.add("a")
        #expect(recents.queries == ["a", "c", "b"])
        recents.add("   ")
        recents.add("")
        #expect(recents.queries == ["a", "c", "b"])
    }

    @Test func aFilterWithNothingShowsNothingWhileAnotherHasMatches() {
        let onlySongs = SearchResult(songs: [song("1")])
        let artists = SearchSections(result: onlySongs, playlists: [], query: "x", filter: .artists)
        #expect(!artists.isEmpty)
        #expect(artists.showsNothing)
        #expect(!SearchSections(result: onlySongs, playlists: [], query: "x", filter: .songs).showsNothing)
        #expect(!SearchSections(result: onlySongs, playlists: [], query: "x", filter: .all).showsNothing)
        #expect(SearchSections(result: SearchResult(), playlists: [], query: "x", filter: .all).showsNothing)
    }

    @Test func anEmptyFieldShowsTheRecentsOrElseThePrompt() {
        #expect(SearchIdleState(hasRecents: true, searchesServer: true) == .recents)
        #expect(SearchIdleState(hasRecents: true, searchesServer: false) == .recents)
        #expect(SearchIdleState(hasRecents: false, searchesServer: true) == .prompt(detail: "Songs, albums, artists and playlists"))
        #expect(SearchIdleState(hasRecents: false, searchesServer: false) == .prompt(detail: "Downloaded songs and playlists"))
        #expect(SearchIdleState.promptTitle == "Search your library")
    }
}

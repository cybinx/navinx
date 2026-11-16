import Foundation
import Testing
@testable import SubsonicKit

@Suite struct PingAndErrorTests {
    @Test func pingReadsTheServer() async throws {
        let (client, transport) = try makeClient(["ping": .fixture("ping")])
        let info = try await client.ping()
        #expect(info == ServerInfo(type: "navidrome", serverVersion: "0.64.2 (10114574)", isOpenSubsonic: true, apiVersion: "1.16.1"))
        let url = try #require(transport.requests.first)
        #expect(url.absoluteString.hasPrefix("https://music.example.com/rest/ping?u=demo&v=1.16.1&c=Navinx&f=json&t="))
    }

    @Test func pingNormalizesTheType() async throws {
        // A type is kept as the server gives it: no server is known by name (C50).
        let other = #"{"subsonic-response":{"status":"ok","version":"1.16.1","type":"Some-Proxy"}}"#
        let (a, _) = try makeClient(["ping": .body(other)])
        #expect(try await a.ping().type == "Some-Proxy")

        let open = #"{"subsonic-response":{"status":"ok","version":"1.16.1","openSubsonic":"true"}}"#
        let (b, _) = try makeClient(["ping": .body(open)])
        #expect(try await b.ping().type == "OpenSubsonic")

        let plain = #"{"subsonic-response":{"status":"ok","version":"1.15.0"}}"#
        let (c, _) = try makeClient(["ping": .body(plain)])
        let info = try await c.ping()
        #expect(info.type == nil && !info.isOpenSubsonic && info.apiVersion == "1.15.0")
    }

    /// The real answer to a wrong password: HTTP 200, `status: failed`, code 40.
    @Test func wrongPasswordIsAnAPIError() async throws {
        let (client, _) = try makeClient(["ping": .fixture("ping_wrong_password")])
        let error = await #expect(throws: SubsonicError.self) { try await client.ping() }
        #expect(error == .api(code: 40, message: "Wrong username or password"))
        #expect(error?.isAuthenticationFailure == true)
        #expect(error?.errorDescription == "Wrong username or password")
    }

    @Test func notFoundIsAnAPIError() async throws {
        let (client, _) = try makeClient(["getPlaylist": .fixture("getPlaylist_notFound")])
        await #expect(throws: SubsonicError.api(code: 70, message: "playlist not found")) {
            try await client.playlist(id: "doesnotexist")
        }
    }

    @Test(arguments: [
        (Reply.status(401), SubsonicError.unauthorized, "Invalid username or password."),
        // A proxy's or firewall's 403 isn't a wrong password.
        (Reply.status(403), SubsonicError.forbidden, "Access denied (HTTP 403). The server or its proxy refused the request."),
        (Reply.status(404), SubsonicError.notFound, "Server not found. Check your URL path."),
        (Reply.status(503), SubsonicError.server(status: 503), "Server error (503). The server failed to process the request."),
        (Reply.status(418), SubsonicError.http(status: 418), "Request failed (HTTP 418)."),
        (Reply.failure(.timedOut), SubsonicError.timedOut, "Connection timed out. Check your server URL."),
        (Reply.failure(.cannotFindHost), SubsonicError.cannotConnect, "Cannot connect to server. Check the URL and your internet connection."),
        (Reply.failure(.cannotConnectToHost), SubsonicError.cannotConnect, "Cannot connect to server. Check the URL and your internet connection."),
        (Reply.failure(.notConnectedToInternet), SubsonicError.cannotConnect, "Cannot connect to server. Check the URL and your internet connection."),
        (Reply.failure(.serverCertificateUntrusted), SubsonicError.certificate, "SSL certificate error. Check the server's certificate."),
        // Also what an https:// address on a plain-HTTP port gives.
        (Reply.failure(.secureConnectionFailed), SubsonicError.secureConnection, "Could not make a secure connection. Check whether the server uses https."),
        (Reply.failure(.badServerResponse), SubsonicError.network, "Network error. Check your connection."),
        (Reply.body("<html>proxy page</html>"), SubsonicError.invalidResponse, "Invalid response format"),
        (Reply.body(#"{"other":1}"#), SubsonicError.invalidResponse, "Invalid response format"),
    ])
    func mapsFailures(reply: Reply, expected: SubsonicError, message: String) async throws {
        let (client, _) = try makeClient(["ping": reply])
        let error = await #expect(throws: SubsonicError.self) { try await client.ping() }
        #expect(error == expected)
        #expect(error?.errorDescription == message)
    }

    /// Only a 401 or the API's own codes send the user to the password: not a 403.
    @Test func onlyA401OrTheAPIsCodesAreAuthenticationFailures() {
        #expect(SubsonicError.unauthorized.isAuthenticationFailure)
        #expect(SubsonicError.api(code: 40, message: nil).isAuthenticationFailure)
        #expect(!SubsonicError.forbidden.isAuthenticationFailure)
        #expect(!SubsonicError.secureConnection.isAuthenticationFailure)
    }

    @Test func cancellationStaysCancellation() async throws {
        let (client, _) = try makeClient(["ping": .failure(.cancelled)])
        await #expect(throws: CancellationError.self) { try await client.ping() }
    }

    @Test func aBrokenPayloadIsInvalidResponse() async throws {
        let body = #"{"subsonic-response":{"status":"ok","album":"not an object"}}"#
        let (client, _) = try makeClient(["getAlbum": .body(body)])
        await #expect(throws: SubsonicError.invalidResponse) { try await client.album(id: "x") }
    }
}

@Suite struct LANTests {
    let config = ServerConfig(serverURL: "https://nd.example.com", homeNetworkURL: "lan-host:4533", username: "u", password: "p")

    @Test func usesTheLANWhenItAnswers() async throws {
        let transport = FakeTransport(byHost: ["lan-host": .fixture("ping")])
        let client = try await SubsonicClient.connect(config: config, coverArtSalt: "s", transport: transport)
        #expect(client.baseURL.absoluteString == "http://lan-host:4533")
        #expect(transport.requests.map { $0.host() } == ["lan-host"])
        #expect(client.streamURL(songID: "1").host() == "lan-host")
    }

    /// The probe carries no login (D180), with a token login or legacy auth's password.
    @Test(arguments: [false, true])
    func theProbeCarriesNoLogin(sendsPlainPassword: Bool) async throws {
        var config = self.config
        config.sendsPlainPassword = sendsPlainPassword
        let transport = FakeTransport(byHost: ["lan-host": .fixture("ping")])
        _ = try await SubsonicClient.connect(config: config, coverArtSalt: "s", transport: transport)
        let probe = try #require(transport.requests.first)
        #expect(probe.absoluteString == "http://lan-host:4533/rest/ping?v=1.16.1&c=Navinx&f=json")
        for name in ["u", "t", "s", "p"] {
            #expect(probe.params[name] == nil)
        }
    }

    /// Navidrome's real answer to an unsigned `ping` (recorded 2026-11-14, C50): HTTP 200, failed,
    /// code 10. It is a Subsonic server, so the LAN address is used.
    @Test func aFailedSubsonicAnswerSelectsTheLAN() async throws {
        let unsigned = #"{"subsonic-response":{"status":"failed","version":"1.16.1","type":"navidrome","serverVersion":"0.64.2 (10114574)","openSubsonic":true,"error":{"code":10,"message":"missing parameter: 'u'"}}}"#
        let transport = FakeTransport(byHost: ["lan-host": .body(unsigned)])
        let client = try await SubsonicClient.connect(config: config, coverArtSalt: "s", transport: transport)
        #expect(client.baseURL.absoluteString == "http://lan-host:4533")
    }

    /// A timeout, or nothing listening there.
    @Test(arguments: [URLError.Code.timedOut, .cannotConnectToHost])
    func fallsBackWhenTheLANFails(error: URLError.Code) async throws {
        let transport = FakeTransport(byHost: ["lan-host": .failure(error)])
        let client = try await SubsonicClient.connect(config: config, coverArtSalt: "s", transport: transport)
        #expect(client.baseURL.absoluteString == "https://nd.example.com")
    }

    @Test func fallsBackOnANon200() async throws {
        let transport = FakeTransport(byHost: ["lan-host": .status(502)])
        let client = try await SubsonicClient.connect(config: config, coverArtSalt: "s", transport: transport)
        #expect(client.baseURL.absoluteString == "https://nd.example.com")
    }

    /// Another network's router at that address answers 200 too: only a Subsonic answer counts
    /// (Flutter checked only the status).
    @Test(arguments: [Reply.body("<html>router login</html>"), Reply.status(200), Reply.body(#"{"ok":true}"#)])
    func fallsBackWhenTheAnswerIsNotSubsonic(reply: Reply) async throws {
        let transport = FakeTransport(byHost: ["lan-host": reply])
        let client = try await SubsonicClient.connect(config: config, coverArtSalt: "s", transport: transport)
        #expect(client.baseURL.absoluteString == "https://nd.example.com")
    }

    @Test func noLANMeansNoProbe() async throws {
        let transport = FakeTransport()
        let client = try await SubsonicClient.connect(config: testConfig, coverArtSalt: "s", transport: transport)
        #expect(client.baseURL.absoluteString == "https://music.example.com")
        #expect(transport.requests.isEmpty)
    }
}

/// The re-check, item 10: a home-network address that refuses the login is checked against the main one.
@Suite struct HomeAddressRefusalTests {
    let config = ServerConfig(serverURL: "https://nd.example.com", homeNetworkURL: "lan-host:4533", username: "u", password: "p")
    static let refused = #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":40,"message":"Wrong username or password"}}}"#

    /// Another music server at that private address: the main one takes the login, and its client has no
    /// home-network address, so nothing goes back there.
    @Test func theMainAddressIsUsedWhenItTakesTheLogin() async throws {
        let transport = FakeTransport(byHost: ["lan-host": .body(Self.refused), "nd.example.com": .fixture("ping")])
        let (client, _) = try await SubsonicClient.connectAndPing(config: config, coverArtSalt: "s", transport: transport)
        #expect(client.baseURL.absoluteString == "https://nd.example.com")
        #expect(client.config.normalizedHomeNetworkURL == nil)
        #expect(client.signedLoginQuery(for: URL(string: "http://lan-host:4533")!) == nil)
        #expect(transport.requests.map { $0.host() } == ["lan-host", "lan-host", "nd.example.com"])
    }

    /// Both refuse: the password is wrong.
    @Test func bothRefusingIsARefusal() async throws {
        let transport = FakeTransport(byHost: ["lan-host": .body(Self.refused), "nd.example.com": .body(Self.refused)])
        await #expect(throws: SubsonicError.api(code: 40, message: "Wrong username or password")) {
            _ = try await SubsonicClient.connectAndPing(config: config, coverArtSalt: "s", transport: transport)
        }
    }

    /// The main address doesn't answer: the home one's refusal stands.
    @Test func anUnansweredMainAddressLeavesTheRefusal() async throws {
        let transport = FakeTransport(byHost: ["lan-host": .body(Self.refused), "nd.example.com": .failure(.cannotConnectToHost)])
        await #expect(throws: SubsonicError.api(code: 40, message: "Wrong username or password")) {
            _ = try await SubsonicClient.connectAndPing(config: config, coverArtSalt: "s", transport: transport)
        }
    }

    /// The home-network address takes the login: used as before, the main one never asked.
    @Test func anAcceptedHomeAddressIsUsedAsBefore() async throws {
        let transport = FakeTransport(byHost: ["lan-host": .fixture("ping")])
        let (client, _) = try await SubsonicClient.connectAndPing(config: config, coverArtSalt: "s", transport: transport)
        #expect(client.baseURL.absoluteString == "http://lan-host:4533")
        #expect(transport.requests.allSatisfy { $0.host() == "lan-host" })
    }
}

@Suite struct BrowseTests {
    @Test func musicFoldersWithNumericIDs() async throws {
        let (client, _) = try makeClient(["getMusicFolders": .fixture("getMusicFolders")])
        #expect(try await client.musicFolders() == [MusicFolder(id: "1", name: "Music Library")])
    }

    @Test func artistsFromTheRecordedLibrary() async throws {
        let (client, _) = try makeClient(["getArtists": .fixture("getArtists")])
        let artists = try await client.artists()
        // Sorted by code point, as in Flutter: "[" sorts before letters.
        #expect(artists.map(\.name) == ["[Unknown Artist]", "Cochise", "Smino"])
        let cochise = try #require(artists.first { $0.name == "Cochise" })
        #expect(cochise.id == "47J4kLtntqT8Xa9X4NVbnv")
        #expect(cochise.albumCount == 3)
        #expect(cochise.coverArt == "ar-47J4kLtntqT8Xa9X4NVbnv_a339949c6ca9a8b0")
        #expect(cochise.artistImageURL == "http://<navidrome-host>:4533/share/img/<token>?size=600")
    }

    @Test func artistsSplitMergeAndSort() async throws {
        let (client, _) = try makeClient(["getArtists": .fixture("Handwritten/getArtists_combined")])
        let artists = try await client.artists()
        #expect(artists.map(\.name) == ["Alpha", "beta", "Charlie", "Delta"])
        // "Alpha & Beta" split first; the later plain "Alpha" doesn't replace it.
        #expect(artists[0].id == "ar-ab" && artists[0].albumCount == 2 && artists[0].coverArt == "ar-ab_1")
        // "beta" had no ID, so the split "Beta" merges in: its ID and cover, counts added, first name kept.
        #expect(artists[1].id == "ar-ab" && artists[1].albumCount == 3 && artists[1].coverArt == "ar-ab_1")
        // From the `artists` list: each keeps its own ID; the cover is its own, else its ID.
        #expect(artists[2].id == "ar-c" && artists[2].coverArt == "ar-c")
        #expect(artists[3].id == "ar-d" && artists[3].coverArt == "ar-d_9")
    }

    @Test func emptyArtistIndex() async throws {
        let body = #"{"subsonic-response":{"status":"ok","artists":{"ignoredArticles":""}}}"#
        let (client, _) = try makeClient(["getArtists": .body(body)])
        #expect(try await client.artists().isEmpty)
    }

    @Test func artistWithAlbums() async throws {
        let (client, transport) = try makeClient(["getArtist": .fixture("getArtist")])
        let artist = try await client.artist(id: "47J4kLtntqT8Xa9X4NVbnv")
        #expect(artist.name == "Cochise")
        #expect(artist.albums.count == 3)
        #expect(artist.albums.allSatisfy { $0.artistID == "47J4kLtntqT8Xa9X4NVbnv" })
        #expect(transport.requests.first?.params["id"] == "47J4kLtntqT8Xa9X4NVbnv")
    }

    @Test func artistInfo() async throws {
        let (client, _) = try makeClient(["getArtistInfo2": .fixture("getArtistInfo2")])
        let info = try await client.artistInfo(id: "a")
        #expect(info.biography?.hasPrefix("Cochise is entering a new era.") == true)
        #expect(info.largeImageURL == "http://<navidrome-host>:4533/share/img/<token>?size=1200")
        #expect(info.lastFmURL == nil)
        // Navidrome leaves the key out when no similar artist is in the library.
        #expect(info.similarArtists.isEmpty)
    }

    /// C35: recorded for an artist with similar artists in the library.
    @Test func artistInfoWithSimilarArtists() async throws {
        let (client, _) = try makeClient(["getArtistInfo2": .fixture("getArtistInfo2_similar")])
        let info = try await client.artistInfo(id: "a")
        #expect(info.similarArtists.map(\.name) == ["Steve Lacy", "Chance the Rapper", "The Internet", "Thundercat", "Smino", "SZA"])
        let first = try #require(info.similarArtists.first)
        #expect(first.id == "3kS0ySISkYPwDV2Eoi6hFq")
        #expect(first.coverArt?.hasPrefix("ar-3kS0ySISkYPwDV2Eoi6hFq") == true)
        #expect(first.albumCount == 9)
    }

    @Test func similarArtistsLenient() async throws {
        // One object where a list is expected, and Navidrome's mark for an artist not in the library.
        let one = #"{"subsonic-response":{"status":"ok","artistInfo2":{"similarArtist":{"id":"x","name":"X"}}}}"#
        let (client, _) = try makeClient(["getArtistInfo2": .body(one)])
        #expect(try await client.artistInfo(id: "a").similarArtists.map(\.id) == ["x"])
        let absent = #"{"subsonic-response":{"status":"ok","artistInfo2":{"similarArtist":[{"id":"-1","name":"Gone"},{"id":"","name":"No ID"},{"id":"y","name":"Y"}]}}}"#
        let (other, _) = try makeClient(["getArtistInfo2": .body(absent)])
        #expect(try await other.artistInfo(id: "a").similarArtists.map(\.id) == ["y"])
    }

    /// The older call's similar artists carry folder IDs, which `getArtist` can't open: dropped.
    @Test func similarArtistsNotFromTheFallback() async throws {
        let v1 = #"{"subsonic-response":{"status":"ok","artistInfo":{"biography":"old","similarArtist":[{"id":"folder-1","name":"F"}]}}}"#
        let (client, _) = try makeClient(["getArtistInfo2": .status(404), "getArtistInfo": .body(v1)])
        let info = try await client.artistInfo(id: "a")
        #expect(info.biography == "old" && info.similarArtists.isEmpty)
    }

    @Test func song() async throws {
        let (client, transport) = try makeClient(["getSong": .fixture("getSong")])
        let song = try await client.song(id: "s1")
        #expect(song.title == "General" && song.suffix == "flac")
        #expect(song.samplingRate == 44100 && song.bitDepth == 16 && song.channelCount == 2)
        #expect(song.track == 2 && song.discNumber == 1 && song.year == 2017)
        #expect(transport.requests.first?.params["id"] == "s1")
    }

    @Test func artistInfoFallsBackToV1() async throws {
        let v1 = #"{"subsonic-response":{"status":"ok","artistInfo":{"biography":"old server"}}}"#
        let (client, transport) = try makeClient(["getArtistInfo2": .status(404), "getArtistInfo": .body(v1)])
        #expect(try await client.artistInfo(id: "a").biography == "old server")
        #expect(transport.requests.map(\.lastPathComponent) == ["getArtistInfo2", "getArtistInfo"])
    }

    @Test func topSongsAsksByName() async throws {
        let (client, transport) = try makeClient(["getArtist": .fixture("getArtist"), "getTopSongs": .fixture("getTopSongs")])
        let songs = try await client.topSongs(artistID: "47J4kLtntqT8Xa9X4NVbnv", count: 5)
        #expect(songs.map(\.title) == ["Jackson"])
        let topSongs = try #require(transport.requests.last)
        #expect(topSongs.params["artist"] == "Cochise" && topSongs.params["count"] == "5")
    }

    @Test func topSongsFallsBackToTheFirstAlbums() async throws {
        let (client, _) = try makeClient([
            "getArtist": .fixture("getArtist"),
            "getTopSongs": .status(500),
            "getAlbum": .fixture("getAlbum"),
        ])
        let songs = try await client.topSongs(artistID: "a", count: 20)
        // The first album already has 14 songs; the second brings it past 20, cut to 20.
        #expect(songs.count == 20)
    }

    @Test func albumWithSongs() async throws {
        let (client, _) = try makeClient(["getAlbum": .fixture("getAlbum")])
        let album = try await client.album(id: "5tDNdwIQTVclZb9ASelEZJ")
        #expect(album.name == "me" && album.artist == "Cochise")
        #expect(album.songCount == 14 && album.songs.count == 14 && album.duration == 2140)
        #expect(album.coverArt == "al-5tDNdwIQTVclZb9ASelEZJ_898ad586020c6801")
        #expect(album.artists == [ArtistCredit(id: "47J4kLtntqT8Xa9X4NVbnv", name: "Cochise")])
        #expect(album.created != nil && !album.starred)
        let song = try #require(album.songs.first)
        #expect(song.title == "Blackity" && song.duration == 118 && song.bitRate == 192)
        #expect(song.albumID == album.id && song.created != nil && song.replayGain.isEmpty)
    }

    @Test func albumListSendsTypeSizeOffset() async throws {
        let (client, transport) = try makeClient(["getAlbumList2": .fixture("getAlbumList2_newest")])
        let albums = try await client.albumList(.newest, size: 3, offset: 6)
        #expect(albums.count == 3)
        let params = try #require(transport.requests.first?.params)
        #expect(params["type"] == "newest" && params["size"] == "3" && params["offset"] == "6")
    }

    @Test func albumListAcceptsASingleObject() async throws {
        let (client, _) = try makeClient(["getAlbumList2": .fixture("Handwritten/getAlbumList2_single")])
        let albums = try await client.albumList(.random)
        #expect(albums == [Album(id: "42", name: "Numbered", songCount: 9, year: 2001)])
    }

    @Test func randomSongs() async throws {
        let (client, transport) = try makeClient(["getRandomSongs": .fixture("getRandomSongs")])
        #expect(try await client.randomSongs(size: 3).count == 3)
        #expect(transport.requests.first?.params["genre"] == nil)
        _ = try await client.randomSongs(genre: "Rap")
        #expect(transport.requests.last?.params["genre"] == "Rap")
    }

    @Test func similarSongsFallsBackToV1() async throws {
        let (a, _) = try makeClient(["getSimilarSongs2": .fixture("getSimilarSongs2")])
        #expect(try await a.similarSongs(id: "1").map(\.title) == ["Jackson"])

        let v1 = #"{"subsonic-response":{"status":"ok","similarSongs":{"song":[{"id":"9","title":"Old"}]}}}"#
        let failed = #"{"subsonic-response":{"status":"failed","error":{"code":0,"message":"no"}}}"#
        let (b, _) = try makeClient(["getSimilarSongs2": .body(failed), "getSimilarSongs": .body(v1)])
        #expect(try await b.similarSongs(id: "1").map(\.title) == ["Old"])
    }

    @Test func starred() async throws {
        let (client, _) = try makeClient(["getStarred2": .fixture("Handwritten/getStarred2")])
        let starred = try await client.starred()
        #expect(starred.artists.map(\.name) == ["Cochise"])
        #expect(starred.albums.map(\.name) == ["me"] && starred.albums[0].starred)
        #expect(starred.songs.map(\.title) == ["Jackson"] && starred.songs[0].starred && starred.songs[0].userRating == 4)

        let (empty, _) = try makeClient(["getStarred2": .fixture("getStarred2_empty")])
        #expect(try await empty.starred().isEmpty)
    }

    @Test func search() async throws {
        let (client, transport) = try makeClient(["search3": .fixture("search3")])
        let result = try await client.search("cochise")
        // Search results aren't split (as in Flutter); only the Library's artist list is.
        #expect(result.artists.map(\.name) == ["Cochise", "Cochise & Pradabagshawty"])
        #expect(!result.albums.isEmpty && !result.songs.isEmpty)
        let params = try #require(transport.requests.first?.params)
        #expect(params["query"] == "cochise")
        #expect(params["artistCount"] == "20" && params["albumCount"] == "20" && params["songCount"] == "20")

        let (empty, _) = try makeClient(["search3": .fixture("search3_empty")])
        #expect(try await empty.search("zzzzqqq").isEmpty)
    }
}

@Suite struct PlaylistAndLyricsTests {
    @Test func playlists() async throws {
        let (client, _) = try makeClient(["getPlaylists": .fixture("Handwritten/getPlaylists")])
        let playlists = try await client.playlists()
        #expect(playlists.map(\.name) == ["Late night", "Gym"])
        let first = playlists[0]
        #expect(first.comment == "slow ones" && first.owner == "api" && first.isPublic == false)
        #expect(first.songCount == 2 && first.formattedDuration == "1 h 5 min")
        #expect(first.created != nil && first.changed != nil && first.songs == nil)

        let (empty, _) = try makeClient(["getPlaylists": .fixture("getPlaylists_empty")])
        #expect(try await empty.playlists().isEmpty)
    }

    @Test func playlistWithSongs() async throws {
        let (client, _) = try makeClient(["getPlaylist": .fixture("Handwritten/getPlaylist")])
        let playlist = try await client.playlist(id: "pl-1")
        #expect(playlist.songs?.map(\.title) == ["Jackson", "Pow Wow"])
        #expect(playlist.songs?.map(\.starred) == [true, false])
    }

    @Test func structuredLyrics() async throws {
        let (client, _) = try makeClient(["getLyricsBySongId": .fixture("Handwritten/getLyricsBySongId")])
        let lyrics = try await client.lyricsBySongID("1")
        #expect(lyrics.count == 2)
        #expect(lyrics[0].synced && lyrics[0].offset == -100 && lyrics[0].lang == "eng")
        #expect(lyrics[0].lines.map(\.start) == [0, 2500, 5100])
        #expect(lyrics[0].lines.map(\.value) == ["First line", "Second line", ""])
        #expect(!lyrics[1].synced && lyrics[1].lines.allSatisfy { $0.start == nil })
    }

    @Test func noStructuredLyrics() async throws {
        let (client, _) = try makeClient(["getLyricsBySongId": .fixture("getLyricsBySongId")])
        #expect(try await client.lyricsBySongID("1").isEmpty)
    }

    @Test func plainLyrics() async throws {
        let (client, transport) = try makeClient(["getLyrics": .fixture("getLyrics")])
        #expect(try await client.lyrics(artist: "Cochise", title: "x") == Lyrics(value: ""))
        let params = try #require(transport.requests.first?.params)
        #expect(params["artist"] == "Cochise" && params["title"] == "x")
    }
}

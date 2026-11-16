import Foundation
import Testing
@testable import SubsonicKit

@Suite struct ServerConfigTests {
    @Test func addsHTTPSWhenNoScheme() {
        #expect(ServerConfig(serverURL: " music.example.com/ ", username: "u", password: "p").normalizedURL
            == "https://music.example.com")
    }

    @Test func keepsAGivenScheme() {
        #expect(ServerConfig(serverURL: "http://host:4533/", username: "u", password: "p").normalizedURL
            == "http://host:4533")
        #expect(ServerConfig(serverURL: "https://nd.home.example/sub", username: "u", password: "p").normalizedURL
            == "https://nd.home.example/sub")
    }

    @Test func homeNetworkURLDefaultsToHTTPAndKeepsHTTPS() {
        var config = ServerConfig(serverURL: "a", homeNetworkURL: "host:4533", username: "u", password: "p")
        #expect(config.normalizedHomeNetworkURL == "http://host:4533")
        config.homeNetworkURL = "https://nd.home.example/"
        #expect(config.normalizedHomeNetworkURL == "https://nd.home.example")
        config.homeNetworkURL = "  "
        #expect(config.normalizedHomeNetworkURL == nil)
        config.homeNetworkURL = nil
        #expect(config.normalizedHomeNetworkURL == nil)
    }

    /// One form per address: either-case scheme, lower-case host (not path), no query, fragment
    /// or trailing slashes, and the same back for an address already in that form.
    @Test func normalizesOneWay() {
        #expect(ServerConfig.normalize("HTTPS://Music.Example.com//", defaultScheme: "https") == "https://music.example.com")
        #expect(ServerConfig.normalize("https://host/App/#/login", defaultScheme: "https") == "https://host/App")
        #expect(ServerConfig.normalize("https://host:4533/sub?x=1", defaultScheme: "https") == "https://host:4533/sub")
        #expect(ServerConfig.normalize(" Host:4533 ", defaultScheme: "http") == "http://host:4533")
        #expect(ServerConfig.normalize("https://Me:PW@Host/Sub", defaultScheme: "https") == "https://Me:PW@host/Sub")
        let normal = "https://nd.home.example/Music"
        #expect(ServerConfig.normalize(normal, defaultScheme: "https") == normal)
    }

    /// A user and password in the address, even with a `#` or `?` in that password.
    @Test func findsAUserInTheAddress() {
        #expect(ServerConfig.hasUserInfo("https://me:pw@host"))
        #expect(ServerConfig.hasUserInfo(" me:pw@host:4533/sub "))
        #expect(ServerConfig.hasUserInfo("https://me:p#w?x@host"))
        #expect(!ServerConfig.hasUserInfo("https://host:4533/sub"))
        #expect(!ServerConfig.hasUserInfo("https://host/path@x"))
    }

    @Test func validNeedsAllThree() {
        #expect(ServerConfig(serverURL: "a", username: "u", password: "p").isValid)
        #expect(!ServerConfig(serverURL: "", username: "u", password: "p").isValid)
        #expect(!ServerConfig(serverURL: "a", username: "", password: "p").isValid)
        #expect(!ServerConfig(serverURL: "a", username: "u", password: "").isValid)
    }
}

@Suite struct AuthTests {
    /// The example in the Subsonic API docs.
    @Test func tokenIsMD5OfPasswordAndSalt() {
        #expect(Auth.token(password: "sesame", salt: "c19b2d") == "26719a1196d2a940705a59634eb18eab")
    }

    @Test func tokenAuthSendsTokenAndSaltNotPassword() {
        let items = Auth.queryItems(for: testConfig, salt: "abc")
        #expect(items.map(\.0) == ["u", "v", "c", "f", "t", "s"])
        let params = Dictionary(uniqueKeysWithValues: items)
        #expect(params["u"] == "demo")
        #expect(params["v"] == "1.16.1")
        #expect(params["c"] == "Navinx")
        #expect(params["f"] == "json")
        #expect(params["t"] == Auth.token(password: "demo", salt: "abc"))
        #expect(params["s"] == "abc")
        #expect(params["p"] == nil)
    }

    @Test func legacyAuthSendsThePassword() {
        var config = testConfig
        config.sendsPlainPassword = true
        let params = Dictionary(uniqueKeysWithValues: Auth.queryItems(for: config, salt: "abc"))
        #expect(params["p"] == "demo")
        #expect(params["t"] == nil && params["s"] == nil)
    }

    @Test func saltsAreRandomHex() {
        let a = Auth.makeSalt(), b = Auth.makeSalt()
        #expect(a.count == 8 && a != b)
        #expect(a.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(SubsonicClient.makeCoverArtSalt().count == 16)
    }

    @Test func encodesEverythingButUnreserved() throws {
        let url = Auth.url(
            base: try #require(URL(string: "https://h")),
            endpoint: "search3",
            items: [("query", "a&b+c=d%e f/ü"), ("p", "x?y#z")]
        )
        #expect(url.absoluteString == "https://h/rest/search3?query=a%26b%2Bc%3Dd%25e%20f%2F%C3%BC&p=x%3Fy%23z")
        #expect(url.params["query"] == "a&b+c=d%e f/ü")
    }
}

@Suite struct URLBuilderTests {
    @Test func coverArtURLIsStable() throws {
        let (client, _) = try makeClient()
        let first = try #require(client.coverArtURL("al-1", size: 300))
        #expect(first == client.coverArtURL("al-1", size: 300))
        #expect(first.absoluteString.hasPrefix("https://music.example.com/rest/getCoverArt?"))
        #expect(first.params["id"] == "al-1")
        #expect(first.params["size"] == "300")
        #expect(first.params["s"] == "stablesalt123456")
    }

    @Test func coverArtDefaultsTo600AndOmitsSizeZero() throws {
        let (client, _) = try makeClient()
        #expect(client.coverArtURL("x")?.params["size"] == "600")
        #expect(client.coverArtURL("x", size: 0)?.params["size"] == nil)
    }

    @Test func coverArtNilEmptyAndFullURLs() throws {
        let (client, _) = try makeClient()
        #expect(client.coverArtURL(nil) == nil)
        #expect(client.coverArtURL("") == nil)
        #expect(client.coverArtURL("https://img.example/a.jpg")?.absoluteString == "https://img.example/a.jpg")
    }

    @Test func streamURL() throws {
        let (client, _) = try makeClient()
        let plain = client.streamURL(songID: "song123")
        #expect(plain.absoluteString.hasPrefix("https://music.example.com/rest/stream?"))
        #expect(plain.params["id"] == "song123")
        #expect(plain.params["maxBitRate"] == nil && plain.params["format"] == nil)

        let transcoded = client.streamURL(songID: "song123", maxBitRate: 320, format: "mp3")
        #expect(transcoded.params["maxBitRate"] == "320")
        #expect(transcoded.params["format"] == "mp3")

        let raw = client.streamURL(songID: "s", maxBitRate: 0, format: "raw")
        #expect(raw.params["maxBitRate"] == nil && raw.params["format"] == "raw")
    }

    @Test func streamAndDownloadGetAFreshSalt() throws {
        let (client, _) = try makeClient()
        #expect(client.streamURL(songID: "s").params["s"] != client.streamURL(songID: "s").params["s"])
        let download = client.downloadURL(songID: "s1")
        #expect(download.path() == "/rest/download")
        #expect(download.params["id"] == "s1")
    }

    @Test func keepsAPathInTheServerAddress() throws {
        let config = ServerConfig(serverURL: "https://nd.home.example/music/", username: "u", password: "p")
        let (client, _) = try makeClient(config: config)
        #expect(client.downloadURL(songID: "1").path() == "/music/rest/download")
    }

    /// D100, D101: the server's `/eq` and `/panel` get the signed login only on this account's own host,
    /// never down from https to http, and never with legacy auth (whose `p` is the password).
    @Test func signedLoginGoesOnlyToTheServersOwnHost() throws {
        let home = ServerConfig(serverURL: "http://10.0.0.5:4533", username: "me", password: "pw")
        let (client, _) = try makeClient(config: home)
        let query = try #require(client.signedLoginQuery(for: URL(string: "http://10.0.0.5:8787")!))
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(string: "?" + query)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(Set(items.keys) == ["u", "t", "s"] && items["u"] == "me" && items["p"] == nil)
        #expect(client.signedLoginQuery(for: URL(string: "http://10.0.0.6:8787")!) == nil)

        let secure = ServerConfig(serverURL: "https://nd.example", homeNetworkURL: "192.168.1.9:4533", username: "me", password: "pw")
        let (remote, _) = try makeClient(config: secure)
        #expect(remote.signedLoginQuery(for: URL(string: "http://nd.example:8787")!) == nil)
        #expect(remote.signedLoginQuery(for: URL(string: "https://nd.example:8787")!) != nil)
        #expect(remote.signedLoginQuery(for: URL(string: "http://192.168.1.9:8787")!) != nil)

        let legacy = ServerConfig(serverURL: "http://10.0.0.5:4533", username: "me", password: "pw", sendsPlainPassword: true)
        let (old, _) = try makeClient(config: legacy)
        #expect(old.signedLoginQuery(for: URL(string: "http://10.0.0.5:8787")!) == nil)
    }

    @Test(arguments: ["https://", "https://my server"])
    func rejectsAnAddressWithNoHost(address: String) {
        #expect(throws: SubsonicError.invalidURL) {
            try SubsonicClient(
                config: ServerConfig(serverURL: address, username: "u", password: "p"),
                coverArtSalt: "s"
            )
        }
    }

    /// A pasted web-page address keeps the API path out of its fragment.
    @Test func dropsAQueryAndFragmentFromTheServerAddress() throws {
        let config = ServerConfig(serverURL: "https://nd.home.example/app/#/login", username: "u", password: "p")
        let (client, _) = try makeClient(config: config)
        let url = client.downloadURL(songID: "1")
        #expect(url.path() == "/app/rest/download")
        #expect(url.fragment() == nil)
    }
}

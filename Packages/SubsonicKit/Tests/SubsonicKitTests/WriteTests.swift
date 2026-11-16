import Foundation
import Testing
@testable import SubsonicKit

@Suite struct WriteTests {
    private static let ok = Reply.body(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#)

    @Test func starAndUnstarSendTheGivenKinds() async throws {
        let (client, transport) = try makeClient(["star": Self.ok, "unstar": Self.ok])
        try await client.star(id: "song")
        try await client.star(albumID: "album")
        try await client.unstar(artistID: "artist")

        #expect(transport.requests[0].lastPathComponent == "star")
        #expect(transport.requests[0].params["id"] == "song")
        #expect(transport.requests[0].params["albumId"] == nil)
        #expect(transport.requests[1].params["albumId"] == "album")
        #expect(transport.requests[2].lastPathComponent == "unstar")
        #expect(transport.requests[2].params["artistId"] == "artist")
    }

    @Test func setRatingSendsTheRating() async throws {
        let (client, transport) = try makeClient(["setRating": Self.ok])
        try await client.setRating(id: "song", rating: 4)
        let url = try #require(transport.requests.first)
        #expect(url.params["id"] == "song" && url.params["rating"] == "4")
    }

    @Test func addToPlaylistSendsEachSong() async throws {
        let (client, transport) = try makeClient(["updatePlaylist": Self.ok])
        try await client.addToPlaylist(id: "list", songIDs: ["a", "b"])
        let url = try #require(transport.requests.first)
        #expect(url.params["playlistId"] == "list")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.filter { $0.name == "songIdToAdd" }.map(\.value) == ["a", "b"])
    }

    private func values(_ url: URL, _ name: String) -> [String?] {
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .filter { $0.name == name }
            .map(\.value)
    }

    @Test func createPlaylistSendsTheName() async throws {
        let (client, transport) = try makeClient(["createPlaylist": Self.ok])
        try await client.createPlaylist(name: "Road & Trip")
        let url = try #require(transport.requests.first)
        #expect(url.params["name"] == "Road & Trip")
        #expect(url.params["playlistId"] == nil)
    }

    @Test func updatePlaylistSendsOnlyWhatChanges() async throws {
        let (client, transport) = try makeClient(["updatePlaylist": Self.ok])
        try await client.updatePlaylist(id: "list", name: "New name")
        try await client.updatePlaylist(id: "list", songIndexesToRemove: [3, 1])

        #expect(transport.requests[0].params["name"] == "New name")
        #expect(values(transport.requests[0], "songIndexToRemove").isEmpty)
        #expect(transport.requests[1].params["name"] == nil)
        #expect(values(transport.requests[1], "songIndexToRemove") == ["3", "1"])
        #expect(transport.requests.allSatisfy { $0.params["playlistId"] == "list" })
    }

    /// The whole order, in order, with repeats, and no name that could overwrite the playlist's.
    @Test func setPlaylistSongsSendsTheWholeOrder() async throws {
        let (client, transport) = try makeClient(["createPlaylist": Self.ok])
        try await client.setPlaylistSongs(id: "list", songIDs: ["c", "a", "b", "a"])
        let url = try #require(transport.requests.first)
        #expect(url.lastPathComponent == "createPlaylist")
        #expect(url.params["playlistId"] == "list")
        #expect(url.params["name"] == nil)
        #expect(values(url, "songId") == ["c", "a", "b", "a"])
    }

    /// A few hundred songs would make an address a proxy refuses: such a request goes as a POST,
    /// with every song still sent in order; a short one stays a GET.
    @Test func aLongRequestGoesAsAPost() async throws {
        let (client, transport) = try makeClient(["createPlaylist": Self.ok, "updatePlaylist": Self.ok])
        let songs = (1...400).map { "song-\($0)-0123456789abcdef" }
        try await client.setPlaylistSongs(id: "list", songIDs: songs)
        try await client.updatePlaylist(id: "list", songIndexesToRemove: Array(0..<400))
        try await client.updatePlaylist(id: "list", name: "Short")
        #expect(transport.posted.map(\.lastPathComponent) == ["createPlaylist", "updatePlaylist"])
        #expect(values(transport.requests[0], "songId").compactMap { $0 } == songs)
        #expect(values(transport.requests[1], "songIndexToRemove").count == 400)
        #expect(transport.requests.count == 3)
    }

    /// The POST's address has no query; the query, as sent in a GET, is the form body.
    @Test func aPostSendsTheQueryAsAFormBody() throws {
        let url = try #require(URL(string: "https://music.example.com/rest/createPlaylist?u=demo&songId=a%20b&songId=c"))
        let request = URLSessionTransport.formRequest(url, timeout: 30)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://music.example.com/rest/createPlaylist")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.httpBody == Data("u=demo&songId=a%20b&songId=c".utf8))
    }

    @Test func deletePlaylistSendsTheID() async throws {
        let (client, transport) = try makeClient(["deletePlaylist": Self.ok])
        try await client.deletePlaylist(id: "list")
        let url = try #require(transport.requests.first)
        #expect(url.lastPathComponent == "deletePlaylist" && url.params["id"] == "list")
    }

    @Test(arguments: [true, false])
    func scrobbleSendsTheSubmissionFlag(submission: Bool) async throws {
        let (client, transport) = try makeClient(["scrobble": Self.ok])
        try await client.scrobble(id: "song", submission: submission)
        let url = try #require(transport.requests.first)
        #expect(url.params["id"] == "song" && url.params["submission"] == String(submission))
        #expect(url.params["time"] == nil)
    }

    @Test func aLaterScrobbleSendsItsTimeInMilliseconds() async throws {
        let (client, transport) = try makeClient(["scrobble": Self.ok])
        try await client.scrobble(id: "song", submission: true, time: Date(timeIntervalSince1970: 1_700_000_000.25))
        let url = try #require(transport.requests.first)
        #expect(url.params["time"] == "1700000000250")
    }

    @Test func aFailedAnswerThrows() async throws {
        let failed = #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":50,"message":"Not allowed"}}}"#
        let (client, _) = try makeClient(["star": .body(failed)])
        await #expect(throws: SubsonicError.self) { try await client.star(id: "song") }
    }
}

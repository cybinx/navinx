import Foundation
import SubsonicKit
import Testing
@testable import Navinx

/// An album of three songs, a source playlist that repeats one, and a target playlist that already
/// has one of the album's songs under another ID. Records what `updatePlaylist` is asked to add.
private final class BatchServer: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var added: [[String]] = []

    var adds: [[String]] { lock.withLock { added } }

    func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let id = items.first { $0.name == "id" }?.value ?? ""
        func songs(_ list: [(String, String)]) -> String {
            list.map { #"{"id":"\#($0.0)","title":"\#($0.1)","artist":"Band"}"# }.joined(separator: ",")
        }
        var inner = ""
        switch url.lastPathComponent.replacingOccurrences(of: ".view", with: "") {
        case "getAlbum":
            inner = #","album":{"id":"\#(id)","name":"Album","song":[\#(songs([("a1", "One"), ("a2", "Two"), ("a3", "Three")]))]}"#
        case "getPlaylist":
            let list = id == "target" ? [("x2", "two "), ("t9", "Other")] : [("a1", "One"), ("a1", "One"), ("p5", "Five")]
            inner = #","playlist":{"id":"\#(id)","name":"List","entry":[\#(songs(list))]}"#
        case "updatePlaylist":
            lock.withLock { added.append(items.filter { $0.name == "songIdToAdd" }.compactMap(\.value)) }
        default:
            throw URLError(.badURL)
        }
        let body = #"{"subsonic-response":{"status":"ok","version":"1.16.1"\#(inner)}}"#
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// C48 (D166): "Add all to playlist" for an album or a playlist; songs already there are skipped
/// and said.
@MainActor
struct BatchActionTests {
    private func song(_ id: String, _ title: String) -> Song {
        Song(id: id, title: title, artist: "Band")
    }

    @Test func onlyTheSongsThePlaylistLacksAreMissingEachOnce() {
        let existing = [song("1", "One"), song("9", " TWO ")]
        let wanted = [song("1", "One"), song("2", "Two"), song("3", "Three"), song("3", "Three"), song("4", "three")]
        #expect(PlaylistMembership.missing(wanted, from: existing).map(\.id) == ["3"])
        #expect(PlaylistMembership.missing(wanted, from: []).map(\.id) == ["1", "2", "3"])
    }

    @Test func everySongGoesInWithOneRequestAndWhatIsThereIsSkipped() async throws {
        let server = BatchServer()
        let client = try SubsonicClient(
            config: ServerConfig(serverURL: "http://music.invalid:4533", username: "u", password: "p"),
            coverArtSalt: "salt", transport: server
        )
        let target = Playlist(id: "target", name: "Target")
        let album = try await BatchActions.addAll(.album(Album(id: "al", name: "Album", songs: [])), to: target, client: client)
        #expect(album == BatchAddResult(added: 2, skipped: 1))
        #expect(server.adds == [["a1", "a3"]])
        // A playlist as the source: a song it repeats goes in once.
        let list = try await BatchActions.addAll(.playlist(Playlist(id: "source", name: "Source")), to: target, client: client)
        #expect(list == BatchAddResult(added: 2, skipped: 1))
        #expect(server.adds == [["a1", "a3"], ["a1", "p5"]])
    }

    @Test func theMessageSaysWhatWasSkipped() {
        #expect(BatchAddResult(added: 12, skipped: 0).message(playlist: "Mix") == "Added 12 songs to Mix")
        #expect(BatchAddResult(added: 1, skipped: 0).message(playlist: "Mix") == "Added 1 song to Mix")
        #expect(BatchAddResult(added: 9, skipped: 3).message(playlist: "Mix") == "Added 9 songs to Mix (3 already there)")
        #expect(BatchAddResult(added: 0, skipped: 12).message(playlist: "Mix") == "All 12 songs are already in Mix")
        #expect(BatchAddResult(added: 0, skipped: 1).message(playlist: "Mix") == "That song is already in Mix")
        #expect(BatchAddResult(added: 0, skipped: 0).message(playlist: "Mix") == "No songs to add")
    }
}

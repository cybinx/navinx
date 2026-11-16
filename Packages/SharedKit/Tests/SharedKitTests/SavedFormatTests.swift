import Foundation
import Testing
@testable import SharedKit

/// C43, step 0 (D157): `Widgets/snapshot.json`, frozen as a golden sample written by the build before
/// C43's renames. The app and the widgets read each other's file, so its keys must never move. It
/// must pass unchanged before and after every rename; never edit it to make the test pass.
struct SavedFormatTests {
    static var snapshot: WidgetSnapshot {
        WidgetSnapshot(
            signedIn: true,
            nowPlaying: WidgetSong(id: "s1", title: "One", artist: "A", album: "First", cover: "cover-c1.jpg", isPlaying: true),
            latestAlbums: [WidgetItem(id: "al1", name: "First", subtitle: "A", cover: "cover-c1.jpg")],
            playlists: [WidgetItem(id: "p1", name: "Mix")]
        )
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test func widgetSnapshot() throws {
        let golden = #"{"nowPlaying":{"album":"First","artist":"A","cover":"cover-c1.jpg","id":"s1","isPlaying":true,"title":"One"},"playlists":[{"id":"p1","name":"Mix"}],"recentAlbums":[{"cover":"cover-c1.jpg","id":"al1","name":"First","subtitle":"A"}],"signedIn":true}"#
        #expect(try Self.json(Self.snapshot) == golden)
        #expect(try JSONDecoder().decode(WidgetSnapshot.self, from: Data(golden.utf8)) == Self.snapshot)
    }

}

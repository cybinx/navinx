import Foundation
import SubsonicKit
import Testing
@testable import PlaybackKit

/// C43, step 0 (D157): what the player saves, frozen as golden samples written by the build before
/// C43's renames: the queue file, the scrobbles still to send, the server queue's mark, and the
/// settings saved by raw value. They must pass unchanged before and after every rename; never edit
/// one to make a test pass.
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

    static var scrobbles: [PlayerStore.PendingScrobble] {
        [PlayerStore.PendingScrobble(songID: "s1", submission: true, time: date)]
    }

    static var savedQueue: PlayerStore.SavedQueue {
        PlayerStore.SavedQueue(
            profileID: "6F0C2B2E-8F4A-4C61-9D35-1A7E2C9B5D10",
            queue: PlayQueue.Saved(
                songs: [Song(id: "s1", title: "One"), Song(id: "s2", title: "Two")],
                originalOrder: [1, 0],
                currentIndex: 1,
                currentSongID: "s2",
                autoplayStart: 1
            ),
            position: 42.5,
            isPlaceholder: false
        )
    }

    static var syncRecord: QueueSyncRecord {
        QueueSyncRecord(mark: QueueSnapshot(songIDs: ["s1", "s2"], currentID: "s2", positionMs: 42_500), changedHereAt: date)
    }

    @Test func heldScrobbles() throws {
        let golden = #"[{"songID":"s1","submission":true,"time":800000000}]"#
        #expect(try Self.json(Self.scrobbles) == golden)
        #expect(try Self.read([PlayerStore.PendingScrobble].self, golden) == Self.scrobbles)
    }

    @Test func savedQueue() throws {
        let golden = #"{"isPlaceholder":false,"position":42.5,"profileID":"6F0C2B2E-8F4A-4C61-9D35-1A7E2C9B5D10","queue":{"autoplayStart":1,"currentIndex":1,"currentSongID":"s2","originalOrder":[1,0],"songs":[{"id":"s1","title":"One"},{"id":"s2","title":"Two"}]}}"#
        #expect(try Self.json(Self.savedQueue) == golden)
        #expect(try Self.json(Self.read(PlayerStore.SavedQueue.self, golden)) == golden)
    }

    @Test func queueSyncRecord() throws {
        let golden = #"{"changedHereAt":800000000,"mark":{"currentID":"s2","positionMs":42500,"songsHash":"fba0dc09718b76ca-2"}}"#
        #expect(try Self.json(Self.syncRecord) == golden)
        #expect(try Self.read(QueueSyncRecord.self, golden) == Self.syncRecord)
    }

    /// `auto_dj_mode` and `auto_dj_last_mode` hold these strings.
    @Test func refillSourceRawValues() {
        #expect(RefillSource.allCases.map(\.rawValue) == ["off", "shuffleLibrary", "similarSongs", "sameGenre", "sameArtist", "smartMix"])
    }

    @Test func numberedSettings() {
        #expect(RepeatMode.allCases.map(\.rawValue) == [0, 1, 2])
        #expect(ReplayGainSettings.Mode.allCases.map(\.rawValue) == [0, 1, 2])
    }

}

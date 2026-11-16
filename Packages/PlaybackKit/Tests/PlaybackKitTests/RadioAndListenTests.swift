import Foundation
import Testing
import SubsonicKit
@testable import PlaybackKit

@MainActor
@Suite struct RadioTests {
    @Test func aSongWithRadioIsFollowedBySimilarSongs() async throws {
        let rig = try Rig()
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["b", "c"])
        rig.player.playAsStation(song("a"))
        #expect(rig.player.currentSong?.id == "a")
        #expect(rig.player.queueIsStation)
        #expect(await eventually { rig.player.queue.map(\.id) == ["a", "b", "c"] })
        #expect(rig.engine.nextSongID == "b")
    }

    @Test func songsAlreadyQueuedAreNotAddedTwice() async throws {
        let rig = try Rig()
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["a", "b", "b"])
        rig.player.playAsStation(song("a"))
        #expect(await eventually { rig.player.queue.count > 1 })
        #expect(rig.player.queue.map(\.id).filter { $0 == "a" }.count == 1)
    }

    @Test func noSimilarSongsFallsBackToRandomSongs() async throws {
        let rig = try Rig()
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: [])
        rig.server.stubSongs("getSimilarSongs", key: "similarSongs", ids: [])
        rig.server.stubSongs("getRandomSongs", key: "randomSongs", ids: ["z"])
        rig.player.playAsStation(song("a"))
        #expect(await eventually { rig.player.queue.map(\.id) == ["a", "z"] })
    }

    @Test func itRefillsWithThreeSongsOrFewerLeft() async throws {
        let rig = try Rig()
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["b", "c", "d", "e", "f"])
        rig.player.playAsStation(song("a"))
        #expect(await eventually { rig.player.queue.count == 6 })
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["g"])
        // Five left, then four: nothing yet.
        rig.player.skipNext()
        #expect(rig.server.calls(to: "getSimilarSongs2").count == 1)
        rig.player.skipNext()
        rig.player.skipNext()
        #expect(await eventually { rig.player.queue.last?.id == "g" })
        #expect(rig.server.calls(to: "getSimilarSongs2").last?.songID == "f")
    }

    @Test func radioCarriesOnPastTheEndWhenMoreArrive() async throws {
        let rig = try Rig()
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: [])
        rig.server.stubSongs("getSimilarSongs", key: "similarSongs", ids: [])
        rig.server.stubSongs("getRandomSongs", key: "randomSongs", ids: [])
        rig.player.playAsStation(song("a"))
        #expect(await eventually { rig.server.calls(to: "getRandomSongs").count >= 1 })
        try await Task.sleep(for: .milliseconds(50))
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["b"])
        rig.engine.send(.ended)
        #expect(await eventually { rig.player.currentSong?.id == "b" && rig.player.isPlaying })
    }

    /// Two Nexts at the end while the refill is on its way: one song on, not two.
    @Test func nextTwiceWhileTheRefillWaitsMovesOnOnce() async throws {
        let rig = try Rig()
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["b", "c"])
        rig.server.hold("getSimilarSongs2")
        rig.player.playAsStation(song("a"))
        #expect(await eventually { rig.server.waitingCount == 1 })
        rig.player.skipNext()
        rig.player.skipNext()
        rig.server.release()
        #expect(await eventually { rig.player.currentSong?.id == "b" })
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.player.currentSong?.id == "b" && rig.player.isPlaying)
        // The refill that "b" starts is let go too.
        let refilling = await eventually { rig.server.waitingCount == 1 }
        if refilling { rig.server.release() }
    }

    /// Re-check item 20 (2026-11-15): Next on radio's last song kept it playing while more were fetched.
    @Test func nextOnTheLastSongSilencesItWhileMoreAreFetched() async throws {
        let rig = try Rig()
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["b"])
        rig.server.hold("getSimilarSongs2")
        rig.player.playAsStation(song("a"))
        #expect(await eventually { rig.server.waitingCount == 1 })
        let stops = rig.engine.stops
        rig.player.skipNext()
        #expect(rig.engine.stops == stops + 1 && !rig.engine.hasItem && rig.player.isLoading)
        rig.server.release()
        #expect(await eventually { rig.player.currentSong?.id == "b" && rig.player.isPlaying })
        #expect(rig.engine.loadedSongIDs == ["a", "b"] && rig.engine.isPlaying)
        // The refill that "b" starts is let go too.
        let refilling = await eventually { rig.server.waitingCount == 1 }
        if refilling { rig.server.release() }
    }

    @Test func withNothingMoreToAddTheQueueEnds() async throws {
        let rig = try Rig()
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: [])
        rig.server.stubSongs("getSimilarSongs", key: "similarSongs", ids: [])
        rig.server.stubSongs("getRandomSongs", key: "randomSongs", ids: [])
        rig.player.playAsStation(song("a"))
        rig.engine.send(.ended)
        #expect(await eventually { !rig.player.isPlaying && !rig.player.isLoading })
        #expect(rig.player.currentSong?.id == "a")
    }

    // D34: Flutter's radio stayed on until the app restarted.

    @Test func anotherListEndsRadio() async throws {
        let rig = try Rig()
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["b"])
        rig.player.playAsStation(song("a"))
        #expect(await eventually { rig.player.queue.count == 2 })
        rig.player.playSong(song("x"), playlist: songs("x", "y"))
        #expect(!rig.player.queueIsStation)
        rig.player.skipNext()
        rig.player.skipNext()
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.player.queue.map(\.id) == ["x", "y"])
    }

    @Test func playAndShuffleEndRadio() throws {
        let rig = try Rig()
        rig.player.playAsStation(song("a"))
        rig.player.playInOrder(songs("x", "y"))
        #expect(!rig.player.queueIsStation)
        rig.player.playAsStation(song("a"))
        rig.player.playShuffled(songs("x", "y"))
        #expect(!rig.player.queueIsStation)
        rig.player.toggleShuffle(forceValue: false)
    }

    @Test func aFetchUnderWayIsDroppedWhenAListStarts() async throws {
        let rig = try Rig()
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["late"])
        rig.player.playAsStation(song("a"))
        rig.player.playInOrder(songs("x", "y"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.player.queue.map(\.id) == ["x", "y"])
    }

    @Test func clearingTheQueueEndsRadio() throws {
        let rig = try Rig()
        rig.player.playAsStation(song("a"))
        rig.player.clearQueue()
        #expect(!rig.player.queueIsStation)
    }
}

/// D33: what the recommendation engine hears.
@MainActor
@Suite struct ListenEventTests {
    private func listening(_ rig: Rig) -> EventLog {
        let log = EventLog()
        rig.player.onListen = { log.events.append($0) }
        return log
    }

    @MainActor
    final class EventLog {
        var events: [ListenEvent] = []
        var finishes: [ListenEnd] {
            events.compactMap { if case .finished(_, _, _, let end) = $0 { end } else { nil } }
        }
        var playedTimes: [TimeInterval] {
            events.compactMap { if case .finished(_, let played, _, _) = $0 { played } else { nil } }
        }
        var starts: [String] {
            events.compactMap { if case .started(let song) = $0 { song.id } else { nil } }
        }
    }

    @Test func aSongStartsOnceItMakesSound() throws {
        let rig = try Rig()
        let log = listening(rig)
        rig.player.playSong(song("a"))
        #expect(log.starts.isEmpty)
        rig.engine.startSounding()
        rig.player.pause()
        rig.player.play()
        #expect(log.starts == ["a"])
    }

    @Test func aSongEndingOnItsOwnSaysSo() throws {
        let rig = try Rig()
        let log = listening(rig)
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.engine.startSounding()
        rig.clock.advance(200)
        rig.engine.send(.advanced)
        #expect(log.finishes == [.ended])
        #expect(log.playedTimes == [200])
    }

    @Test func nextSaysNextByEitherRoute() throws {
        let rig = try Rig()
        let log = listening(rig)
        // Lined up, so the engine hands over.
        rig.player.playSong(song("a"), playlist: songs("a", "b", "c"))
        rig.engine.startSounding()
        rig.player.skipNext()
        #expect(rig.engine.advances == 1)
        #expect(log.finishes == [.next])
        // Not lined up: past the end, with repeat off.
        rig.player.skip(toIndex: 2)
        rig.player.skipNext()
        #expect(log.finishes == [.next, .replaced, .next])
    }

    @Test func aSongEndingAfterASkipSaysEnded() throws {
        let rig = try Rig()
        let log = listening(rig)
        rig.player.playSong(song("a"), playlist: songs("a", "b", "c"))
        rig.player.skipNext()
        rig.engine.send(.advanced)
        #expect(log.finishes == [.next, .ended])
    }

    /// A Next the engine had nothing lined up for (re-check item 20, 2026-11-15): it used to do
    /// nothing; the next song is started afresh, and its own end later still says ended.
    @Test func aNextTheEngineHadNothingForStartsTheNextSongAfresh() throws {
        let rig = try Rig()
        let log = listening(rig)
        rig.player.playSong(song("a"), playlist: songs("a", "b", "c"))
        rig.engine.advanceEvent = nil
        rig.player.skipNext()
        #expect(rig.player.currentSong?.id == "b" && rig.player.isPlaying)
        #expect(rig.engine.loadedSongIDs == ["a", "b"] && rig.engine.nextSongID == "c")
        #expect(log.finishes == [.next])
        rig.engine.advanceEvent = .advanced
        rig.engine.send(.advanced)
        #expect(log.finishes == [.next, .ended])
    }

    /// A Next that ends the song instead of handing over still says next, and plays on.
    @Test func aNextThatEndsTheSongSaysNext() throws {
        let rig = try Rig()
        let log = listening(rig)
        rig.player.playSong(song("a"), playlist: songs("a", "b", "c"))
        rig.engine.advanceEvent = .ended
        rig.player.skipNext()
        #expect(log.finishes == [.next])
        #expect(rig.player.currentSong?.id == "b" && rig.player.isPlaying)
        rig.engine.advanceEvent = .advanced
        rig.engine.send(.ended)
        #expect(log.finishes == [.next, .ended])
    }

    @Test func anotherListSaysReplaced() throws {
        let rig = try Rig()
        let log = listening(rig)
        rig.player.playSong(song("a"))
        rig.player.playInOrder(songs("x"))
        #expect(log.finishes == [.replaced])
    }

    @Test func pausedTimeIsNotCounted() throws {
        let rig = try Rig()
        let log = listening(rig)
        rig.player.playSong(song("a"))
        rig.engine.startSounding()
        rig.clock.advance(10)
        rig.player.pause()
        rig.clock.advance(100)
        rig.player.playInOrder(songs("x"))
        #expect(log.playedTimes == [10])
    }

    /// Play after a failure loads the song again, its play count carrying on: no second start, and
    /// the time before the failure counts.
    @Test func aSongResumedAfterAFailureKeepsItsListen() async throws {
        let rig = try Rig()
        let log = listening(rig)
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.engine.startSounding()
        rig.clock.advance(60)
        rig.engine.send(.failed("No"))
        rig.player.play()
        rig.engine.startSounding()
        rig.clock.advance(50)
        rig.engine.send(.advanced)
        #expect(log.starts == ["a", "b"])
        #expect(log.playedTimes == [110])
        #expect(await eventually { rig.server.scrobbles.contains("a:true") })
        #expect(rig.server.scrobbles.filter { $0 == "a:false" }.count == 1)
    }

    @Test func favouritesAndRatingsAreHeardOnlyOnceTheServerTakesThem() async throws {
        let rig = try Rig()
        let log = listening(rig)
        rig.player.playSong(song("a"))
        await rig.player.toggleFavorite()
        try await rig.player.setRating(songID: "a", rating: 4)
        #expect(log.events.contains(.starred(song("a"), true)))
        #expect(log.events.contains { if case .rated(_, 4) = $0 { true } else { false } })

        let failing = try Rig()
        let failedLog = listening(failing)
        failing.server.setFailing(true)
        failing.player.playSong(song("a"))
        await failing.player.toggleFavorite()
        #expect(!failedLog.events.contains { if case .starred = $0 { true } else { false } })
    }
}

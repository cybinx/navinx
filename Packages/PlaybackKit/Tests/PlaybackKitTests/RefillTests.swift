import Foundation
import Testing
import SubsonicKit
@testable import PlaybackKit

/// C21, D90: Auto DJ adds songs, under "Autoplay", when two or fewer are left after the current one.
@MainActor
@Suite struct RefillTests {
    private func rig(_ mode: RefillSource, refillCount: Int = 5) throws -> Rig {
        let rig = try Rig()
        rig.defaults.set(refillCount, forKey: RefillSettings.refillCountKey)
        rig.player.setRefillSource(mode)
        return rig
    }

    private func many(_ prefix: String, _ count: Int) -> [String] {
        (1...count).map { "\(prefix)\($0)" }
    }

    // MARK: The modes

    @Test func fromLibraryAsksForTwiceTheCountAndAddsTheCount() async throws {
        let rig = try rig(.fromLibrary)
        rig.server.stubSongs("getRandomSongs", key: "randomSongs", ids: many("r", 10))
        rig.player.playInOrder(songs("a"))
        #expect(await eventually { rig.player.queue.count == 6 })
        #expect(rig.server.calls(to: "getRandomSongs").contains { $0.params["size"] == "10" })
        #expect(rig.player.playQueue.autoplayStart == 1)
        #expect(rig.engine.nextSongID == rig.player.queue[1].id)
    }

    @Test func fromSimilarAsksForTheCurrentSong() async throws {
        let rig = try rig(.fromSimilar, refillCount: 2)
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["s1", "s2", "s3", "s4"])
        rig.player.playInOrder(songs("a", "b"))
        #expect(await eventually { rig.player.queue.count == 4 })
        let call = try #require(rig.server.calls(to: "getSimilarSongs2").first)
        #expect(call.songID == "a")
        #expect(call.params["count"] == "4")
        #expect(Set(rig.player.queue[2...].map(\.id)).isSubset(of: ["s1", "s2", "s3", "s4"]))
    }

    @Test func fromSimilarWithNothingFallsToTheGenre() async throws {
        let rig = try rig(.fromSimilar, refillCount: 1)
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: [])
        rig.server.stubSongs("getSimilarSongs", key: "similarSongs", ids: [])
        rig.server.stubSongs("getRandomSongs", key: "randomSongs", ids: ["g"])
        rig.player.playInOrder([Song(id: "a", title: "A", genre: "Rock", duration: 200)])
        #expect(await eventually { rig.player.queue.map(\.id) == ["a", "g"] })
        #expect(rig.server.calls(to: "getRandomSongs").contains { $0.params["genre"] == "Rock" })
    }

    /// Flutter's `getSongsByGenre` always gave the genre's first songs.
    @Test func fromGenreTakesRandomSongsOfTheGenre() async throws {
        let rig = try rig(.fromGenre)
        rig.server.stubSongs("getRandomSongs", key: "randomSongs", ids: many("g", 10))
        rig.player.playInOrder([Song(id: "a", title: "A", genre: "Jazz", duration: 200)])
        #expect(await eventually { rig.player.queue.count == 6 })
        #expect(rig.server.calls(to: "getRandomSongs").contains { $0.params["genre"] == "Jazz" && $0.params["size"] == "10" })
        #expect(rig.server.calls(to: "getSongsByGenre").isEmpty)
    }

    @Test func fromArtistTakesTheArtistsTopSongs() async throws {
        let rig = try rig(.fromArtist)
        rig.server.stubPayload("getArtist", #","artist":{"id":"ar","name":"Cochise","album":[]}"#)
        rig.server.stubSongs("getTopSongs", key: "topSongs", ids: ["t1", "t2"])
        rig.player.playInOrder([Song(id: "a", title: "A", artist: "Cochise", artistID: "ar", duration: 200)])
        #expect(await eventually { rig.player.queue.count == 3 })
        #expect(rig.server.calls(to: "getTopSongs").first?.params["artist"] == "Cochise")
    }

    /// No tempo: similar songs, the song's genre, the listener's favourite genres and random ones.
    @Test func fromBlendPoolsItsSources() async throws {
        let rig = try rig(.fromBlend, refillCount: 10)
        rig.player.favouriteGenres = { _ in ["Soul", "Funk"] }
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["s1", "s2"])
        rig.server.stubSongs("getRandomSongs", key: "randomSongs", ids: ["r1", "r2"])
        rig.player.playInOrder([Song(id: "a", title: "A", genre: "Rock", duration: 200)])
        #expect(await eventually { rig.player.queue.count == 5 })
        #expect(Set(rig.player.queue.map(\.id)) == ["a", "s1", "s2", "r1", "r2"])
        let genres = Set(rig.server.calls(to: "getRandomSongs").compactMap { $0.params["genre"] })
        #expect(genres == ["Rock", "Soul", "Funk"])
        #expect(rig.server.calls(to: "getSimilarSongs2").first?.params["count"] == "4")
    }

    // MARK: When

    @Test func itAddsOnceWithTwoLeft() async throws {
        let rig = try rig(.fromSimilar)
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: many("s", 10))
        rig.player.playInOrder(songs("a", "b", "c", "d"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.server.calls(to: "getSimilarSongs2").isEmpty)
        rig.player.skipNext()
        rig.player.skipNext()
        #expect(await eventually { rig.player.queue.count == 9 })
        rig.player.skipNext()
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.server.calls(to: "getSimilarSongs2").map(\.songID) == ["b"])
    }

    @Test func atTheEndItWaitsThenPlaysWhatCame() async throws {
        let rig = try rig(.fromSimilar)
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: [])
        rig.server.stubSongs("getSimilarSongs", key: "similarSongs", ids: [])
        rig.server.stubSongs("getRandomSongs", key: "randomSongs", ids: [])
        rig.player.playInOrder(songs("a"))
        #expect(await eventually { rig.server.calls(to: "getRandomSongs").contains { $0.params["size"] == "10" } })
        try await Task.sleep(for: .milliseconds(50))
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["b"])
        rig.engine.send(.ended)
        #expect(await eventually { rig.player.currentSong?.id == "b" && rig.player.isPlaying })
    }

    @Test func atTheEndWithNothingTheQueueEnds() async throws {
        let rig = try rig(.fromLibrary)
        rig.server.stubSongs("getRandomSongs", key: "randomSongs", ids: [])
        rig.player.playInOrder(songs("a", "b"))
        rig.player.skipNext()
        rig.engine.send(.ended)
        #expect(await eventually { !rig.player.isPlaying && !rig.player.isLoading })
        #expect(rig.player.currentSong?.id == "a")
        #expect(rig.player.queue.map(\.id) == ["a", "b"])
    }

    /// Plays "a" with Auto DJ's fetch held, so the queue's end has to wait for it.
    private func waitingAtTheEnd() async throws -> Rig {
        let rig = try rig(.fromSimilar)
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["b"])
        rig.server.hold("getSimilarSongs2")
        rig.player.playInOrder(songs("a"))
        #expect(await eventually { rig.server.waitingCount == 1 })
        return rig
    }

    /// The fetch that "b" starts is let go too.
    private func releaseTheNextFetch(_ rig: Rig) async {
        let isWaiting = await eventually { rig.server.waitingCount == 1 }
        if isWaiting { rig.server.release() }
    }

    @Test func aPauseWhileTheEndWaitsHolds() async throws {
        let rig = try await waitingAtTheEnd()
        rig.player.skipNext()
        rig.player.pause()
        rig.server.release()
        #expect(await eventually { rig.player.currentSong?.id == "b" })
        #expect(!rig.player.isPlaying && !rig.engine.isPlaying && !rig.player.isLoading)
        await releaseTheNextFetch(rig)
    }

    @Test func stopCallsTheWaitOff() async throws {
        let rig = try await waitingAtTheEnd()
        rig.player.skipNext()
        rig.player.stop()
        rig.server.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.player.currentSong?.id == "a" && !rig.player.isPlaying && !rig.player.isLoading)
        #expect(rig.engine.loadedSongIDs == ["a"])
    }

    /// Play once the last song has ended doesn't play its end again: what comes plays.
    @Test func playWhileTheEndWaitsPlaysWhatComes() async throws {
        let rig = try await waitingAtTheEnd()
        rig.engine.send(.playing(false))
        rig.engine.hasItem = false
        rig.engine.send(.ended)
        rig.player.play()
        #expect(rig.engine.loadedSongIDs == ["a"] && rig.player.isPlaying)
        rig.server.release()
        #expect(await eventually { rig.player.currentSong?.id == "b" && rig.engine.isPlaying })
        #expect(rig.engine.loadedSongIDs == ["a", "b"])
        await releaseTheNextFetch(rig)
    }

    /// The playing song tapped again on its own list carries on, though Auto DJ has added to it.
    @Test func thePlayingSongTappedOnItsListCarriesOn() async throws {
        let rig = try rig(.fromSimilar)
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["s1"])
        rig.player.playSong(song("b"), playlist: songs("a", "b"), startIndex: 1)
        #expect(await eventually { rig.player.queue.count == 3 })
        rig.player.playSong(song("b"), playlist: songs("a", "b"))
        #expect(rig.engine.loaded.count == 1)
        #expect(rig.player.queue.map(\.id) == ["a", "b", "s1"])
    }

    @Test func offAddsNothing() async throws {
        let rig = try Rig()
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["s"])
        rig.player.playInOrder(songs("a"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.player.queue.map(\.id) == ["a"])
        #expect(rig.server.calls(to: "getSimilarSongs2").isEmpty)
    }

    /// Apple Music turns Autoplay off with repeat; Flutter kept adding, so the queue never repeated.
    @Test func repeatHoldsItBack() async throws {
        let rig = try rig(.fromSimilar)
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["s"])
        rig.player.changeRepeat(.all)
        rig.player.playInOrder(songs("a"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.server.calls(to: "getSimilarSongs2").isEmpty)
        rig.player.changeRepeat(.off)
        #expect(await eventually { rig.player.queue.map(\.id) == ["a", "s"] })
    }

    /// D81: the song kept after Clear Queue isn't a list to carry on.
    @Test func thePlaceholderGetsNothing() async throws {
        let rig = try rig(.fromSimilar)
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["s"])
        rig.player.playInOrder(songs("a", "b", "c", "d", "e"))
        rig.player.clearQueue()
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.player.queue.map(\.id) == ["a"])
        #expect(rig.server.calls(to: "getSimilarSongs2").isEmpty)
    }

    @Test func offlineAddsNothing() async throws {
        let rig = try Rig(connects: false)
        rig.player.connectOffline(profileID: "profile")
        rig.player.localFile = { URL(filePath: "/tmp/\($0.id).mp3") }
        rig.player.setRefillSource(.fromLibrary)
        rig.player.playInOrder(songs("a"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.player.queue.map(\.id) == ["a"])
        #expect(rig.server.requests.isEmpty)
    }

    @Test func aRadioQueueKeepsItsOwnRefill() async throws {
        let rig = try rig(.fromLibrary)
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["b", "c"])
        rig.player.playAsStation(song("a"))
        #expect(await eventually { rig.player.queue.map(\.id) == ["a", "b", "c"] })
        #expect(rig.player.playQueue.autoplayStart == 3)
        #expect(!rig.server.calls(to: "getRandomSongs").contains { $0.params["size"] == "10" })
    }

    @Test func aNewListDropsAFetchUnderWay() async throws {
        let rig = try rig(.fromSimilar)
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["late"])
        rig.player.playInOrder(songs("a"))
        rig.player.playInOrder(songs("x", "y", "z", "w"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.player.queue.map(\.id) == ["x", "y", "z", "w"])
    }

    // MARK: Which songs

    @Test func songsAlreadyComingAreLeftOut() async throws {
        let rig = try rig(.fromSimilar)
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["a", "b", "c", "c"])
        rig.player.playInOrder(songs("a", "b"))
        #expect(await eventually { rig.player.queue.count == 3 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.player.queue.map(\.id) == ["a", "b", "c"])
    }

    /// Flutter ran dry on a small library: with nothing new, anything but the current song.
    @Test func withNothingNewItStillAddsSomething() async throws {
        let rig = try rig(.fromSimilar)
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["a", "b"])
        rig.server.stubSongs("getRandomSongs", key: "randomSongs", ids: ["a"])
        rig.player.playInOrder(songs("a", "b"))
        #expect(await eventually { rig.player.queue.count == 3 })
        #expect(rig.player.queue.map(\.id) == ["a", "b", "b"])
    }

    @Test func pickShufflesDedupesAndLimits() {
        let picked = PlayerModel.pick(songs("a", "b", "b", "c", "d", "e"), count: 3, excluding: ["a"])
        #expect(picked.count == 3)
        #expect(Set(picked.map(\.id)).count == 3)
        #expect(!picked.contains { $0.id == "a" })
    }

    // MARK: The Autoplay group

    @Test func queueUpGoesBeforeAutoplaySongs() async throws {
        let rig = try rig(.fromSimilar, refillCount: 2)
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["x", "y"])
        rig.player.playInOrder(songs("a"))
        #expect(await eventually { rig.player.queue.count == 3 })
        rig.player.queueUp(song("mine"))
        #expect(rig.player.queue[1].id == "mine")
        #expect(rig.player.playQueue.autoplayStart == 2)
        #expect(rig.engine.nextSongID == "mine")
    }

    @Test func turningItOffTakesOutTheUnplayedOnes() async throws {
        let rig = try rig(.fromSimilar, refillCount: 2)
        rig.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["x", "y"])
        rig.player.playInOrder(songs("a"))
        #expect(await eventually { rig.player.queue.count == 3 })
        rig.player.skipNext()
        let reached = try #require(rig.player.currentSong?.id)
        rig.player.setRefillSource(.off)
        #expect(rig.player.queue.map(\.id) == ["a", reached])
        #expect(rig.engine.nextSongID == nil)
    }

    @Test func theButtonBringsBackTheLastMode() throws {
        let rig = try Rig()
        rig.player.toggleRefill()
        #expect(rig.player.refillSource == .fromSimilar)
        rig.player.setRefillSource(.fromArtist)
        rig.player.toggleRefill()
        #expect(rig.player.refillSource == .off)
        rig.player.toggleRefill()
        #expect(rig.player.refillSource == .fromArtist)
        #expect(RefillSettings(defaults: rig.defaults).mode == .fromArtist)
    }

    @Test func autoplaySongsAreSavedAsSuch() async throws {
        let first = try rig(.fromSimilar, refillCount: 2)
        first.server.stubSongs("getSimilarSongs2", key: "similarSongs2", ids: ["x", "y"])
        first.player.playInOrder(songs("a", "b"))
        #expect(await eventually { first.player.queue.count == 4 })
        first.player.saveNow()
        try await Task.sleep(for: .milliseconds(100))
        let second = try Rig(defaults: first.defaults, queueFile: first.queueFile)
        #expect(second.player.queue.count == 4)
        #expect(second.player.playQueue.autoplayStart == 2)
        #expect(second.player.refillSource == .fromSimilar)
    }
}

/// The Autoplay group in the queue itself.
@Suite struct AutoplayQueueTests {
    private func queue() -> PlayQueue {
        var queue = PlayQueue()
        queue.load(songs("a", "b"))
        queue.appendAutoplay(songs("x", "y"))
        return queue
    }

    @Test func shuffleKeepsAutoplayLast() {
        var queue = queue()
        queue.append(songs("c", "d", "e"))
        queue.setShuffle(true)
        #expect(queue.songs.suffix(2).map(\.id) == ["x", "y"])
        #expect(queue.autoplayStart == 5)
        queue.setShuffle(false)
        #expect(queue.songs.map(\.id) == ["a", "b", "c", "d", "e", "x", "y"])
        #expect(queue.autoplayStart == 5)
    }

    /// The review's case: the Autoplay group reordered while shuffled, then a song added, then
    /// shuffle off. The user's song must come before Auto DJ's in the order that comes back.
    @Test func aSongAddedAfterReorderingTheGroupWhileShuffledStaysBeforeIt() throws {
        var queue = queue()
        queue.setShuffle(true)
        let y = try #require(queue.songs.firstIndex { $0.id == "y" })
        let x = try #require(queue.songs.firstIndex { $0.id == "x" })
        queue.reorder(from: max(x, y), to: min(x, y))
        queue.append(songs("z"))
        queue.setShuffle(false)
        #expect(queue.songs.prefix(3).map(\.id).sorted() == ["a", "b", "z"])
        #expect(queue.autoplayStart == 3)
        #expect(Set(queue.songs.suffix(2).map(\.id)) == ["x", "y"])
    }

    @Test func aReachedSongIsNoLongerAutoplay() {
        var queue = queue()
        queue.move(to: 2)
        #expect(queue.autoplayStart == 3)
        queue.append(songs("mine"))
        #expect(queue.songs.map(\.id) == ["a", "b", "x", "mine", "y"])
        queue.move(to: 0)
        #expect(queue.autoplayStart == 4)
    }

    @Test func oneMovedAmongTheUsersSongsBecomesTheirs() {
        var queue = queue()
        queue.reorder(from: 3, to: 1)
        #expect(queue.songs.map(\.id) == ["a", "y", "b", "x"])
        #expect(queue.autoplayStart == 3)
    }

    @Test func oldSavesHaveNoAutoplay() throws {
        let json = #"{"songs":[{"id":"a","title":"A"}],"currentIndex":0}"#
        let saved = try JSONDecoder().decode(PlayQueue.Saved.self, from: Data(json.utf8))
        #expect(PlayQueue(saved: saved, isShuffled: false).autoplayStart == 1)
    }
}

import Foundation
import PlaybackKit
import SubsonicKit
import Testing
@testable import Navinx

private func song(_ id: String, artist: String? = nil, genre: String? = nil, album: String? = nil, duration: Int? = 200, starred: Bool = false) -> Song {
    var song = Song(id: id, title: "Song \(id)", albumID: album, artist: artist, genre: genre, duration: duration)
    song.starred = starred
    return song
}

/// Listens to a song right through.
private func finished(_ song: Song, seconds: TimeInterval = 200) -> ListenEvent {
    .finished(song, played: seconds, duration: 200, end: .ended)
}

@Suite struct RecommendationLearningTests {
    // D33: what counts.

    @Test func startingOnlyPutsItFirstInReplayPicks() {
        var data = RecommendationData()
        data.record(.started(song("a")))
        #expect(data.recentlyPlayed == ["a"])
        #expect(data.profiles["a"] == nil)
        #expect(data.artistPull.isEmpty)
    }

    @Test func playingToTheEndCountsOnceAsCompleted() {
        var data = RecommendationData()
        let a = song("a", artist: "A", genre: "Rock", album: "X")
        data.record(.started(a))
        data.record(finished(a), hour: 9)
        #expect(data.profiles["a"]?.playCount == 1)
        #expect(data.profiles["a"]?.completedPlays == 1)
        #expect(data.profiles["a"]?.timeListened == 200)
        #expect(data.profiles["a"]?.hourlyPlays == [9: 1])
        #expect(data.artistPull["A"] == 1.5)
        #expect(data.genrePull["Rock"] == 1.5 * 0.75)
        #expect(data.albumPull["X"] == 1.5 * 0.6)
        #expect(data.timePatterns[9]?["Rock"] == 1)
    }

    @Test func nextBefore80PercentIsASkipAndLowersTheArtist() {
        var data = RecommendationData()
        let a = song("a", artist: "A", genre: "Rock")
        data.record(.finished(a, played: 20, duration: 200, end: .next))
        #expect(data.skipCounts["a"] == 1)
        #expect(data.profiles["a"] == nil)
        // Flutter's skip penalty: 0.3, less the part already heard.
        #expect(abs((data.artistPull["A"] ?? 0) + 0.27) < 0.0001)
        #expect(abs((data.genrePull["Rock"] ?? 0) + 0.135) < 0.0001)
    }

    @Test func nextPast80PercentIsAFullListen() {
        var data = RecommendationData()
        let a = song("a", artist: "A")
        data.record(.finished(a, played: 170, duration: 200, end: .next))
        #expect(data.skipCounts["a"] == nil)
        #expect(data.profiles["a"]?.completedPlays == 1)
        #expect(data.artistPull["A"] == 1.5)
    }

    @Test func replacedPartWayCountsByHowMuchWasHeard() {
        var data = RecommendationData()
        let a = song("a", artist: "A")
        data.record(.finished(a, played: 100, duration: 200, end: .replaced))
        #expect(data.profiles["a"]?.playCount == 1)
        #expect(data.profiles["a"]?.completedPlays == 0)
        #expect(data.artistPull["A"] == 0.8)
        #expect(data.skipCounts["a"] == nil)
    }

    @Test func replacedBeforeAnySoundCountsForNothing() {
        var data = RecommendationData()
        data.record(.finished(song("a", artist: "A"), played: 0, duration: 200, end: .replaced))
        #expect(data.profiles.isEmpty)
        #expect(data.artistPull.isEmpty)
    }

    @Test func aFavouriteRaisesTheArtistAndTakingItBackLowersIt() {
        var data = RecommendationData()
        let a = song("a", artist: "A", genre: "Rock")
        data.record(.starred(a, true))
        #expect(data.starredSongs == ["a"])
        #expect(data.artistPull["A"] == 2)
        #expect(data.genrePull["Rock"] == 1.5)
        data.record(.starred(a, false))
        #expect(data.starredSongs.isEmpty)
        #expect(data.artistPull["A"] == 1)
    }

    @Test func aRatingPullsTheArtistUpOrDown() {
        var data = RecommendationData()
        data.record(.rated(song("a", artist: "A", genre: "Rock"), 5))
        data.record(.rated(song("b", artist: "B", genre: "Pop"), 1))
        data.record(.rated(song("c", artist: "C"), 9))
        #expect(data.profiles["a"]?.userRating == 5)
        #expect(data.artistRatingPull["A"] == 2.5)
        #expect(data.genreRatingPull["Rock"] == 1.8)
        #expect(data.artistRatingPull["B"] == -2.5)
        #expect(data.profiles["c"] == nil)
    }

    @Test func switchedOffItRemembersPlaysButNotTaste() {
        var data = RecommendationData()
        data.isEnabled = false
        data.record(finished(song("a", artist: "A")))
        #expect(data.profiles["a"]?.playCount == 1)
        #expect(data.artistPull.isEmpty)
    }

    @Test func recentsHoldAtMost500LatestFirstWithoutRepeats() {
        var data = RecommendationData()
        for index in 0..<510 { data.record(.started(song("\(index)"))) }
        data.record(.started(song("505")))
        #expect(data.recentlyPlayed.count == 500)
        #expect(data.recentlyPlayed.first == "505")
        #expect(data.recentlyPlayed.filter { $0 == "505" }.count == 1)
    }

    @Test func tasteHalvesEvery30Days() {
        var data = RecommendationData()
        data.record(finished(song("a", artist: "A")))
        let start = Date(timeIntervalSince1970: 1_000_000)
        data.applyDecay(at: start)
        let before = data.artistPull["A"] ?? 0
        data.applyDecay(at: start + 30 * 86_400)
        #expect(abs((data.artistPull["A"] ?? 0) - before / 2) < 0.0001)
        // Less than a day later: nothing changes.
        let after = data.artistPull["A"]
        data.applyDecay(at: start + 30 * 86_400 + 3_600)
        #expect(data.artistPull["A"] == after)
    }

    @Test func aDateThatWasNeverSetOnlyStartsTheClock() {
        var data = RecommendationData()
        data.record(finished(song("a", artist: "A")))
        let learned = data.artistPull["A"]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // The 1970 epoch of new or cleared data is not a gap to decay over.
        data.applyDecay(at: now)
        #expect(data.artistPull["A"] == learned)
        #expect(data.lastFadeDate == now)
        // Nor is an absurdly old date saved by an earlier version.
        var old = RecommendationData()
        old.record(finished(song("a", artist: "A")))
        old.applyDecay(at: now)
        old.applyDecay(at: now + 20_000 * 86_400)
        #expect(old.artistPull["A"] == learned)
        // A real gap still decays.
        old.applyDecay(at: now + 20_000 * 86_400 + 30 * 86_400)
        #expect(abs((old.artistPull["A"] ?? 0) - (learned ?? 0) / 2) < 0.0001)
    }

    @Test func itSurvivesBeingSaved() throws {
        var data = RecommendationData()
        data.record(finished(song("a", artist: "A", genre: "Rock")), hour: 9)
        data.record(.finished(song("b"), played: 1, duration: 200, end: .next))
        data.record(.starred(song("c"), true))
        var restored = try JSONDecoder().decode(RecommendationData.self, from: JSONEncoder().encode(data))
        // The switch is kept in settings, not the file.
        restored.isEnabled = data.isEnabled
        #expect(restored == data)
    }
}

@Suite struct RecommendationListTests {
    @Test func aNeverPlayedSongGetsTheNewnessBoost() {
        let data = RecommendationData()
        #expect(data.score(song("a"), hour: 9) == 0.08)
    }

    @Test func aFavouriteOutscoresAPlainSong() {
        let data = RecommendationData()
        #expect(data.score(song("a", starred: true), hour: 9) == 0.08 + 0.20)
    }

    @Test func aFavouriteArtistOutscoresOthers() {
        var data = RecommendationData()
        data.record(finished(song("played", artist: "A")))
        #expect(data.score(song("x", artist: "A"), hour: 9) > data.score(song("y", artist: "B"), hour: 9))
    }

    @Test func aSkippedSongScoresLowerThanItsTwin() {
        var data = RecommendationData()
        data.record(.finished(song("a"), played: 1, duration: 200, end: .next))
        #expect(data.score(song("a"), hour: 9) < data.score(song("b"), hour: 9))
    }

    @Test func aJustPlayedSongScoresLower() {
        var data = RecommendationData()
        data.record(.started(song("a", starred: true)))
        #expect(data.score(song("a", starred: true), hour: 9) < data.score(song("b", starred: true), hour: 9))
    }

    @Test func switchedOffEverythingScoresZero() {
        var data = RecommendationData()
        data.isEnabled = false
        #expect(data.score(song("a", starred: true), hour: 9) == 0)
    }

    @Test func replayPicksFollowTheRecentsAndKnownSongs() {
        var data = RecommendationData()
        data.record(.started(song("a")))
        data.record(.started(song("gone")))
        data.record(.started(song("b")))
        #expect(data.replayPicks([song("a"), song("b"), song("c")], limit: 10).map(\.id) == ["b", "a"])
        #expect(data.replayPicks([song("a"), song("b")], limit: 1).map(\.id) == ["b"])
    }

    @Test func heavyRotationWithNothingPlayedIsTheFirstSongs() {
        let songs = (0..<5).map { song("\($0)") }
        #expect(RecommendationData().heavyRotation(songs, limit: 2, hour: 9).map(\.id) == ["0", "1"])
    }

    @Test func heavyRotationRanksByPlaysThenFavourites() {
        var data = RecommendationData()
        let twice = song("twice")
        data.record(finished(twice))
        data.record(finished(twice))
        data.record(finished(song("once")))
        let list = [song("never"), song("once"), song("fav", starred: true), twice]
        #expect(data.heavyRotation(list, limit: 10, hour: 9).map(\.id) == ["twice", "once", "fav"])
    }

    @Test func theTailoredFeedPutsStrongSongsFirstDespiteTheNoise() {
        var data = RecommendationData()
        for _ in 0..<3 { data.record(.starred(song("seed", artist: "A"), true)) }
        let list = [song("weak", artist: "B"), song("strong", artist: "A", starred: true)]
        #expect(data.tailoredFeed(list, limit: 2, hour: 9).first?.id == "strong")
        #expect(data.tailoredFeed(list, limit: 1, hour: 9).count == 1)
    }

    @Test func switchedOffTheFeedIsTheLibraryInOrder() {
        var data = RecommendationData()
        data.isEnabled = false
        let list = [song("a"), song("b"), song("c")]
        #expect(data.tailoredFeed(list, limit: 2, hour: 9).map(\.id) == ["a", "b"])
    }

    @Test func discoverPrefersUnheardSongsInYourGenresByNewArtists() {
        var data = RecommendationData()
        data.record(finished(song("heard", artist: "A", genre: "Rock")))
        let list = [
            song("heard", artist: "A", genre: "Rock"),
            song("byTheSameArtist", artist: "A", genre: "Rock"),
            song("newArtist", artist: "B", genre: "Rock"),
            song("otherGenre", artist: "C", genre: "Pop"),
        ]
        #expect(data.explorerBlend(list, limit: 10, hour: 9).map(\.id) == ["newArtist"])
    }

    @Test func instantPicksLeaveOutWhatWasJustPlayed() {
        var data = RecommendationData()
        data.record(finished(song("just", artist: "A")))
        let list = [song("just", artist: "A"), song("other", artist: "A")]
        #expect(data.instantPicks(list, limit: 10, hour: 9).map(\.id) == ["other"])
    }

    @Test func mixesComeInFlutterOrderAndNeedFiveSongsOfAnArtist() {
        var data = RecommendationData()
        data.record(finished(song("seed", artist: "Big", genre: "Rock")), hour: 9)
        data.record(.finished(song("seed2", artist: "Small"), played: 100, duration: 200, end: .replaced), hour: 9)
        let list = (0..<6).map { song("big\($0)", artist: "Big", genre: "Rock") } + [song("small", artist: "Small")]
        let names = data.mixes(list, hour: 9).map(\.name)
        #expect(names == ["Quick Picks", "Discover Mix", "Big Mix", "Rock Mix", "Morning Vibes"])
    }

    @Test func noMixesWhenOffOrEmpty() {
        var data = RecommendationData()
        #expect(data.mixes([], hour: 9).isEmpty)
        data.isEnabled = false
        #expect(data.mixes([song("a")], hour: 9).isEmpty)
    }
}

@MainActor
@Suite struct RecommendationModelTests {
    private func makeFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "RecommendationTests-\(UUID().uuidString)/data.json")
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "RecommendationTests-\(UUID().uuidString)")!
    }

    @Test func whatItLearnsComesBackOnTheNextLaunch() async throws {
        let file = makeFile()
        let defaults = makeDefaults()
        let model = RecommendationModel(file: file, defaults: defaults)
        model.handle(finished(song("a", artist: "A")))
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: file.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let next = RecommendationModel(file: file, defaults: defaults)
        #expect(next.data.profiles["a"]?.playCount == 1)
    }

    @Test func theSwitchIsRememberedAndOnByDefault() {
        let defaults = makeDefaults()
        #expect(RecommendationModel(file: makeFile(), defaults: defaults).data.isEnabled)
        RecommendationModel(file: makeFile(), defaults: defaults).setEnabled(false)
        #expect(!RecommendationModel(file: makeFile(), defaults: defaults).data.isEnabled)
    }

    @Test func clearingForgetsEverythingButTheSwitch() {
        let model = RecommendationModel(file: makeFile(), defaults: makeDefaults())
        model.setEnabled(false)
        model.handle(finished(song("a")))
        model.clear()
        #expect(model.data.profiles.isEmpty)
        #expect(!model.data.isEnabled)
    }

    @Test func whatIsLearnedAfterAClearSurvivesTheNextLaunch() async throws {
        let file = makeFile()
        let defaults = makeDefaults()
        let model = RecommendationModel(file: file, defaults: defaults)
        model.handle(finished(song("old", artist: "Old")))
        model.clear()
        #expect(model.data.lastFadeDate.timeIntervalSince1970 > 1_000_000_000)
        model.handle(finished(song("a", artist: "A")))
        let learned = model.data.artistPull["A"]
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: file.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let next = RecommendationModel(file: file, defaults: defaults)
        #expect(learned != nil && next.data.artistPull["A"] == learned)
    }

    @Test func aSaveWaitingWhenClearedNeverWrites() async throws {
        let file = makeFile()
        let model = RecommendationModel(file: file, defaults: makeDefaults())
        model.handle(finished(song("a")))
        model.clear()
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aDamagedFileStartsAfresh() throws {
        let file = makeFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        #expect(RecommendationModel(file: file, defaults: makeDefaults()).data.profiles.isEmpty)
    }
}

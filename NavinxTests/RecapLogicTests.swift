import Foundation
import SubsonicKit
import Testing
@testable import Navinx

/// "Navinx Playback"'s numbers (C23, D92).
@Suite struct RecapLogicTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func song(
        _ id: String,
        plays: Int?,
        played: Date?,
        artist: String = "A",
        artistID: String? = nil,
        genre: String? = nil,
        duration: Int = 180
    ) -> Song {
        Song(
            id: id, title: "Song \(id)", artist: artist, artistID: artistID ?? "id-\(artist)", genre: genre,
            coverArt: "c\(id)", duration: duration, playCount: plays, played: played
        )
    }

    private func profile(hours: [Int: Int], lastPlayed: Date) -> ListeningRecord {
        var profile = ListeningRecord(song: Song(id: "p", title: "P"))
        profile.hourlyPlays = hours
        profile.lastPlayed = lastPlayed
        return profile
    }

    @Test func seasonAndYear() {
        #expect(!RecapSeason.isInSeason(day(2026, 11, 23), calendar: calendar))
        #expect(RecapSeason.isInSeason(day(2026, 11, 24), calendar: calendar))
        #expect(RecapSeason.isInSeason(day(2026, 12, 31), calendar: calendar))
        #expect(RecapSeason.isInSeason(day(2027, 1, 15), calendar: calendar))
        #expect(!RecapSeason.isInSeason(day(2027, 1, 16), calendar: calendar))
        #expect(RecapSeason.year(for: day(2027, 1, 10), calendar: calendar) == 2026)
        #expect(RecapSeason.year(for: day(2026, 11, 8), calendar: calendar) == 2026)
    }

    /// Home's banner (C54): in season and only with something to recap, by the story's own test.
    @Test func theBannerNeedsTheSeasonAndPlays() {
        let played = [song("a", plays: 3, played: day(2026, 6, 1))]
        let none = [song("never", plays: 0, played: day(2026, 6, 1)), song("old", plays: 9, played: day(2025, 6, 1))]
        #expect(RecapSeason.showsBanner(on: day(2026, 12, 1), songs: played, calendar: calendar))
        #expect(!RecapSeason.showsBanner(on: day(2026, 12, 1), songs: none, calendar: calendar))
        #expect(!RecapSeason.showsBanner(on: day(2026, 12, 1), songs: [], calendar: calendar))
        #expect(!RecapSeason.showsBanner(on: day(2026, 10, 1), songs: played, calendar: calendar))
        // January recaps last year: a song last played in the new year still counts.
        #expect(RecapSeason.showsBanner(on: day(2027, 1, 10), songs: [song("a", plays: 2, played: day(2027, 1, 2))], calendar: calendar))
        // The same answer as the story's: the banner never opens onto "Nothing to recap yet".
        for songs in [played, none, []] {
            let stats = RecapStats.make(songs: songs, profiles: [], year: 2026, calendar: calendar)
            #expect(RecapStats.hasPlays(songs, year: 2026, calendar: calendar) == !stats.isEmpty)
        }
    }

    @Test func ranksTheYearsSongsByPlays() {
        let songs = [
            song("old", plays: 99, played: day(2025, 12, 31, hour: 23)),
            song("a", plays: 5, played: day(2026, 3, 1)),
            song("b", plays: 9, played: day(2026, 2, 1)),
            song("tieLater", plays: 5, played: day(2026, 6, 1)),
            song("never", plays: 0, played: day(2026, 6, 1)),
            song("noDate", plays: 7, played: nil),
            song("a", plays: 5, played: day(2026, 3, 1)),
        ]
        let stats = RecapStats.make(songs: songs, profiles: [], year: 2026, calendar: calendar)
        #expect(stats.topSongs.map(\.song.id) == ["b", "tieLater", "a"])
        #expect(stats.totalPlays == 19)
        #expect(stats.uniqueTracks == 3)
        // Plays × length: 19 × 180 s.
        #expect(stats.seconds == 19 * 180 && stats.minutes == 57)
    }

    @Test func artistsAndGenres() {
        let songs = [
            song("1", plays: 10, played: day(2026, 5, 1), artist: "X", genre: "Rap"),
            song("2", plays: 4, played: day(2026, 5, 1), artist: "Y", genre: "Jazz"),
            song("3", plays: 3, played: day(2026, 5, 1), artist: "Y"),
            song("4", plays: 6, played: day(2026, 5, 1), artist: "Z", genre: "Jazz"),
        ]
        let stats = RecapStats.make(songs: songs, profiles: [], artistCovers: ["id-X": "ar-X"], year: 2026, calendar: calendar)
        #expect(stats.topArtists.map(\.name) == ["X", "Y", "Z"])
        #expect(stats.topArtists.map(\.plays) == [10, 7, 6])
        #expect(stats.topArtists.first?.coverArt == "ar-X")
        #expect(stats.artistCount == 3)
        // Only songs with a genre count, and nothing is made up.
        #expect(stats.genres.map(\.name) == ["Rap", "Jazz"])
        #expect(stats.genres.map(\.percent) == [50, 50])
        #expect(stats.genres.first?.color == 0xFA243C)
    }

    @Test func artistsRankByPlays() {
        let songs = [
            song("1", plays: 10, played: day(2026, 5, 1), artist: "X"),
            song("2", plays: 4, played: day(2026, 5, 1), artist: "Y"),
            song("3", plays: 8, played: day(2026, 5, 1), artist: "Y"),
        ]
        let stats = RecapStats.make(songs: songs, profiles: [], year: 2026, calendar: calendar)
        #expect(stats.topArtists.map(\.name) == ["Y", "X"])
        #expect(stats.topArtists.map(\.plays) == [12, 10])
    }

    @Test func chronotypeTies() {
        // Morning wins a tie, then afternoon, then evening; night only when it leads.
        #expect(RecapStats.Periods([8: 5, 13: 5, 19: 5, 23: 5]).chronotype == .sunrise)
        #expect(RecapStats.Periods([13: 5, 19: 5, 23: 5]).chronotype == .afternoon)
        #expect(RecapStats.Periods([19: 5, 2: 5]).chronotype == .twilight)
        #expect(RecapStats.Periods([2: 6, 19: 5]).chronotype == .midnight)
        // 22–6 is night, 6–12 morning, 12–18 afternoon, 18–22 evening.
        let edges = RecapStats.Periods([5: 1, 6: 2, 12: 3, 18: 4, 22: 5])
        #expect(edges.night == 6 && edges.morning == 2 && edges.afternoon == 3 && edges.evening == 4)
    }

    @Test func hoursNeedTenPlaysThisYear() {
        let songs = [song("1", plays: 2, played: day(2026, 5, 1))]
        let few = RecapStats.make(songs: songs, profiles: [profile(hours: [8: 9], lastPlayed: day(2026, 5, 1))], year: 2026, calendar: calendar)
        #expect(few.chronotype == nil)
        let lastYear = RecapStats.make(songs: songs, profiles: [profile(hours: [8: 20], lastPlayed: day(2025, 5, 1))], year: 2026, calendar: calendar)
        #expect(lastYear.chronotype == nil)
        let enough = RecapStats.make(songs: songs, profiles: [profile(hours: [8: 10], lastPlayed: day(2026, 5, 1))], year: 2026, calendar: calendar)
        #expect(enough.chronotype == .sunrise)
    }

    @Test func archetypeOrder() {
        let night = RecapStats.Periods([23: 10, 9: 2])
        let morning = RecapStats.Periods([8: 10, 14: 5, 23: 1])
        let day = RecapStats.Periods([14: 10, 8: 2])
        func archetype(artists: Int = 3, genres: Int = 1, seconds: Int = 1000, songs: Int = 10, top: Int = 5, _ periods: RecapStats.Periods?) -> RecapStats.Archetype? {
            RecapStats.archetype(artistCount: artists, genreCount: genres, seconds: seconds, songCount: songs, topArtistPlays: top, periods: periods)
        }
        #expect(archetype(artists: 21, genres: 4, top: 30, night) == .luminary)
        #expect(archetype(artists: 21, genres: 3, top: 26, nil) == .devotee)
        // Over three 3-minute listens a song.
        #expect(archetype(seconds: 10 * 181 * 3, songs: 10, nil) == .devotee)
        #expect(archetype(night) == .nightOwl)
        #expect(archetype(morning) == .sunrise)
        #expect(archetype(day) == .alchemist)
        // Without the hours the last three can't be told.
        #expect(archetype(nil) == nil)
    }

    @Test func slidesWithoutDataAreSkipped() {
        let bare = RecapStats.make(songs: [song("1", plays: 2, played: day(2026, 5, 1))], profiles: [], year: 2026, calendar: calendar)
        #expect(bare.slides == [.intro, .minutes, .topSongs, .topArtists, .summary])

        let full = RecapStats.make(
            songs: [song("1", plays: 30, played: day(2026, 5, 1), genre: "Rap")],
            profiles: [profile(hours: [8: 12], lastPlayed: day(2026, 5, 1))],
            year: 2026,
            calendar: calendar
        )
        #expect(full.slides == RecapStats.Slide.allCases)
        #expect(full.archetype == .devotee)
    }

    /// The review's case: in January the recap is last year's, and a 2026 favourite replayed on
    /// 3 Jan 2027 must still count (its `played` is 2027).
    @Test func januaryKeepsLastYearsSongsReplayedSinceNewYear() {
        let songs = [
            song("replayed", plays: 30, played: day(2027, 1, 3)),
            song("plain", plays: 4, played: day(2026, 8, 1)),
            song("older", plays: 50, played: day(2025, 12, 31)),
        ]
        let profiles = [profile(hours: [8: 12], lastPlayed: day(2027, 1, 3))]
        let stats = RecapStats.make(songs: songs, profiles: profiles, year: 2026, calendar: calendar)
        #expect(stats.topSongs.map(\.song.id) == ["replayed", "plain"])
        #expect(stats.totalPlays == 34)
        #expect(!RecapStats.make(songs: songs, profiles: [], year: 2026, calendar: calendar).isEmpty)
        #expect(stats.slides.count >= RecapStats.make(songs: songs, profiles: [], year: 2026, calendar: calendar).slides.count)
    }

    @Test func nothingPlayedIsEmptyNotMadeUp() {
        let stats = RecapStats.make(
            songs: [song("1", plays: 0, played: nil), song("2", plays: 4, played: day(2025, 2, 1))],
            profiles: [profile(hours: [3: 40], lastPlayed: day(2026, 5, 1))],
            year: 2026,
            calendar: calendar
        )
        #expect(stats.isEmpty && stats.slides.isEmpty)
        #expect(stats.minutes == 0 && stats.genres.isEmpty && stats.topArtists.isEmpty && stats.archetype == nil)
    }

    @Test func wording() {
        #expect(RecapStats.plays(1) == "1 play")
        #expect(RecapStats.plays(1234) == "1,234 plays")
        #expect(RecapStats.grouped(12345) == "12,345")
    }
}

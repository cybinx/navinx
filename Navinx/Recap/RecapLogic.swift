import Foundation
import SubsonicKit

/// When "Navinx Playback" is in season, and which year it recaps (Flutter `WrappedService`'s
/// `isWrappedSeason` and `getWrappedYear`).
nonisolated enum RecapSeason {
    /// 24 November to 15 January: Home's banner shows (D92). Settings → About opens it all year.
    static func isInSeason(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.month, .day], from: date)
        switch (parts.month ?? 0, parts.day ?? 0) {
        case (11, let day): return day >= 24
        case (12, _): return true
        case (1, let day): return day <= 15
        default: return false
        }
    }

    /// In January it's still last year's recap, as in Flutter.
    static func year(for date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.year, .month], from: date)
        let year = parts.year ?? 2026
        return parts.month == 1 ? year - 1 : year
    }

    /// Home's banner (C54): in season, and only when the recap has something to show, by the same
    /// test that decides between the story and "Nothing to recap yet" (`RecapStats.hasPlays`), so
    /// the banner never opens onto the empty state. Settings → About's row stays all year.
    static func showsBanner(on date: Date, songs: [Song], calendar: Calendar = .current) -> Bool {
        isInSeason(date, calendar: calendar)
            && RecapStats.hasPlays(songs, year: year(for: date, calendar: calendar), calendar: calendar)
    }

    /// Today. Debug builds can fake it for the UI tests (`-UITestDate yyyy-MM-dd`).
    static var today: Date {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-UITestDate"), index + 1 < arguments.count,
           let date = try? Date(arguments[index + 1], strategy: .iso8601.year().month().day()) {
            // Noon, so the time zone can't move it to another day.
            return date.addingTimeInterval(12 * 60 * 60)
        }
        #endif
        return .now
    }
}

/// The recap's numbers (Flutter `WrappedData`), from Navidrome's play counts and the phone's hours
/// (D92). Nothing is made up: a slide without data is left out, and no plays at all is the empty state.
nonisolated struct RecapStats: Equatable, Sendable {
    struct RankedSong: Equatable, Sendable {
        let song: Song
        let plays: Int
    }

    struct RankedArtist: Equatable, Sendable {
        /// Navidrome's artist ID, when the songs have one.
        let id: String?
        let name: String
        let plays: Int
        /// The artist's picture if the library has one, else the cover of their most played song.
        let coverArt: String?
    }

    struct GenreShare: Equatable, Sendable {
        let name: String
        let plays: Int
        /// Of the plays of songs with a genre, 0…1.
        let share: Double
        /// Flutter's palette, by rank.
        let color: UInt32

        var percent: Int { Int((share * 100).rounded()) }
    }

    /// Flutter's four chronotypes, by the hours the phone heard music.
    enum Chronotype: String, Equatable, Sendable {
        case sunrise, afternoon, twilight, midnight

        var name: String {
            switch self {
            case .midnight: "Midnight Wanderer 🌙"
            case .sunrise: "Sunrise Harmonizer ☀️"
            case .afternoon: "Afternoon Flow ⚡"
            case .twilight: "Twilight Lounger 🌆"
            }
        }

        var text: String {
            switch self {
            case .midnight: "Your deepest music moments unfold late at night when the world is quiet."
            case .sunrise: "You kickstart every morning with rhythm, setting the soundtrack for the entire day."
            case .afternoon: "Midday is your prime listening peak, powering through your momentum with high-energy sound."
            case .twilight: "Evenings are made for unwinding and losing yourself in immersive album journeys."
            }
        }
    }

    /// Flutter's five listening personalities.
    enum Archetype: String, Equatable, Sendable {
        case luminary, devotee, nightOwl, sunrise, alchemist

        var emoji: String {
            switch self {
            case .luminary: "✨"
            case .devotee: "💎"
            case .nightOwl: "🌙"
            case .sunrise: "☀️"
            case .alchemist: "🔮"
            }
        }

        var badge: String {
            switch self {
            case .luminary: "SONIC EXPLORER"
            case .devotee: "SUPERFAN"
            case .nightOwl: "NOCTURNAL VIBES"
            case .sunrise: "ENERGY CATALYST"
            case .alchemist: "VIBE CURATOR"
            }
        }

        var title: String {
            switch self {
            case .luminary: "The Luminary"
            case .devotee: "The Devotee"
            case .nightOwl: "The Night Owl"
            case .sunrise: "The Sunrise Harmonizer"
            case .alchemist: "The Sonic Alchemist"
            }
        }

        var text: String {
            switch self {
            case .luminary: "You shine light on diverse genres and constantly seek out fresh musical horizons."
            case .devotee: "When you love an artist or album, you listen on repeat with unmatched dedication."
            case .nightOwl: "Your soul belongs to midnight soundscapes, atmospheric chords, and starry listening sessions."
            case .sunrise: "You wake up the world with high vibrations and let optimistic melodies spark your day."
            case .alchemist: "You transmute everyday moments into cinematic experiences with perfectly curated soundtracks."
            }
        }

        var traits: [String] {
            switch self {
            case .luminary: ["Eclectic Taste", "Genre Fluid", "High Discovery"]
            case .devotee: ["Deep Loyalty", "Album Listener", "Emotional Bond"]
            case .nightOwl: ["Atmospheric", "Introspective", "Late-Night Flow"]
            case .sunrise: ["Uplifting", "Morning Energy", "Rhythmic Drive"]
            case .alchemist: ["Curator Instinct", "Cinematic Vibe", "Mood Master"]
            }
        }

        var colors: [UInt32] {
            switch self {
            case .luminary: [0xFF007A, 0x7928CA, 0x00DFD8]
            case .devotee: [0xFA243C, 0xFF8C00, 0xFFE600]
            case .nightOwl: [0x4A00E0, 0x8E2DE2, 0x00C6FF]
            case .sunrise: [0xFF512F, 0xDD2476, 0xFF9472]
            case .alchemist: [0x11998E, 0x38EF7D, 0x00C6FF]
            }
        }
    }

    /// Flutter's eight slides, in order.
    enum Slide: Int, CaseIterable, Equatable, Sendable {
        case intro, minutes, chronotype, genres, topSongs, topArtists, personality, summary

        /// The aura's two colours (Flutter's per-slide gradients).
        var colors: (UInt32, UInt32) {
            switch self {
            case .intro: (0xFA243C, 0x7928CA)
            case .minutes: (0x00C6FF, 0x0072FF)
            case .chronotype: (0xFF512F, 0xDD2476)
            case .genres: (0x8E2DE2, 0x4A00E0)
            case .topSongs: (0xFF0844, 0xFFB199)
            case .topArtists: (0x11998E, 0x38EF7D)
            case .personality: (0xFF007A, 0x7928CA)
            case .summary: (0xFA243C, 0xFF8C00)
            }
        }
    }

    static let genreSwatches: [UInt32] = [0xFA243C, 0x00C6FF, 0xFF8C00, 0x8E2DE2, 0x10B981]
    /// Below this many plays on the phone this year, the hours say nothing (D92: no Midnight Wanderer
    /// from nothing, Flutter's bug).
    static let minimumHourPlays = 10

    let year: Int
    /// Up to ten, most played first (the drumroll and the summary play them; five are shown).
    let topSongs: [RankedSong]
    let totalPlays: Int
    /// Σ plays × length: an estimate, since Navidrome keeps counts, not listening time (D92).
    let seconds: Int
    let uniqueTracks: Int
    let artistCount: Int
    let topArtists: [RankedArtist]
    let genres: [GenreShare]
    let chronotype: Chronotype?
    let archetype: Archetype?

    var minutes: Int { seconds / 60 }
    var hours: Double { Double(seconds) / 3600 }
    var isEmpty: Bool { topSongs.isEmpty }

    /// The slides with something to show; none when there's nothing to recap.
    var slides: [Slide] {
        guard !isEmpty else { return [] }
        return Slide.allCases.filter { slide in
            switch slide {
            case .chronotype: chronotype != nil
            case .genres: !genres.isEmpty
            case .topArtists: !topArtists.isEmpty
            case .personality: archetype != nil
            default: true
            }
        }
    }

    /// - Parameters:
    ///   - songs: the library as Navidrome sends it, with this user's `playCount` and `played`.
    ///   - profiles: the phone's own history (`RecommendationModel`), for the hours only.
    ///   - artistCovers: the library's artist pictures by artist ID.
    static func make(
        songs: [Song],
        profiles: [ListeningRecord],
        artistCovers: [String: String] = [:],
        year: Int,
        calendar: Calendar = .current
    ) -> RecapStats {
        let range = yearRange(year, calendar: calendar)

        // The year's songs: last played this year or since (Navidrome keeps no per-year counts, and its
        // counts are lifetime totals). "Or since" matters in January, when the recap is last year's
        // and a favourite replayed after New Year would otherwise drop out.
        var seen = Set<String>()
        let played = songs.filter { song in
            counts(song, from: range.lowerBound) && seen.insert(song.id).inserted
        }
        let ranked = played.sorted { a, b in
            if a.playCount != b.playCount { return (a.playCount ?? 0) > (b.playCount ?? 0) }
            if a.played != b.played { return (a.played ?? .distantPast) > (b.played ?? .distantPast) }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        let totalPlays = ranked.reduce(0) { $0 + ($1.playCount ?? 0) }
        let seconds = ranked.reduce(0) { $0 + ($1.playCount ?? 0) * ($1.duration ?? 0) }

        // Artists: the song's first credited artist, by ID when there is one.
        var artistPlays: [String: (id: String?, name: String, plays: Int, cover: String?)] = [:]
        var artistOrder: [String] = []
        for song in ranked {
            let ref = song.displayArtists.first
            let name = ref?.name ?? song.artist ?? "Unknown Artist"
            let id = ref?.id ?? song.artistID
            let key = id ?? "name:" + name.lowercased()
            if artistPlays[key] == nil {
                artistOrder.append(key)
                let picture = id.flatMap { artistCovers[$0] }
                artistPlays[key] = (id, name, 0, picture ?? song.coverArt)
            }
            artistPlays[key]?.plays += song.playCount ?? 0
        }
        let artists = artistOrder.compactMap { artistPlays[$0] }
            .enumerated()
            .sorted { $0.element.plays != $1.element.plays ? $0.element.plays > $1.element.plays : $0.offset < $1.offset }
            .map { RankedArtist(id: $0.element.id, name: $0.element.name, plays: $0.element.plays, coverArt: $0.element.cover) }

        // Genres: only songs that have one; no stand-in genres (Flutter's bug).
        var genrePlays: [String: Int] = [:]
        var genreOrder: [String] = []
        for song in ranked {
            guard let genre = song.genre?.trimmingCharacters(in: .whitespaces), !genre.isEmpty else { continue }
            if genrePlays[genre] == nil { genreOrder.append(genre) }
            genrePlays[genre, default: 0] += song.playCount ?? 0
        }
        let genreTotal = genrePlays.values.reduce(0, +)
        let sortedGenres = genreOrder.enumerated()
            .sorted { genrePlays[$0.element]! != genrePlays[$1.element]! ? genrePlays[$0.element]! > genrePlays[$1.element]! : $0.offset < $1.offset }
            .map(\.element)
        let genres = sortedGenres.prefix(5).enumerated().map { index, name in
            GenreShare(
                name: name,
                plays: genrePlays[name]!,
                share: genreTotal > 0 ? Double(genrePlays[name]!) / Double(genreTotal) : 0,
                color: genreSwatches[index % genreSwatches.count]
            )
        }

        // The hours: the phone's history, songs it heard this year (or since, as above).
        var hourly: [Int: Int] = [:]
        for profile in profiles where profile.lastPlayed >= range.lowerBound {
            for (hour, count) in profile.hourlyPlays { hourly[hour, default: 0] += count }
        }
        let periods = Periods(hourly)
        let hasHours = periods.total >= minimumHourPlays

        let archetype = archetype(
            artistCount: artists.count,
            genreCount: sortedGenres.count,
            seconds: seconds,
            songCount: ranked.count,
            topArtistPlays: artists.first?.plays ?? 0,
            periods: hasHours ? periods : nil
        )

        return RecapStats(
            year: year,
            topSongs: ranked.prefix(10).map { RankedSong(song: $0, plays: $0.playCount ?? 0) },
            totalPlays: totalPlays,
            seconds: seconds,
            uniqueTracks: ranked.count,
            artistCount: artists.count,
            topArtists: Array(artists.prefix(5)),
            genres: genres,
            chronotype: hasHours ? periods.chronotype : nil,
            archetype: ranked.isEmpty ? nil : archetype
        )
    }

    /// Plays by part of the day (Flutter's: night 22–6, morning 6–12, afternoon 12–18, evening 18–22).
    struct Periods: Equatable, Sendable {
        var night = 0, morning = 0, afternoon = 0, evening = 0

        init(_ hourly: [Int: Int]) {
            for (hour, count) in hourly {
                switch hour {
                case 6..<12: morning += count
                case 12..<18: afternoon += count
                case 18..<22: evening += count
                default: night += count
                }
            }
        }

        var total: Int { night + morning + afternoon + evening }

        /// Flutter's order: morning wins ties, then afternoon, then evening, else night.
        var chronotype: Chronotype {
            if morning >= night, morning >= afternoon, morning >= evening, morning > 0 { return .sunrise }
            if afternoon >= night, afternoon >= evening, afternoon > 0 { return .afternoon }
            if evening >= night, evening > 0 { return .twilight }
            return .midnight
        }
    }

    /// Flutter's rules, first match. The last three need the hours; without them (too few plays on
    /// the phone) only the first two can be told, and otherwise there's no personality slide.
    static func archetype(
        artistCount: Int,
        genreCount: Int,
        seconds: Int,
        songCount: Int,
        topArtistPlays: Int,
        periods: Periods?
    ) -> Archetype? {
        if artistCount > 20, genreCount >= 4 { return .luminary }
        let repeatRatio = songCount > 0 ? min(max(Double(seconds) / Double(songCount * 180), 0.5), 10) : 1
        if repeatRatio > 3 || topArtistPlays > 25 { return .devotee }
        guard let periods else { return nil }
        if Double(periods.night) > Double(periods.morning + periods.afternoon) * 0.8 { return .nightOwl }
        if periods.morning > periods.afternoon { return .sunrise }
        return .alchemist
    }

    /// Whether a song is in the year's recap: played at least once, last played this year or since.
    static func counts(_ song: Song, from start: Date) -> Bool {
        guard let date = song.played, date >= start else { return false }
        return (song.playCount ?? 0) > 0
    }

    /// Whether the year has anything to recap: `make(…).isEmpty` is its opposite (the story, or
    /// "Nothing to recap yet"), without working out the rest.
    static func hasPlays(_ songs: [Song], year: Int, calendar: Calendar = .current) -> Bool {
        let start = yearRange(year, calendar: calendar).lowerBound
        return songs.contains { counts($0, from: start) }
    }

    static func yearRange(_ year: Int, calendar: Calendar) -> Range<Date> {
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? .distantPast
        let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) ?? .distantFuture
        return start..<end
    }

    /// "12,345", as Flutter's counter.
    static func grouped(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    /// "1 play" / "N plays".
    static func plays(_ count: Int) -> String {
        count == 1 ? "1 play" : "\(grouped(count)) plays"
    }
}

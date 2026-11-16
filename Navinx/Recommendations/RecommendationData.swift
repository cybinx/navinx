import Foundation
import PlaybackKit
import SubsonicKit

/// What the engine remembers about one song (Flutter `SongProfile`).
nonisolated struct ListeningRecord: Codable, Sendable, Equatable {
    let songID: String
    let title: String
    let artist: String?
    let artistID: String?
    let albumID: String?
    let genre: String?
    let duration: Int?
    var coverArt: String?
    var playCount = 0
    var skipCount = 0
    /// Seconds.
    var timeListened = 0
    var completedPlays = 0
    var userRating: Int?
    var hourlyPlays: [Int: Int] = [:]
    var lastPlayed = Date(timeIntervalSince1970: 0)

    /// The saved keys, as the earlier builds wrote them (C43; see `RecommendationData.CodingKeys`).
    private enum CodingKeys: String, CodingKey {
        case songID = "songID"
        case title = "title"
        case artist = "artist"
        case artistID = "artistID"
        case albumID = "albumID"
        case genre = "genre"
        case duration = "duration"
        case coverArt = "coverArt"
        case playCount = "playCount"
        case skipCount = "skipCount"
        case timeListened = "totalListenTime"
        case completedPlays = "completedPlays"
        case userRating = "userRating"
        case hourlyPlays = "hourlyPlays"
        case lastPlayed = "lastPlayed"
    }

    init(song: Song) {
        songID = song.id
        title = song.title
        artist = song.artist
        artistID = song.artistID
        albumID = song.albumID
        genre = song.genre
        duration = song.duration
        coverArt = song.coverArt
    }

    var completionRate: Double {
        playCount == 0 ? 0 : Double(completedPlays) / Double(playCount)
    }

    func hourLeaning(_ hour: Int) -> Double {
        guard let highest = hourlyPlays.values.max(), highest > 0 else { return 0 }
        return Double(hourlyPlays[hour] ?? 0) / Double(highest)
    }
}

/// The recommendation engine: Flutter `RecommendationService`, with the same weights and lists.
///
/// A plain value, so Home can rank a whole library away from the main thread. Saving and the
/// player's events are `RecommendationModel`'s. What differs from Flutter is what it learns from
/// (D33): see `record`.
nonisolated struct RecommendationData: Codable, Sendable, Equatable {
    private enum Weight {
        static let artistPull = 0.28
        static let genrePull = 0.18
        static let artistScore = 0.11
        static let genreScore = 0.07
        static let albumPull = 0.06
        static let completionRate = 0.09
        static let hourLeaning = 0.05
        static let playWeight = 0.04
        static let userRating = 0.10
        static let songScore = 0.06
        static let favoriteBoost = 0.20
        static let newnessBoost = 0.08
        static let costPerSkip = 0.06
        static let skipCostCap = 0.35
        static let recentPlayCost = 0.015
        static let hourBoost = 0.05
        static let shuffleNoise = 0.12
    }

    private static let fadeHalfLifeDays = 30.0
    private static let recentLimit = 500
    /// Ten years; no listener's real gap is longer, and the epoch of unset data is fifty-odd.
    private static let longestGapDays = 3_650.0

    /// Flutter's "Enable Recommendations" (its switch is C11). Saved by the model, not in this file.
    var isEnabled = true
    private(set) var profiles: [String: ListeningRecord] = [:]

    /// Flutter `getListeningStats`, for Settings → Display: every play counted, and the songs played.
    var listeningStats: (totalPlays: Int, songs: Int) {
        (profiles.values.reduce(0) { $0 + $1.playCount }, profiles.count)
    }
    private(set) var artistPull: [String: Double] = [:]
    private(set) var genrePull: [String: Double] = [:]
    private(set) var albumPull: [String: Double] = [:]
    private(set) var artistRatingPull: [String: Double] = [:]
    private(set) var genreRatingPull: [String: Double] = [:]
    private(set) var skipCounts: [String: Int] = [:]
    private(set) var timePatterns: [Int: [String: Double]] = [:]
    /// Song IDs, latest first.
    private(set) var recentlyPlayed: [String] = []
    private(set) var starredSongs: Set<String> = []
    private(set) var lastFadeDate = Date(timeIntervalSince1970: 0)

    /// The saved file's keys, as the earlier builds wrote them (C43): a renamed property must not move
    /// them, or the listening history would be lost. Changing one needs a move at launch (C43's step 2).
    private enum CodingKeys: String, CodingKey {
        case profiles = "profiles"
        case artistPull = "artistAffinity"
        case genrePull = "genreAffinity"
        case albumPull = "albumAffinity"
        case artistRatingPull = "artistRatingAffinity"
        case genreRatingPull = "genreRatingAffinity"
        case skipCounts = "skipCounts"
        case timePatterns = "timePatterns"
        case recentlyPlayed = "recentlyPlayed"
        case starredSongs = "starredSongs"
        case lastFadeDate = "lastDecayApplied"
    }

    init() {}

    // MARK: Learning

    /// What each player event teaches (D33). Flutter counted every song as a play when it started,
    /// and Next as a completed listen as well as a skip, and left favourites and ratings out. Here a
    /// song counts once, when it goes, by the time it actually played; starting one only puts it
    /// first in Listen Again.
    mutating func record(_ event: ListenEvent, at date: Date = .now, hour: Int? = nil) {
        let hour = hour ?? Calendar.current.component(.hour, from: date)
        switch event {
        case .started(let song):
            markRecent(song.id)
        case .finished(let song, let played, let duration, let end):
            let reachedTheEnd = end == .ended || (duration > 0 && played >= duration * 0.8)
            if played > 0, reachedTheEnd {
                trackPlay(song, secondsPlayed: Int(played), completed: true, at: date, hour: hour)
            } else if end == .next {
                trackSkip(song, secondsPlayed: Int(played))
            } else if played > 0 {
                trackPlay(song, secondsPlayed: Int(played), completed: false, at: date, hour: hour)
            }
        case .starred(let song, let isStarred):
            trackStarred(song, isStarred)
        case .rated(let song, let rating):
            trackRating(song, rating)
        }
    }

    private mutating func markRecent(_ id: String) {
        recentlyPlayed.removeAll { $0 == id }
        recentlyPlayed.insert(id, at: 0)
        if recentlyPlayed.count > Self.recentLimit { recentlyPlayed.removeLast(recentlyPlayed.count - Self.recentLimit) }
    }

    private mutating func trackPlay(_ song: Song, secondsPlayed: Int, completed: Bool, at date: Date, hour: Int) {
        var profile = profiles[song.id] ?? ListeningRecord(song: song)
        if let cover = song.coverArt, !cover.isEmpty { profile.coverArt = cover }
        profile.playCount += 1
        profile.timeListened += secondsPlayed
        if completed { profile.completedPlays += 1 }
        profile.hourlyPlays[hour, default: 0] += 1
        profile.lastPlayed = date
        profiles[song.id] = profile
        markRecent(song.id)

        guard isEnabled else { return }
        let weight = Self.listenWeight(song, secondsPlayed: secondsPlayed, completed: completed)
        if let artist = song.artist { artistPull[artist, default: 0] += weight }
        if let genre = song.genre { genrePull[genre, default: 0] += weight * 0.75 }
        if let album = song.albumID { albumPull[album, default: 0] += weight * 0.6 }
        if let genre = song.genre { timePatterns[hour, default: [:]][genre, default: 0] += 1 }
    }

    private mutating func trackSkip(_ song: Song, secondsPlayed: Int) {
        skipCounts[song.id, default: 0] += 1
        profiles[song.id]?.skipCount += 1

        guard isEnabled else { return }
        let early: Double = if let duration = song.duration, duration > 0 {
            1 - min(max(Double(secondsPlayed) / Double(duration), 0), 1)
        } else {
            1
        }
        let penalty = 0.3 * early
        if let artist = song.artist { artistPull[artist, default: 0] -= penalty }
        if let genre = song.genre { genrePull[genre, default: 0] -= penalty * 0.5 }
    }

    private mutating func trackRating(_ song: Song, _ rating: Int) {
        guard (1...5).contains(rating) else { return }
        var profile = profiles[song.id] ?? ListeningRecord(song: song)
        profile.userRating = rating
        profiles[song.id] = profile

        guard isEnabled else { return }
        let signed = Double(rating - 3) / 2
        if let artist = song.artist { artistRatingPull[artist, default: 0] += signed * 2.5 }
        if let genre = song.genre { genreRatingPull[genre, default: 0] += signed * 1.8 }
    }

    private mutating func trackStarred(_ song: Song, _ isStarred: Bool) {
        if isStarred {
            starredSongs.insert(song.id)
        } else {
            starredSongs.remove(song.id)
        }

        guard isEnabled else { return }
        let delta = isStarred ? 1.0 : -0.5
        if let artist = song.artist { artistPull[artist, default: 0] += delta * 2 }
        if let genre = song.genre { genrePull[genre, default: 0] += delta * 1.5 }
    }

    private static func listenWeight(_ song: Song, secondsPlayed: Int, completed: Bool) -> Double {
        if completed { return 1.5 }
        guard let duration = song.duration, duration > 0 else { return 0.8 }
        let ratio = Double(secondsPlayed) / Double(duration)
        switch ratio {
        case 0.8...: return 1.3
        case 0.6...: return 1.0
        case 0.4...: return 0.8
        case 0.2...: return 0.5
        default: return 0.2
        }
    }

    /// Flutter `_applyDecay`: affinities halve every 30 days, at most once a day.
    mutating func applyDecay(at date: Date = .now) {
        let days = date.timeIntervalSince(lastFadeDate) / 86_400
        guard days >= 1 else { return }
        // A date that was never set (the 1970 epoch of new or cleared data) or is absurdly old isn't
        // a gap to decay over, which would wipe everything learned since: it only starts the clock.
        guard days <= Self.longestGapDays else {
            lastFadeDate = date
            return
        }
        let factor = pow(0.5, days / Self.fadeHalfLifeDays)
        func decay(_ map: inout [String: Double]) {
            for (key, value) in map {
                let decayed = value * factor
                map[key] = abs(decayed) < 0.001 ? nil : decayed
            }
        }
        decay(&artistPull)
        decay(&genrePull)
        decay(&albumPull)
        decay(&artistRatingPull)
        decay(&genreRatingPull)
        lastFadeDate = date
    }

    // MARK: Scoring

    /// Everything a score needs that's the same for each song, worked out once per ranking.
    private struct Ranking {
        let hour: Int
        let maxArtist: Double
        let maxGenre: Double
        let maxAlbum: Double
        let artistScoreCap: Double
        let genreScoreCap: Double
        let recentIndex: [String: Int]
    }

    private func ranking(hour: Int) -> Ranking {
        Ranking(
            hour: hour,
            maxArtist: artistPull.values.max() ?? 0,
            maxGenre: genrePull.values.max() ?? 0,
            maxAlbum: albumPull.values.max() ?? 0,
            artistScoreCap: artistRatingPull.values.max() ?? 0,
            genreScoreCap: genreRatingPull.values.max() ?? 0,
            // Only the latest 20 count.
            recentIndex: Dictionary(uniqueKeysWithValues: recentlyPlayed.prefix(20).enumerated().map { ($0.element, $0.offset) })
        )
    }

    /// Flutter `calculateSongScore`.
    func score(_ song: Song, hour: Int) -> Double {
        score(song, ranking: ranking(hour: hour))
    }

    private func score(_ song: Song, ranking: Ranking) -> Double {
        guard isEnabled else { return 0 }
        func share(_ map: [String: Double], _ key: String?, of highest: Double) -> Double {
            guard let key, highest > 0 else { return 0 }
            return min(max(map[key] ?? 0, 0), highest) / highest
        }

        var score = share(artistPull, song.artist, of: ranking.maxArtist) * Weight.artistPull
        score += share(genrePull, song.genre, of: ranking.maxGenre) * Weight.genrePull
        score += share(albumPull, song.albumID, of: ranking.maxAlbum) * Weight.albumPull
        score += share(artistRatingPull, song.artist, of: ranking.artistScoreCap) * Weight.artistScore
        score += share(genreRatingPull, song.genre, of: ranking.genreScoreCap) * Weight.genreScore

        if let profile = profiles[song.id] {
            score += profile.completionRate * Weight.completionRate
            score += profile.hourLeaning(ranking.hour) * Weight.hourLeaning
            score += min(Double(profile.playCount) / 10, 1) * Weight.playWeight
            if let rating = profile.userRating { score += Double(rating) / 5 * Weight.userRating }
        } else {
            score += Weight.newnessBoost
        }

        if let rating = song.userRating { score += Double(rating) / 5 * Weight.songScore }
        if starredSongs.contains(song.id) || song.starred { score += Weight.favoriteBoost }

        if let skips = skipCounts[song.id], skips > 0 {
            score -= min(Double(skips) * Weight.costPerSkip, Weight.skipCostCap)
        }
        if let index = ranking.recentIndex[song.id] {
            score -= Double(20 - index) * Weight.recentPlayCost
        }
        if let genre = song.genre, let hours = timePatterns[ranking.hour], let highest = hours.values.max(), highest > 0 {
            score += (hours[genre] ?? 0) / highest * Weight.hourBoost
        }
        return min(max(score, 0), 1)
    }

    private func sortedByScore(_ songs: [Song], jitter: Double, limit: Int, hour: Int) -> [Song] {
        guard !songs.isEmpty else { return [] }
        let ranking = ranking(hour: hour)
        return songs
            .map { (song: $0, score: score($0, ranking: ranking) + (jitter > 0 ? Double.random(in: 0..<jitter) : 0)) }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.song)
    }

    // MARK: The lists

    /// Flutter `getPersonalizedFeed`: Home's "Made For You".
    func tailoredFeed(_ songs: [Song], limit: Int, hour: Int) -> [Song] {
        guard isEnabled, !songs.isEmpty else { return Array(songs.prefix(limit)) }
        return sortedByScore(songs, jitter: Weight.shuffleNoise, limit: limit, hour: hour)
    }

    /// Flutter `getListenAgain`: what was played last, latest first.
    func replayPicks(_ songs: [Song], limit: Int) -> [Song] {
        guard !songs.isEmpty else { return [] }
        let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var results: [Song] = []
        for id in recentlyPlayed {
            guard let song = byID[id] else { continue }
            results.append(song)
            if results.count >= limit { break }
        }
        return results
    }

    /// Flutter `getTopHits`: the most played and the favourites; with neither, the library's first songs.
    func heavyRotation(_ songs: [Song], limit: Int, hour: Int) -> [Song] {
        guard !songs.isEmpty else { return [] }
        let candidates = songs.filter {
            (profiles[$0.id]?.playCount ?? 0) > 0 || starredSongs.contains($0.id) || $0.starred
        }
        guard !candidates.isEmpty else { return Array(songs.prefix(limit)) }
        let ranking = ranking(hour: hour)
        let scored: [(song: Song, plays: Int, score: Double)] = candidates.map { song in
            (song, profiles[song.id]?.playCount ?? 0, score(song, ranking: ranking))
        }
        let sorted = scored.sorted { a, b in
            if a.plays != b.plays { return a.plays > b.plays }
            return a.score > b.score
        }
        return sorted.prefix(limit).map(\.song)
    }

    func instantPicks(_ songs: [Song], limit: Int, hour: Int) -> [Song] {
        guard isEnabled, !songs.isEmpty else { return [] }
        let artists = Set(topArtists(5))
        let genres = Set(topGenres(4))
        let recent = Set(recentlyPlayed.prefix(10))
        var candidates = songs.filter {
            !recent.contains($0.id) && (($0.artist.map(artists.contains) ?? false) || ($0.genre.map(genres.contains) ?? false))
        }
        if candidates.count < limit {
            let chosen = Set(candidates.map(\.id))
            candidates += songs.lazy
                .filter { !recent.contains($0.id) && !chosen.contains($0.id) }
                .prefix(limit - candidates.count)
        }
        return sortedByScore(candidates, jitter: 0.05, limit: limit, hour: hour)
    }

    /// Flutter `getDiscoverMix`: unheard songs, preferring your genres by artists you don't play much.
    func explorerBlend(_ songs: [Song], limit: Int, hour: Int) -> [Song] {
        guard isEnabled, !songs.isEmpty else { return [] }
        let genres = Set(topGenres(5))
        let artists = Set(topArtists(10))
        let recent = Set(recentlyPlayed.prefix(20))
        func isNeverPlayed(_ song: Song) -> Bool { profiles[song.id] == nil && !recent.contains(song.id) }
        func inTopGenre(_ song: Song) -> Bool { song.genre.map(genres.contains) ?? false }
        let unheard = songs.filter(isNeverPlayed)
        let inGenre = unheard.filter(inTopGenre)
        let newArtists = inGenre.filter { !($0.artist.map(artists.contains) ?? false) }
        var pool = newArtists
        if pool.isEmpty { pool = inGenre }
        if pool.isEmpty { pool = unheard }
        if pool.isEmpty { pool = songs.filter { !recent.contains($0.id) } }
        return sortedByScore(pool, jitter: 0.30, limit: limit, hour: hour)
    }

    /// Flutter `generateMixes`, in its order. A mix of one artist or genre needs at least 5 songs.
    func mixes(_ songs: [Song], hour: Int) -> [SongMix] {
        guard isEnabled, !songs.isEmpty else { return [] }
        var mixes: [SongMix] = []
        func add(_ name: String, _ list: [Song], minimum: Int = 1) {
            // Flutter's mixes are a map, so a repeated name replaces the earlier mix, in its place.
            guard list.count >= minimum else { return }
            if let index = mixes.firstIndex(where: { $0.name == name }) {
                mixes[index].songs = list
            } else {
                mixes.append(SongMix(name: name, songs: list))
            }
        }
        add("Quick Picks", instantPicks(songs, limit: 20, hour: hour))
        add("Discover Mix", explorerBlend(songs, limit: 20, hour: hour))
        for artist in topArtists(3) {
            add("\(artist) Mix", sortedByScore(songs.filter { $0.artist == artist }, jitter: 0.08, limit: 15, hour: hour), minimum: 5)
        }
        for genre in topGenres(2) {
            add("\(genre) Mix", sortedByScore(songs.filter { $0.genre == genre }, jitter: 0.10, limit: 15, hour: hour), minimum: 5)
        }
        if let genre = timePatterns[hour]?.max(by: { $0.value < $1.value })?.key {
            add(
                "\(Self.timeLabel(hour)) Vibes",
                sortedByScore(songs.filter { $0.genre == genre }, jitter: 0.10, limit: 15, hour: hour),
                minimum: 5
            )
        }
        return mixes
    }

    /// Flutter `getRecommendedArtists`.
    func topArtists(_ limit: Int) -> [String] {
        artistPull.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    func topGenres(_ limit: Int) -> [String] {
        genrePull.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    private static func timeLabel(_ hour: Int) -> String {
        switch hour {
        case 5..<12: "Morning"
        case 12..<17: "Afternoon"
        case 17..<21: "Evening"
        default: "Night"
        }
    }
}

nonisolated struct SongMix: Sendable, Equatable, Identifiable {
    let name: String
    var songs: [Song]
    var id: String { name }
}

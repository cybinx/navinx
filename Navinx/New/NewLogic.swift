import Foundation
import SubsonicKit

/// Fresh From Artists' data: the albums, and the artists they came from, most played first.
nonisolated struct ArtistNewArrivals: Sendable, Equatable {
    var albums: [Album] = []
    var artists: [String] = []

    /// Flutter's line under the title.
    var subtitle: String? {
        switch artists.count {
        case 0: nil
        case 1: "New from \(artists[0])"
        case 2: "New from \(artists[0]) and \(artists[1])"
        default: "New from \(artists[0]), \(artists[1]) and more"
        }
    }
}

/// What the New tab's sections show, from what the server answers. Flutter keeps each section's rules
/// in its widget (`lib/widgets/new_tab/`); the numbers are Flutter's.
nonisolated enum NewFeed {
    static let heroCount = 6
    static let blendLength = 25

    // MARK: Fetching

    static func hero(_ client: SubsonicClient) async throws -> [Album] {
        try await client.albumList(.newest, size: heroCount)
    }

    /// Skips the albums the hero already shows.
    static func latestAdditions(_ client: SubsonicClient) async throws -> [Album] {
        try await client.albumList(.newest, size: 20, offset: heroCount)
    }

    static func mix(_ client: SubsonicClient) async throws -> [Song] {
        try await client.randomSongs(size: blendLength)
    }

    static func rediscover(_ client: SubsonicClient) async throws -> [Album] {
        async let starredList = client.albumList(.starred, size: 200)
        async let recentList = client.albumList(.recent, size: 60)
        let (starred, recent) = try await (starredList, recentList)
        var picks = rediscoverPicks(starred: starred, recent: recent)
        if picks.count < 6 {
            let frequent = try await client.albumList(.frequent, size: 40)
            picks = rediscoverTopUp(picks, frequent: frequent, recent: recent)
        }
        return Array(picks.prefix(14))
    }

    static func artistNewArrivals(_ client: SubsonicClient) async throws -> ArtistNewArrivals {
        let frequent = try await client.albumList(.frequent, size: 60)
        guard !frequent.isEmpty else { return ArtistNewArrivals() }
        let top = topArtists(frequent: frequent)
        // One artist failing only loses that artist, as in Flutter.
        let catalogues = await withTaskGroup(of: (Int, [Album]).self) { group in
            for (index, artist) in top.enumerated() {
                group.addTask { (index, (try? await client.artistAlbums(artistID: artist.id)) ?? []) }
            }
            var found = [[Album]](repeating: [], count: top.count)
            for await (index, albums) in group { found[index] = albums }
            return found
        }
        return freshAlbums(frequent: frequent, top: top, catalogues: catalogues)
    }

    // MARK: Rules

    /// Starred albums not played lately, shuffled so the row changes over time.
    static func rediscoverPicks(starred: [Album], recent: [Album]) -> [Album] {
        let recentIDs = Set(recent.map(\.id))
        return starred.filter { !recentIDs.contains($0.id) }.shuffled()
    }

    /// With too few picks, most-played albums that aren't recent either go after them.
    static func rediscoverTopUp(_ picks: [Album], frequent: [Album], recent: [Album]) -> [Album] {
        let excluded = Set(recent.map(\.id)).union(picks.map(\.id))
        return picks + frequent.filter { !excluded.contains($0.id) }.shuffled()
    }

    /// The eight most-played artists: an album counts for more the nearer it is to the top of the
    /// list. Compilations and albums with no artist ID don't count.
    static func topArtists(frequent: [Album]) -> [(id: String, name: String)] {
        var scores: [String: Int] = [:]
        var names: [String: String] = [:]
        var order: [String] = []
        for (index, album) in frequent.enumerated() {
            guard let id = album.artistID, !id.isEmpty, !isVariousArtists(album.artist) else { continue }
            if scores[id] == nil {
                order.append(id)
                names[id] = album.artist ?? ""
            }
            scores[id, default: 0] += frequent.count - index
        }
        // Swift's sort keeps the first-seen order on a tie.
        let ranked = order.sorted { scores[$0, default: 0] > scores[$1, default: 0] }
        return ranked.prefix(8).map { (id: $0, name: names[$0] ?? "") }
    }

    /// Up to two albums per artist that aren't among the most played, newest first, 14 at most.
    static func freshAlbums(frequent: [Album], top: [(id: String, name: String)], catalogues: [[Album]]) -> ArtistNewArrivals {
        let played = Set(frequent.map(\.id))
        var result = ArtistNewArrivals()
        var taken = Set<String>()
        for (artist, catalogue) in zip(top, catalogues) {
            let fresh = catalogue.filter { !played.contains($0.id) }.sorted(by: isNewer)
            guard !fresh.isEmpty else { continue }
            // An album credited to two top artists is listed once, under the first.
            var added = 0
            for album in fresh where added < 2 && !taken.contains(album.id) {
                taken.insert(album.id)
                result.albums.append(album)
                added += 1
            }
            if !artist.name.isEmpty { result.artists.append(artist.name) }
        }
        result.albums = Array(result.albums.sorted(by: isNewer).prefix(14))
        return result
    }

    /// Flutter `compareAlbumsNewestFirst`: by release year, then date added.
    static func isNewer(_ a: Album, than b: Album) -> Bool {
        let (yearA, yearB) = (a.year ?? 0, b.year ?? 0)
        if yearA != yearB { return yearA > yearB }
        return (a.created ?? .distantPast) > (b.created ?? .distantPast)
    }

    /// "Artist · year", with whichever of the two the album has.
    static func artistAndYear(_ album: Album) -> String {
        [album.artist, album.year.map(String.init)].compactMap(\.self).joined(separator: " · ")
    }

    /// The mix card's mosaic: the covers of up to four different albums.
    static func mixCovers(_ songs: [Song]) -> [String] {
        var seen = Set<String>()
        var covers: [String] = []
        for song in songs {
            guard let cover = song.coverArt, !cover.isEmpty else { continue }
            if seen.insert(song.albumID ?? cover).inserted { covers.append(cover) }
            if covers.count == 4 { break }
        }
        return covers
    }

    /// The mix card's line: its first three artists.
    static func mixArtists(_ songs: [Song]) -> String {
        var names: [String] = []
        for song in songs {
            if let artist = song.artist, !artist.isEmpty, !names.contains(artist) { names.append(artist) }
            if names.count == 3 { break }
        }
        return names.count < 3 ? names.joined(separator: " and ") : "\(names[0]), \(names[1]), \(names[2]) and more"
    }

    private static func isVariousArtists(_ name: String?) -> Bool {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return name.isEmpty || name == "various artists" || name == "various"
    }
}

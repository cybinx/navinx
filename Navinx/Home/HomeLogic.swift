import Foundation
import SubsonicKit

/// Home's chips, in Flutter's order.
nonisolated enum HomeCategory: CaseIterable, Hashable {
    case all, music, madeForYou, playlists

    var title: String {
        switch self {
        case .all: "All"
        case .music: "Music"
        case .madeForYou: "Made For You"
        case .playlists: "Playlists"
        }
    }

    var showsMusic: Bool { self == .all || self == .music }
    var showsMadeForYou: Bool { self == .all || self == .madeForYou }
    var showsPlaylists: Bool { self == .all || self == .playlists }
}

/// Home's recommended rows, ranked away from the main thread and kept until `key` changes.
nonisolated struct HomeFeed: Sendable, Equatable {
    var mixes: [SongMix] = []
    var personalized: [Song] = []
    var replayPicks: [Song] = []
    var heavyRotation: [Song] = []

    /// Flutter's sizes. With recommendations switched off, all four rows go.
    static func make(data: RecommendationData, songs: [Song], hour: Int) -> HomeFeed {
        guard data.isEnabled, !songs.isEmpty else { return HomeFeed() }
        return HomeFeed(
            mixes: data.mixes(songs, hour: hour),
            personalized: data.tailoredFeed(songs, limit: 12, hour: hour),
            replayPicks: data.replayPicks(songs, limit: 10),
            heavyRotation: data.heavyRotation(songs, limit: 10, hour: hour)
        )
    }

    /// Flutter `_computeRandomKey`: the rows are ranked again when this changes.
    static func key(data: RecommendationData, songs: [Song]) -> String {
        guard data.isEnabled, let first = songs.first, let last = songs.last else { return "" }
        return "\(songs.count)_\(first.id)_\(last.id)_\(data.profiles.count)_\(data.recentlyPlayed.count)_\(data.recentlyPlayed.first ?? "")"
    }
}

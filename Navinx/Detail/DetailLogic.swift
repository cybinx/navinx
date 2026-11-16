import Foundation
import SubsonicKit

/// The detail pages' pure rules, from Flutter's album, artist and playlist screens.
nonisolated enum DetailLogic {
    /// The track filter: title or artist contains the text, ignoring case.
    static func filter(_ songs: [Song], query: String) -> [Song] {
        filteredIndexes(songs, query: query).map { songs[$0] }
    }

    /// The same, as places in the list, for pages that edit what's underneath.
    static func filteredIndexes(_ songs: [Song], query: String) -> [Int] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Array(songs.indices) }
        return songs.indices.filter {
            songs[$0].title.lowercased().contains(query) || (songs[$0].artist?.lowercased().contains(query) ?? false)
        }
    }

    /// The album's line: "12 songs • ROCK • 2020 • 1 HR 2 MIN".
    static func albumSummary(album: Album, songs: [Song]) -> String {
        let total = songs.reduce(0) { $0 + ($1.duration ?? 0) }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        var parts = [CountText.songs(songs.count)]
        if let genre = album.genre { parts.append(genre.uppercased()) }
        if let year = album.year { parts.append(String(year)) }
        parts.append(hours > 0 ? "\(hours) HR \(minutes) MIN" : "\(minutes) MIN")
        return parts.joined(separator: " • ")
    }

    /// Flutter's split by song count: albums 7+, EPs 3–6, singles 2 or fewer (no count: a single).
    static func sections(_ albums: [Album]) -> (albums: [Album], eps: [Album], singles: [Album]) {
        (
            albums.filter { ($0.songCount ?? 0) >= 7 },
            albums.filter { (3...6).contains($0.songCount ?? 0) },
            albums.filter { ($0.songCount ?? 0) <= 2 }
        )
    }

    /// The artist page's header art.
    static func artistArt(_ artist: Artist, info: ArtistInfo?) -> String? {
        artist.coverArt ?? info?.largeImageURL ?? info?.mediumImageURL ?? artist.artistImageURL
            ?? (artist.id.isEmpty ? nil : "ar-\(artist.id)")
    }

    /// Who the page is about when `getArtist` failed: the library's artist, a song's artist, else an album's.
    static func fallbackArtist(id: String, cached: [Artist], songs: [Song], albums: [Album]) -> Artist? {
        if let artist = cached.first(where: { $0.id == id }) { return artist }
        if let song = songs.first(where: { $0.artistID == id }) {
            return Artist(id: id, name: song.artist ?? "Unknown Artist")
        }
        if let album = albums.first { return Artist(id: id, name: album.artist ?? "Unknown Artist") }
        return nil
    }

    /// Whether a failed load means the item is gone (Subsonic's "data not found", code 70), rather
    /// than the server not answering: only the first earns "not found", the rest earn a Retry.
    static func isMissing(_ error: Error) -> Bool {
        if case .api(let code, _)? = error as? SubsonicError { return code == 70 }
        return false
    }

    /// Whether the signed-in account may change a playlist: its own (the owner is compared without
    /// regard to case), one with no owner given, or any of them for an administrator.
    static func canEdit(_ playlist: Playlist, username: String?, isAdmin: Bool) -> Bool {
        if isAdmin { return true }
        guard let owner = playlist.owner, !owner.isEmpty, let username, !username.isEmpty else { return true }
        return owner.caseInsensitiveCompare(username) == .orderedSame
    }

    // MARK: Biography

    /// An artist's biography as plain text. Navidrome passes Last.fm's on as HTML, ending in
    /// "<a ...>Read more on Last.fm</a>", with entities in the text.
    static func plainBiography(_ html: String) -> String {
        var text = html.replacingOccurrences(
            of: #"<a\b[^>]*>\s*Read more on Last\.fm\s*</a>"#, with: "", options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"</?[A-Za-z][^>]*>"#, with: "", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: #"[ \t\u00A0]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #" ?\n ?"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "hellip": "…", "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
    ]

    /// Each entity once, so "&amp;lt;" becomes "&lt;" and no further.
    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&"),
              let regex = try? NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z]+);")
        else { return text }
        let source = text as NSString
        var result = ""
        var position = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: position, length: match.range.location - position))
            let name = source.substring(with: match.range(at: 1))
            result += decodedEntity(name) ?? source.substring(with: match.range)
            position = match.range.location + match.range.length
        }
        return result + source.substring(from: position)
    }

    private static func decodedEntity(_ name: String) -> String? {
        guard name.hasPrefix("#") else { return namedEntities[name] }
        let digits = name.dropFirst()
        let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
        return value.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
    }
}

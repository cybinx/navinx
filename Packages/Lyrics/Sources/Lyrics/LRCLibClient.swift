import Foundation
import SubsonicKit

/// Flutter `LrcLibService`: lyrics from lrclib.net for songs the server has none for. Answers are
/// kept for the app's run (misses too, the cache bounded), by cleaned artist and title.
///
/// **The artist is required (D44), unlike Flutter's code.** A song LRCLIB doesn't have, such as an
/// unreleased one, gets no lyrics rather than another song's: Flutter's title-only searches brought
/// back the wrong artist nearly every time, and a search's results are only taken if they're this
/// artist's and this song.
public actor LRCLibClient {
    /// The app's one client, so answers are remembered across songs.
    public static let shared = LRCLibClient()

    private static let base = URL(string: "https://lrclib.net/api")!
    /// Flutter's connect and receive timeouts.
    private static let timeout: TimeInterval = 6

    private let transport: any HTTPTransport
    /// A key's lyrics, or nil for a miss. Bounded: past `cacheLimit` the oldest go first.
    private var cache: [String: String?] = [:]
    private var cacheOrder: [String] = []
    private static let cacheLimit = 500

    private struct Answer: Decodable {
        let artistName: String?
        let trackName: String?
        let syncedLyrics: String?
        let plainLyrics: String?

        /// Flutter `_parseLrcLibResponse`: the synced text if there is any, else the plain.
        var text: String? {
            if let syncedLyrics, !syncedLyrics.isEmpty { return syncedLyrics }
            if let plainLyrics, !plainLyrics.isEmpty { return plainLyrics }
            return nil
        }
    }

    /// LRCLIB asks clients to name themselves.
    public static func makeTransport() -> any HTTPTransport {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": "Navinx/1.0"]
        return URLSessionTransport(session: URLSession(configuration: configuration))
    }

    public init(transport: (any HTTPTransport)? = nil) {
        self.transport = transport ?? Self.makeTransport()
    }

    /// Flutter `searchLyrics`, without its title-only searches: exact matches first, then a search
    /// for each artist and title. The answer is LRC text or plain lyrics; `TimedLyricsReader` reads either.
    public func search(artist: String?, title: String) async -> String? {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let cleanedTitle = Self.cleanTitle(title)
        let cleanedArtist = artist.flatMap { $0.isEmpty ? nil : Self.cleanArtist($0) }
        // "Artist - Song" in the title: the artist may be there rather than in the tags.
        var extracted: (artist: String, title: String)?
        let parts = title.components(separatedBy: " - ")
        if parts.count >= 2 {
            let artistPart = Self.cleanArtist(parts[0])
            let titlePart = Self.cleanTitle(parts[1...].joined(separator: " - "))
            if !artistPart.isEmpty, !titlePart.isEmpty { extracted = (artistPart, titlePart) }
        }
        // What was asked, whole: a hit found through the "Artist - Song" reading belongs to this
        // title, not to the tagged artist's song of the same cleaned name.
        let key = "\(cleanedArtist?.lowercased() ?? "")|\(cleanedTitle.lowercased())|"
            + (extracted.map { "\($0.artist)|\($0.title)".lowercased() } ?? "")
        if let cached = cache[key] { return cached }

        var pairs: [(artist: String, title: String)] = []
        if let extracted { pairs.append(extracted) }
        if let cleanedArtist, !cleanedArtist.isEmpty, !cleanedTitle.isEmpty {
            pairs.append((cleanedArtist, cleanedTitle))
        }
        // A miss is remembered only when every request got an answer (a 404 or an empty list), not when
        // one failed (no network, a server error): that song is worth asking about again.
        var answered = true
        for pair in pairs {
            if Task.isCancelled { return nil }
            if let answer = await exact(artist: pair.artist, title: pair.title, answered: &answered), let text = answer.text {
                remember(key, text)
                return text
            }
        }

        for pair in pairs {
            if Task.isCancelled { return nil }
            if let text = await bestMatch(artist: pair.artist, title: pair.title, answered: &answered) {
                remember(key, text)
                return text
            }
        }
        if answered, !Task.isCancelled { remember(key, nil) }
        return nil
    }

    private func remember(_ key: String, _ text: String?) {
        if !cache.keys.contains(key) {
            cacheOrder.append(key)
            if cacheOrder.count > Self.cacheLimit { cache[cacheOrder.removeFirst()] = nil }
        }
        cache[key] = .some(text)
    }

    private func exact(artist: String, title: String, answered: inout Bool) async -> Answer? {
        guard let data = await fetch("get", [("artist_name", artist), ("track_name", title)], answered: &answered)
        else { return nil }
        return try? JSONDecoder().decode(Answer.self, from: data)
    }

    /// Of the results that are really this song, the first with synced lyrics, else the first with
    /// plain ones.
    private func bestMatch(artist: String, title: String, answered: inout Bool) async -> String? {
        guard let data = await fetch("search", [("q", "\(artist) \(title)")], answered: &answered),
              let found = try? JSONDecoder().decode([Answer].self, from: data) else { return nil }
        let results = found.filter { Self.isSameSong($0.artistName, $0.trackName, artist: artist, title: title) }
        let synced = results.first { !($0.syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let plain = results.first { !($0.plainLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return (synced ?? plain)?.text
    }

    /// The body of a 200. `answered` goes false when there was no answer worth trusting (the call
    /// failed, or the server erred); a 404 is an answer ("not here").
    private func fetch(_ path: String, _ query: [(String, String)], answered: inout Bool) async -> Data? {
        guard var components = URLComponents(url: Self.base.appending(path: path), resolvingAgainstBaseURL: false)
        else {
            answered = false
            return nil
        }
        components.queryItems = query.map(URLQueryItem.init)
        // URLComponents leaves a literal "+" as it is, and the server reads it as a space ("AC+DC").
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else {
            answered = false
            return nil
        }
        guard let (data, response) = try? await transport.get(url, timeout: Self.timeout) else {
            answered = false
            return nil
        }
        guard response.statusCode == 200 else {
            if response.statusCode != 404 { answered = false }
            return nil
        }
        return data
    }

    // MARK: Cleaning names

    private static let titleNoise = [
        #"\((?:official|music|video|audio|lyrics?|lyric video|visualizer|hd|4k|remastered|live|explicit|clip|video oficial|clip officiel).*?\)"#,
        #"\[(?:official|music|video|audio|lyrics?|lyric video|visualizer|hd|4k|remastered|live|explicit|clip|video oficial|clip officiel).*?\]"#,
        #"\((?:feat\.|ft\.|featuring).*?\)"#,
        #"\[(?:feat\.|ft\.|featuring).*?\]"#,
        #"(?:feat\.|ft\.|featuring).*$"#,
        #"\(prod\..*?\)"#,
        #"\[prod\..*?\]"#,
    ]

    private static func replacing(_ pattern: String, in text: String, with replacement: String = "") -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
    }

    /// Flutter `cleanTitle`: drops an "Artist - " in front, then "(Official Video)", "(feat. …)" and
    /// the like, and quotes. Falls back on the original if nothing's left.
    public static func cleanTitle(_ raw: String) -> String {
        var title = raw
        let parts = title.components(separatedBy: " - ")
        if parts.count >= 2 { title = parts[1...].joined(separator: " - ") }
        for pattern in titleNoise {
            title = replacing(pattern, in: title, with: " ")
        }
        title = title.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
        title = replacing(#"\s+"#, in: title, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? raw : title
    }

    /// Flutter `cleanArtist`: drops " - Topic", "VEVO", "Official" and "feat. …".
    public static func cleanArtist(_ raw: String) -> String {
        var artist = raw
        for pattern in [#"\s*-\s*Topic$"#, #"\s*VEVO$"#, #"\s*Official$"#, #"(?:feat\.|ft\.|featuring).*$"#] {
            artist = replacing(pattern, in: artist)
        }
        artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return artist.isEmpty ? raw : artist
    }

    /// Whether a search result is this song. The artist can differ in punctuation, case and extras such
    /// as a second artist, so one only has to contain the other. The title must be the same after
    /// cleaning the punctuation and case, or the same but for a bracketed or dashed extra such as
    /// "(Remastered 2020)", " - Live" or "(feat. …)": "Go" is not "Gone".
    static func isSameSong(_ foundArtist: String?, _ foundTitle: String?, artist: String, title: String) -> Bool {
        func overlaps(_ a: String, _ b: String) -> Bool {
            !a.isEmpty && !b.isEmpty && (a.contains(b) || b.contains(a))
        }
        guard let foundArtist, let foundTitle else { return false }
        return overlaps(normal(foundArtist), normal(artist))
            && (sameTitle(foundTitle, title) || sameTitle(cleanTitle(foundTitle), title))
    }

    /// Letters and digits only, lowercased.
    private static func normal(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }

    /// Words in a title's extra that make it a version of the same song, not another song.
    private static let versionWords: Set<String> = [
        "remaster", "remastered", "live", "feat", "ft", "featuring", "version", "edit", "radio", "mono", "stereo",
        "deluxe", "edition", "explicit", "clean", "single", "album", "bonus", "original", "mix", "acoustic",
        "anniversary",
    ]

    private static func sameTitle(_ a: String, _ b: String) -> Bool {
        guard !normal(a).isEmpty, !normal(b).isEmpty else { return false }
        if normal(a) == normal(b) { return true }
        // The title proper is what's in front of the first " - ", "(" or "[".
        func split(_ title: String) -> (core: String, extra: String) {
            var end = title.endIndex
            for marker in [" - ", "(", "["] {
                if let range = title.range(of: marker), range.lowerBound < end { end = range.lowerBound }
            }
            return (String(title[..<end]), String(title[end...]))
        }
        func isVersion(_ extra: String) -> Bool {
            extra.isEmpty || extra.lowercased().split { !$0.isLetter && !$0.isNumber }.contains { versionWords.contains(String($0)) }
        }
        let (coreA, extraA) = split(a), (coreB, extraB) = split(b)
        return !normal(coreA).isEmpty && normal(coreA) == normal(coreB) && isVersion(extraA) && isVersion(extraB)
    }
}

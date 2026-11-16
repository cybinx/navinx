import Foundation

/// One credited artist (OpenSubsonic's `artists` on songs, albums and artists).
/// Flutter: `lib/models/artist_ref.dart`.
public struct ArtistCredit: Sendable, Hashable, Decodable {
    public var id: String
    public var name: String
    public var coverArt: String?

    public init(id: String, name: String, coverArt: String? = nil) {
        self.id = id
        self.name = name
        self.coverArt = coverArt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        id = c.string("id") ?? ""
        name = c.string("name") ?? ""
        coverArt = c.string("coverArt")
    }

    /// The cover-art ID to show: `coverArt` if set, else the artist ID (Navidrome serves artist
    /// images under the artist's ID), else nil.
    public var coverToShow: String? {
        if let coverArt, !coverArt.isEmpty { return coverArt }
        return id.isEmpty ? nil : id
    }
}

// MARK: - Splitting combined artist names (the Flutter app's rules, kept as they are)

extension ArtistCredit {
    /// Separators between artists in one name: `,` `/` `;` `&` `\` `|` anywhere, and the words
    /// "featuring", "feat." "ft." "and", "x", "with" (any case) only between two names, with
    /// spaces on both sides.
    ///
    /// D12 (the user, 2026-11-05) fixed two quirks of the Flutter rule, which matched words
    /// anywhere: "feat" inside "Featuring" ("A Featuring B" → "A", "uring B") and a name's own
    /// "X" or leading "With" ("X & Y" → "Y", "With Confidence" → "Confidence").
    private static let separator = try! NSRegularExpression(
        pattern: #"\s*(?:,|/|;|&|\\|\|)\s*|\s+(?:featuring|feat\.?|ft\.?|and|x|with)(?=\s)\s*"#,
        options: [.caseInsensitive]
    )

    /// Splits `"A & B feat. C"` into `["A", "B", "C"]`. A name with nothing to split comes back
    /// alone; an empty name gives `[]`.
    public static func parseArtistCredits(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        let ns = trimmed as NSString
        var parts: [String] = []
        var start = 0
        for match in separator.matches(in: trimmed, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: start, length: match.range.location - start)))
            start = match.range.location + match.range.length
        }
        parts.append(ns.substring(from: start))

        let cleaned = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? [trimmed] : cleaned
    }

    /// The `artists` list as the Flutter app reads it: entries whose name splits become one ref
    /// per name (with no ID); entries with neither ID nor name are dropped; an empty result is nil.
    static func expand(_ refs: [ArtistCredit]?) -> [ArtistCredit]? {
        guard let refs else { return nil }
        var result: [ArtistCredit] = []
        for ref in refs {
            let names = parseArtistCredits(ref.name)
            if names.count > 1 {
                result += names.map { ArtistCredit(id: "", name: $0, coverArt: ref.coverArt) }
            } else if !ref.id.isEmpty || !ref.name.isEmpty {
                result.append(ref)
            }
        }
        return result.isEmpty ? nil : result
    }

    /// The artists to show for an item: its credited artists if any (split as above), else the
    /// plain `artist` name (split), else just the ID. Flutter: `ArtistRef.fromListOrFallback`.
    public static func list(
        _ participants: [ArtistCredit]?,
        fallbackName: String?,
        fallbackID: String?
    ) -> [ArtistCredit] {
        if let participants, !participants.isEmpty {
            var expanded: [ArtistCredit] = []
            for participant in participants {
                let names = parseArtistCredits(participant.name)
                if names.count > 1 {
                    expanded += names.map { ArtistCredit(id: "", name: $0, coverArt: participant.coverArt) }
                } else {
                    expanded.append(participant)
                }
            }
            if !expanded.isEmpty { return expanded }
        }

        if let fallbackName, !fallbackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let names = parseArtistCredits(fallbackName)
            if names.count > 1 {
                return names.map { ArtistCredit(id: "", name: $0) }
            }
            return [ArtistCredit(
                id: fallbackID ?? "",
                name: fallbackName.trimmingCharacters(in: .whitespacesAndNewlines)
            )]
        }

        if let fallbackID, !fallbackID.isEmpty {
            return [ArtistCredit(id: fallbackID, name: "")]
        }
        return []
    }
}

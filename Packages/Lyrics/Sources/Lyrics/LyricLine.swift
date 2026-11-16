import Foundation
import SubsonicKit

/// One line of lyrics (Flutter `LyricLine`). Times are seconds. Flutter's model also has word
/// timings, but nothing there ever fills them, so they aren't carried over.
public struct LyricLine: Sendable, Hashable, Codable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval?

    public init(text: String, start: TimeInterval, end: TimeInterval? = nil) {
        self.text = text
        self.start = start
        self.end = end
    }

    /// Flutter's `next.startTime - 1 ms`: each line ends where the next begins.
    static func chained(_ lines: [LyricLine]) -> [LyricLine] {
        var sorted = lines.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
        for index in sorted.indices.dropLast() {
            sorted[index].end = sorted[index + 1].start - 0.001
        }
        return sorted
    }

    /// Flutter `_fetchLyrics`' reading of OpenSubsonic's structured lyrics. Unsynced lyrics have no
    /// start times, so every line starts at 0. The lyrics' `offset` (milliseconds) is added to every
    /// start, but never so far that a line would start before 0: the shift stops at the earliest line,
    /// which keeps the order and the spacing.
    public static func lines(from structured: StructuredLyrics) -> [LyricLine] {
        let kept = structured.lines.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let shift = max(structured.offset, -max(0, kept.compactMap(\.start).min() ?? 0))
        let lines = kept.map { line in
            LyricLine(text: line.value, start: TimeInterval(line.start.map { max(0, $0 + shift) } ?? 0) / 1000)
        }
        return chained(lines)
    }
}

/// Flutter `LrcParser`. Its file is named `lrc_ttml_parser`, but there is no TTML parser in the
/// Flutter app, and Navidrome's answers are already structured, so none is needed here either.
public enum TimedLyricsReader {
    /// Timed lines in time order, a line with several tags once for each. Text with no timed lines
    /// at all is plain lyrics: every line starts at 0.
    public static func parse(_ content: String) -> [LyricLine] {
        // `[mm:ss]`, `[mm:ss.x]`, `[mm:ss.xx]`, `[mm:ss.xxx]` (or more digits), with `:` also allowed before
        // the fraction, and `[h:mm:ss.xx]` with hours (its fraction is then needed to tell it from `[mm:ss:xx]`).
        let tag = /\[(?:(\d{1,2}):)?(\d{1,3}):(\d{2})(?:[.:](\d{1,9}))?\]/
        // Enhanced LRC's word times, `<mm:ss.xx>`, are dropped: lines are what's shown.
        let wordTag = /<(?:\d{1,2}:)?\d{1,3}:\d{2}(?:[.:]\d{1,9})?>/
        // A byte-order mark in front of the file isn't part of the first line.
        let content = content.replacingOccurrences(of: "\u{FEFF}", with: "")
        let rows = content.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        var raw: [(text: String, start: TimeInterval)] = []
        for row in rows where !row.isEmpty {
            let matches = row.matches(of: tag)
            guard let last = matches.last else { continue }
            let text = row[last.range.upperBound...].replacing(wordTag, with: "").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            for match in matches {
                let (first, second, third) = (match.output.1, match.output.2, match.output.3)
                let start: TimeInterval
                if let first, match.output.4 != nil {
                    start = (TimeInterval(first) ?? 0) * 3600 + (TimeInterval(second) ?? 0) * 60
                        + (TimeInterval(third) ?? 0) + fraction(match.output.4)
                } else if let first {
                    // `[mm:ss:xx]`: the third number is the fraction.
                    start = (TimeInterval(first) ?? 0) * 60 + (TimeInterval(second) ?? 0) + fraction(third)
                } else {
                    start = (TimeInterval(second) ?? 0) * 60 + (TimeInterval(third) ?? 0) + fraction(match.output.4)
                }
                raw.append((text, start))
            }
        }
        guard !raw.isEmpty else {
            // No timed line: plain lyrics, without the file's own tags (`[ar:…]`, `[offset:…]`, …).
            let metadata = /\[(?:ar|ti|al|au|by|offset|length|re|ve|tool|lang|id|hash|total|#):[^\]]*\]/.ignoresCase()
            return rows.filter { !$0.isEmpty && $0.wholeMatch(of: metadata) == nil }.map { LyricLine(text: $0, start: 0) }
        }
        // A positive offset shows the lines sooner, but never so far that one starts before 0: the shift
        // stops at the earliest line, so the order and the spacing stay.
        let shift = min(offsetSeconds(in: rows), raw.map(\.start).min() ?? 0)
        return LyricLine.chained(raw.map { LyricLine(text: $0.text, start: max(0, $0.start - shift)) })
    }

    /// The `[offset:±ms]` tag, in seconds. By the LRC convention a positive offset shows the lyrics
    /// sooner, so it is taken off every start time.
    private static func offsetSeconds(in rows: [String]) -> TimeInterval {
        let tag = /\[offset:\s*([+-]?\d+)\s*\]/.ignoresCase()
        for row in rows {
            if let match = row.firstMatch(of: tag), let milliseconds = TimeInterval(match.output.1) {
                return milliseconds / 1000
            }
        }
        return 0
    }

    /// `.5` is 500 ms, `.50` is 500 ms, `.500` is 500 ms, `.5000` is 500 ms.
    private static func fraction(_ digits: Substring?) -> TimeInterval {
        guard let digits, let value = TimeInterval(digits) else { return 0 }
        return value / pow(10, TimeInterval(digits.count))
    }
}

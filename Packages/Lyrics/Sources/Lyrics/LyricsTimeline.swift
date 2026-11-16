import Foundation

/// What the lyrics page shows and which line is current: the logic of Flutter `LyricsListView`.
public struct LyricsTimeline: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `index` is the place in the lyrics.
        case line(LyricLine, index: Int)
        /// A long gap, shown as three dots.
        case interlude
    }

    public struct Item: Sendable, Equatable, Identifiable {
        public let id: Int
        public let kind: Kind
        public let start: TimeInterval
        public let end: TimeInterval
    }

    public enum LineState: Sendable, Equatable {
        case past, current, future
    }

    /// Where the page is at a moment in the song.
    public struct Moment: Sendable, Equatable {
        /// The current item; nil in unsynced lyrics.
        public let item: Int?
        /// The current line; nil in unsynced lyrics and during an interlude.
        public let line: Int?
    }

    public let items: [Item]

    /// Every item starts at 0 (even a single line): there are no timings to follow.
    public var isUnsynced: Bool {
        !items.isEmpty && items.allSatisfy { $0.start == 0 }
    }

    /// Flutter `_buildItems`. The dots come before a first line more than 10 seconds in, and in a
    /// gap of more than 10 seconds between lines. A line lasts until the next one, or 5 seconds if
    /// that's longer away. The ends the parsers chain (1 ms before the next line) don't count for
    /// that: with them there would never be a gap, so the dots could only ever show before the first
    /// line (as in Flutter, whose parsers chain the same way).
    public init(lines: [LyricLine]) {
        var items: [Item] = []
        func add(_ kind: Kind, _ start: TimeInterval, _ end: TimeInterval) {
            items.append(Item(id: items.count, kind: kind, start: start, end: end))
        }
        if let first = lines.first, first.start > 10 {
            add(.interlude, 0, first.start)
        }
        for (index, line) in lines.enumerated() {
            let isLast = index == lines.count - 1
            let next = isLast ? 24 * 60 * 60 : lines[index + 1].start
            let natural = next - line.start > 5 ? line.start + 5 : next
            let end = min(line.end ?? natural, natural)
            add(.line(line, index: index), line.start, end)
            if !isLast, next - end > 10 {
                add(.interlude, end, next)
            }
        }
        self.items = items
    }

    /// Flutter `_updateCurrentIndex`. The current item is the last one that has started, so it stays
    /// current through the gap to the next one (also past the end); before the first timing, the first
    /// is current.
    public func moment(at time: TimeInterval) -> Moment {
        guard !items.isEmpty, !isUnsynced else { return Moment(item: nil, line: nil) }
        let index = items.lastIndex { $0.start <= time } ?? 0
        guard case .line(_, let line) = items[index].kind else { return Moment(item: index, line: nil) }
        return Moment(item: index, line: line)
    }

    /// Flutter's choice of look. With no current line, a line is past once its time is over. Unsynced
    /// lyrics have no time to be over (Flutter fades them once their 5 seconds are up): every line shows
    /// as the current one, at full strength.
    public func state(ofLine line: Int, item: Item, at moment: Moment, time: TimeInterval) -> LineState {
        if isUnsynced { return .current }
        guard let current = moment.line else { return item.end <= time ? .past : .future }
        if line < current { return .past }
        return line == current ? .current : .future
    }

    /// How many lines from the current one, for the optional blur. With no current line, 3.
    public func distance(ofLine line: Int, at moment: Moment) -> Int {
        moment.line.map { abs(line - $0) } ?? 3
    }

    /// Flutter's live lyric pill: the last line that has started, until the next one does. Unsynced
    /// lyrics (no line starts after 0) have none.
    public static func activeLine(in lines: [LyricLine], at time: TimeInterval) -> LyricLine? {
        guard lines.contains(where: { $0.start > 0 }) else { return nil }
        for (index, line) in lines.enumerated() {
            let next = lines.indices.contains(index + 1) ? lines[index + 1].start : .infinity
            if time >= line.start, time < next { return line }
        }
        return nil
    }

    /// Flutter `InterludeDotsWidget`: three dots, one going each second over the last three seconds.
    public static func visibleDots(timeLeft: TimeInterval) -> Int {
        if timeLeft <= 1 { return 0 }
        if timeLeft <= 2 { return 1 }
        if timeLeft <= 3 { return 2 }
        return 3
    }
}

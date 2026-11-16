import Foundation
import SubsonicKit

/// Flutter `RepeatMode`, in its order, which is also the order the repeat button cycles through.
public enum RepeatMode: Int, Sendable, CaseIterable {
    case off, all, one

    /// The repeat button's next mode (Flutter `toggleRepeat`).
    public var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

/// What's playing and what's up next. Pure, so it's tested without audio.
///
/// Works like Apple Music (D23): shuffling reorders the queue around the current song, the queue's
/// order is always the playing order, and turning shuffle off brings the original order back.
///
/// Auto DJ's songs (C21, D90) are "autoplay" places: always the last upcoming ones, after the user's
/// own, as Apple Music's Autoplay. A place stops being autoplay once it has been reached.
public struct PlayQueue: Sendable, Equatable {
    /// One place in the queue. A song can be queued twice, so places have their own identity.
    struct Entry: Sendable, Equatable {
        let id: UUID
        var song: Song
        /// Added by Auto DJ and not yet reached.
        var isAutoplay: Bool

        init(id: UUID = UUID(), song: Song, isAutoplay: Bool = false) {
            self.id = id
            self.song = song
            self.isAutoplay = isAutoplay
        }
    }

    private var entries: [Entry] = []
    /// The order to return to when shuffle goes off; nil unless this queue has been shuffled.
    private var unshuffled: [Entry]?
    /// The position of the current song, or -1 when there isn't one.
    public private(set) var currentIndex = -1
    /// The shuffle switch. It stays on between lists, so a new list starts shuffled.
    public private(set) var isShuffled: Bool

    public init(isShuffled: Bool = false) {
        self.isShuffled = isShuffled
    }

    public var songs: [Song] { entries.map(\.song) }
    /// Each place in the queue, in `songs`' order. Stays with its song when it moves.
    public var entryIDs: [UUID] { entries.map(\.id) }
    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public var current: Song? { entries.indices.contains(currentIndex) ? entries[currentIndex].song : nil }

    /// The list as it was given, before any shuffling.
    public var originalSongs: [Song] { (unshuffled ?? entries).map(\.song) }
    /// `originalSongs` without Auto DJ's songs not yet reached: the list the user started.
    var ownSongs: [Song] { (unshuffled ?? entries).filter { !$0.isAutoplay }.map(\.song) }

    /// Identifies the place at `index`, so the player can tell whether its queued item is still right.
    func entryID(at index: Int) -> UUID? {
        entries.indices.contains(index) ? entries[index].id : nil
    }

    /// Whether the place at `index` is one of Auto DJ's songs not yet reached (the queue page's
    /// "Autoplay" group). They always come last.
    public func isAutoplay(at index: Int) -> Bool {
        entries.indices.contains(index) && entries[index].isAutoplay
    }

    /// Where Auto DJ's songs start: the first autoplay place, or `count` when there are none.
    public var autoplayStart: Int {
        entries.firstIndex(where: \.isAutoplay) ?? entries.count
    }

    /// How many songs come after the current one.
    public var upcomingCount: Int {
        current == nil ? 0 : entries.count - currentIndex - 1
    }

    // MARK: Starting a list

    /// Replaces the queue. With shuffle on, the song at `startIndex` plays first and the rest are shuffled.
    public mutating func load<G: RandomNumberGenerator>(_ songs: [Song], startIndex: Int = 0, using generator: inout G) {
        guard !songs.isEmpty else {
            clear()
            return
        }
        entries = songs.map { Entry(song: $0) }
        unshuffled = nil
        currentIndex = min(max(startIndex, 0), entries.count - 1)
        if isShuffled { shuffleAroundCurrent(using: &generator) }
    }

    public mutating func load(_ songs: [Song], startIndex: Int = 0) {
        var generator = SystemRandomNumberGenerator()
        load(songs, startIndex: startIndex, using: &generator)
    }

    /// An album's Play button: shuffle off, in order, from the first song.
    public mutating func loadInOrder(_ songs: [Song]) {
        isShuffled = false
        load(songs)
    }

    /// An album's Shuffle button: shuffle on, starting from a random song.
    public mutating func loadShuffled<G: RandomNumberGenerator>(_ songs: [Song], using generator: inout G) {
        isShuffled = true
        let start = songs.isEmpty ? 0 : Int.random(in: 0..<songs.count, using: &generator)
        load(songs, startIndex: start, using: &generator)
    }

    public mutating func loadShuffled(_ songs: [Song]) {
        var generator = SystemRandomNumberGenerator()
        loadShuffled(songs, using: &generator)
    }

    // MARK: Shuffle

    /// The shuffle button. The current song keeps playing either way.
    public mutating func setShuffle<G: RandomNumberGenerator>(_ isOn: Bool, using generator: inout G) {
        guard isOn != isShuffled else { return }
        isShuffled = isOn
        if isOn {
            if current != nil { shuffleAroundCurrent(using: &generator) }
        } else if let unshuffled {
            let currentID = entryID(at: currentIndex)
            entries = unshuffled
            self.unshuffled = nil
            currentIndex = entries.firstIndex { $0.id == currentID } ?? -1
            settleAutoplay()  // Auto DJ's songs stay the group at the end (D90).
        }
    }

    public mutating func setShuffle(_ isOn: Bool) {
        var generator = SystemRandomNumberGenerator()
        setShuffle(isOn, using: &generator)
    }

    private mutating func shuffleAroundCurrent<G: RandomNumberGenerator>(using generator: inout G) {
        guard entries.indices.contains(currentIndex) else { return }
        if unshuffled == nil { unshuffled = entries }
        var rest = entries
        let current = rest.remove(at: currentIndex)
        // Auto DJ's songs stay after the user's, in their order.
        let autoplay = rest.filter(\.isAutoplay)
        rest.removeAll(where: \.isAutoplay)
        rest.shuffle(using: &generator)
        entries = [current] + rest + autoplay
        currentIndex = 0
    }

    // MARK: Moving through the queue

    public mutating func move(to index: Int) {
        guard entries.indices.contains(index) else { return }
        currentIndex = index
        settleAutoplay()
    }

    /// What plays when the current song ends by itself; nil at the end of the queue.
    public func indexAfterEnd(repeat mode: RepeatMode) -> Int? {
        guard current != nil else { return nil }
        return mode == .one ? currentIndex : indexForNext(repeat: mode)
    }

    /// What the Next button goes to; nil at the end of the queue. Repeat One doesn't hold it back.
    public func indexForNext(repeat mode: RepeatMode) -> Int? {
        guard current != nil else { return nil }
        if currentIndex < entries.count - 1 { return currentIndex + 1 }
        return mode == .all ? 0 : nil
    }

    /// What the Previous button goes to; nil at the start of the queue.
    public func indexForPrevious(repeat mode: RepeatMode) -> Int? {
        guard current != nil else { return nil }
        if currentIndex > 0 { return currentIndex - 1 }
        return mode == .all ? entries.count - 1 : nil
    }

    // MARK: Changing the queue

    /// Adds to the end of the user's songs: before Auto DJ's, if there are any (D90). If nothing is
    /// current, the first song becomes current.
    public mutating func append(_ songs: [Song]) {
        let new = songs.map { Entry(song: $0) }
        // Each order puts them before its own first Auto DJ song: a reorder while shuffled moves
        // the group in `entries` only, so the shuffled order's first one can sit later in `unshuffled`.
        entries.insert(contentsOf: new, at: entries.firstIndex(where: \.isAutoplay) ?? entries.count)
        if let order = unshuffled {
            unshuffled!.insert(contentsOf: new, at: order.firstIndex(where: \.isAutoplay) ?? order.count)
        }
        if current == nil, !entries.isEmpty { currentIndex = 0 }
    }

    /// Auto DJ's songs, at the very end (C21).
    public mutating func appendAutoplay(_ songs: [Song]) {
        guard current != nil else { return }
        let new = songs.map { Entry(song: $0, isAutoplay: true) }
        entries += new
        unshuffled? += new
    }

    /// Takes out Auto DJ's songs not yet reached (Auto DJ turned off, D90). Returns how many went.
    @discardableResult
    public mutating func removeAutoplay() -> Int {
        let ids = Set(entries.filter(\.isAutoplay).map(\.id))
        guard !ids.isEmpty else { return 0 }
        entries.removeAll { ids.contains($0.id) }
        unshuffled?.removeAll { ids.contains($0.id) }
        return ids.count
    }

    /// Plays next: straight after the current song, in both the shuffled and the original order.
    public mutating func insertNext(_ song: Song) {
        let entry = Entry(song: song)
        guard current != nil else {
            append([song])
            return
        }
        let currentID = entries[currentIndex].id
        entries.insert(entry, at: currentIndex + 1)
        if let position = unshuffled?.firstIndex(where: { $0.id == currentID }) {
            unshuffled?.insert(entry, at: position + 1)
        }
    }

    /// Removes the song at `index`. Returns true when it was the current one: the song now at
    /// `currentIndex` (the next one, or the new last one) has replaced it.
    @discardableResult
    public mutating func remove(at index: Int) -> Bool {
        guard entries.indices.contains(index) else { return false }
        let removed = entries.remove(at: index)
        unshuffled?.removeAll { $0.id == removed.id }
        if entries.isEmpty {
            unshuffled = nil
            currentIndex = -1
            return true
        }
        if index < currentIndex {
            currentIndex -= 1
            return false
        }
        guard index == currentIndex else { return false }
        currentIndex = min(currentIndex, entries.count - 1)
        settleAutoplay()
        return true
    }

    /// Moves a song. `newIndex` counts positions before the song is taken out, as Flutter's
    /// `ReorderableListView` and SwiftUI's `onMove` both do.
    public mutating func reorder(from oldIndex: Int, to newIndex: Int) {
        guard entries.indices.contains(oldIndex), (0...entries.count).contains(newIndex) else { return }
        let currentID = entryID(at: currentIndex)
        let target = oldIndex < newIndex ? newIndex - 1 : newIndex
        let entry = entries.remove(at: oldIndex)
        entries.insert(entry, at: target)
        if let currentID { currentIndex = entries.firstIndex { $0.id == currentID } ?? currentIndex }
        settleAutoplay()
    }

    /// Keeps Auto DJ's songs a group at the end: the current song and those before it are no longer
    /// autoplay, nor is one moved among the user's songs.
    private mutating func settleAutoplay() {
        guard entries.contains(where: \.isAutoplay) else { return }
        let lastOwn = entries.lastIndex { !$0.isAutoplay } ?? -1
        let settled = max(lastOwn, currentIndex)
        guard settled >= 0 else { return }
        var ids = Set<UUID>()
        for index in 0...min(settled, entries.count - 1) where entries[index].isAutoplay {
            entries[index].isAutoplay = false
            ids.insert(entries[index].id)
        }
        guard !ids.isEmpty, unshuffled != nil else { return }
        for index in unshuffled!.indices where ids.contains(unshuffled![index].id) {
            unshuffled![index].isAutoplay = false
        }
    }

    public mutating func clear() {
        entries = []
        unshuffled = nil
        currentIndex = -1
    }

    /// Changes every queued copy of a song (a new favourite or rating).
    public mutating func updateSongs(id: String, _ change: (inout Song) -> Void) {
        for index in entries.indices where entries[index].song.id == id {
            change(&entries[index].song)
        }
        guard unshuffled != nil else { return }
        for index in unshuffled!.indices where unshuffled![index].song.id == id {
            change(&unshuffled![index].song)
        }
    }
}

// MARK: - Saving

extension PlayQueue {
    /// The queue as it's saved between launches.
    public struct Saved: Codable, Sendable, Equatable {
        public var songs: [Song]
        /// Positions in `songs`, in the original order; nil unless shuffled.
        public var originalOrder: [Int]?
        public var currentIndex: Int
        /// Finds the song again if the index turns out to be wrong (Flutter keeps both too).
        public var currentSongID: String?
        /// Where Auto DJ's songs start in `songs` (C21); nil when there are none. Older saves have none.
        public var autoplayStart: Int?
    }

    public var saved: Saved {
        let originalOrder = unshuffled.map { (original: [Entry]) -> [Int] in
            // One lookup for the whole queue: this runs at every save, and a queue can be a library.
            var positions: [UUID: Int] = [:]
            for (index, entry) in entries.enumerated() where positions[entry.id] == nil {
                positions[entry.id] = index
            }
            return original.compactMap { positions[$0.id] }
        }
        let start = autoplayStart
        return Saved(
            songs: songs,
            originalOrder: originalOrder,
            currentIndex: currentIndex,
            currentSongID: current?.id,
            autoplayStart: start < entries.count ? start : nil
        )
    }

    public init(saved: Saved, isShuffled: Bool) {
        self.init(isShuffled: isShuffled)
        entries = saved.songs.map { Entry(song: $0) }
        guard !entries.isEmpty else { return }
        if let order = saved.originalOrder, order.allSatisfy({ entries.indices.contains($0) }) {
            unshuffled = order.map { entries[$0] }
        }
        var index = min(max(saved.currentIndex, 0), entries.count - 1)
        if entries[index].song.id != saved.currentSongID,
           let found = entries.firstIndex(where: { $0.song.id == saved.currentSongID }) {
            index = found
        }
        currentIndex = index
        if let start = saved.autoplayStart, entries.indices.contains(start) {
            for position in start..<entries.count { entries[position].isAutoplay = true }
            let ids = Set(entries[start...].map(\.id))
            if unshuffled != nil {
                for position in unshuffled!.indices where ids.contains(unshuffled![position].id) {
                    unshuffled![position].isAutoplay = true
                }
            }
            settleAutoplay()
        }
    }
}

extension Song {
    /// Two copies of the same queue list: same songs in the same order.
    static func sameIDs(_ left: [Song], _ right: [Song]) -> Bool {
        left.count == right.count && zip(left, right).allSatisfy { $0.id == $1.id }
    }
}

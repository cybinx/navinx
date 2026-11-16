import Foundation

/// What fetching a song's levels found (C20).
public enum LevelFetch: Sendable, Equatable {
    case levels(Data)
    /// The server has none for this song (it doesn't know it, or couldn't read it).
    case none
    /// Nowhere to ask: signed out or offline, the login refused, or a server without the route (a
    /// direct address answers the music server's own redirect).
    case unavailable
    /// The server failed on this song alone (ffmpeg couldn't read it, Navidrome failed on it):
    /// that song waits `failedRetry`, the others carry on.
    case failed
}

/// The equalizer bars' levels (C20, D89): worked out on the server (`GET /eq/<songId>`, C27), fetched for the
/// current song and the next few in the queue, kept in memory and in Caches, and read at the player's
/// position. Not observable: the bars read it on their own clock, 30 times a second.
///
/// Until a song's levels are here (a skip past the preloaded ones, a server without the route,
/// offline), `sample` returns nil and the bars run their made-up loop; once they
/// arrive, `sample`'s weight rises from 0 to 1 over `blend` seconds, so the loop blends into them.
@MainActor
public final class LevelMeter {
    public typealias Fetch = @MainActor (String) async throws -> LevelFetch

    /// The current song and the next three (D89: "the next few").
    public static let lookahead = 3
    /// How long the loop takes to blend into levels that arrive while a song plays.
    public static let blend: TimeInterval = 0.8
    /// After `.none`, that song isn't asked for again for this long.
    static let missingRetry: TimeInterval = 600
    /// After `.unavailable` or a failed call, nothing is asked for this long.
    static let unavailablePause: TimeInterval = 120
    static let failurePause: TimeInterval = 30
    /// After `.failed`, that song isn't asked for again for this long; the others carry on.
    static let failedRetry: TimeInterval = 300
    /// Songs kept in memory.
    static let memoryLimit = 16
    /// The Levels folder in Caches is trimmed past this, oldest first (about 1,000 songs).
    static let diskLimit = 20 * 1024 * 1024

    private struct Entry {
        let levels: SongLevels
        let readyAt: Date
    }

    private let fetch: Fetch
    private let folder: URL?
    private let now: @MainActor () -> Date
    private var memory: [String: Entry] = [:]
    /// Song IDs in memory, the most recently used last.
    private var recent: [String] = []
    private var retryAfter: [String: Date] = [:]
    private var pausedUntil: Date?
    private var wanted: [String] = []
    private var task: Task<Void, Never>?
    /// Restarts preloading when a pause runs out (nothing else would until the queue changes).
    private var wakeTask: Task<Void, Never>?

    /// - Parameters:
    ///   - folder: where levels are kept between launches; nil keeps them in memory only.
    public init(
        folder: URL? = URL.cachesDirectory.appending(path: "Levels", directoryHint: .isDirectory),
        now: @escaping @MainActor () -> Date = { Date() },
        fetch: @escaping Fetch
    ) {
        self.folder = folder
        self.now = now
        self.fetch = fetch
    }

    /// The songs to have ready, the current one first: one fetch at a time, in that order. A new list
    /// replaces the old; a fetch under way finishes.
    public func preload(_ songIDs: [String]) {
        wanted = songIDs
        guard task == nil else { return }
        task = Task { [weak self] in
            while let self, let songID = self.nextToFetch() {
                await self.load(songID)
            }
            self?.task = nil
            self?.wakeAfterPause()
        }
    }

    /// After an outage's pause, picks up the wanted songs again by itself.
    private func wakeAfterPause() {
        guard wakeTask == nil, let pausedUntil, !wanted.isEmpty else { return }
        // A pause already over has nothing to wake for (`nextToFetch` ends it).
        let remaining = pausedUntil.timeIntervalSince(now())
        guard remaining > 0 else {
            self.pausedUntil = nil
            return
        }
        let delay = max(remaining, 1)
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            wakeTask = nil
            preload(wanted)
        }
    }

    /// Waits for the preloading under way (tests).
    func settle() async {
        while let task { await task.value }
    }

    /// The song's three bands at `seconds`, 0…1, and how far the bars have blended into them (0…1);
    /// nil while the song has none (the bars run their loop).
    public func sample(songID: String, at seconds: TimeInterval, date: Date) -> (levels: SIMD3<Float>, weight: Float)? {
        guard let entry = memory[songID] else { return nil }
        let weight = min(max(date.timeIntervalSince(entry.readyAt) / Self.blend, 0), 1)
        return (entry.levels.levels(at: seconds), Float(weight))
    }

    /// Whether the song's levels are here (tests).
    func hasLevels(_ songID: String) -> Bool { memory[songID] != nil }
    /// Whether an outage's pause is still kept (tests).
    var isPaused: Bool { pausedUntil != nil }

    /// The current song and the next `lookahead` in play order, wrapping with Repeat All.
    public static func songsToPreload(queue: [String], currentIndex: Int, wraps: Bool) -> [String] {
        guard queue.indices.contains(currentIndex) else { return [] }
        var ids = [queue[currentIndex]]
        var index = currentIndex
        for _ in 0..<min(lookahead, queue.count - 1) {
            index += 1
            if index == queue.count {
                guard wraps else { break }
                index = 0
            }
            if !ids.contains(queue[index]) { ids.append(queue[index]) }
        }
        return ids
    }

    // MARK: Fetching

    private func nextToFetch() -> String? {
        let date = now()
        if let pausedUntil {
            if pausedUntil > date { return nil }
            // Over: forgotten, so a finished run doesn't keep scheduling wakes for it.
            self.pausedUntil = nil
        }
        return wanted.first { id in
            memory[id] == nil && (retryAfter[id].map { $0 <= date } ?? true)
        }
    }

    private func load(_ songID: String) async {
        if let data = readFile(songID), let levels = SongLevels(data: data) {
            keep(levels, for: songID)
            return
        }
        do {
            switch try await fetch(songID) {
            case .levels(let data):
                if let levels = SongLevels(data: data) {
                    keep(levels, for: songID)
                    writeFile(data, for: songID)
                } else {
                    retryAfter[songID] = now().addingTimeInterval(Self.missingRetry)
                }
            case .none:
                retryAfter[songID] = now().addingTimeInterval(Self.missingRetry)
            case .unavailable:
                pausedUntil = now().addingTimeInterval(Self.unavailablePause)
            case .failed:
                retryAfter[songID] = now().addingTimeInterval(Self.failedRetry)
            }
        } catch {
            // Unreachable or timed out: everything waits, then picks up again (`wakeAfterPause`).
            pausedUntil = now().addingTimeInterval(Self.failurePause)
        }
    }

    private func keep(_ levels: SongLevels, for songID: String) {
        memory[songID] = Entry(levels: levels, readyAt: now())
        retryAfter[songID] = nil
        recent.removeAll { $0 == songID }
        recent.append(songID)
        while recent.count > Self.memoryLimit, let oldest = recent.first(where: { !wanted.contains($0) }) {
            recent.removeAll { $0 == oldest }
            memory[oldest] = nil
        }
    }

    // MARK: The files

    private func fileURL(_ songID: String) -> URL? {
        guard let folder, !songID.isEmpty, songID.count <= 64,
              songID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        return folder.appending(path: "\(songID).lvl")
    }

    private func readFile(_ songID: String) -> Data? {
        guard let url = fileURL(songID) else { return nil }
        return try? Data(contentsOf: url)
    }

    private func writeFile(_ data: Data, for songID: String) {
        guard let folder, let url = fileURL(songID) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else { return }
        let sized = files.compactMap { file -> (url: URL, date: Date, size: Int)? in
            guard let values = try? file.resourceValues(forKeys: keys) else { return nil }
            return (file, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        var total = sized.reduce(0) { $0 + $1.size }
        for file in sized.sorted(by: { $0.date < $1.date }) where total > Self.diskLimit {
            try? manager.removeItem(at: file.url)
            total -= file.size
        }
    }
}

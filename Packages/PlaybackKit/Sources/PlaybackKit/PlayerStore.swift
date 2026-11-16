import Foundation
import Synchronization

/// The player's saved state: settings in `UserDefaults`, the queue in a file (it can run to a whole
/// library), and the scrobbles still to send, per server.
struct PlayerStore: Sendable {
    /// `UserDefaults` is documented as thread-safe, but isn't marked `Sendable`.
    nonisolated(unsafe) let defaults: UserDefaults
    let queueFile: URL

    /// A scrobble the server hasn't taken yet (Flutter `queueScrobble`).
    struct PendingScrobble: Codable, Sendable, Equatable {
        var songID: String
        var submission: Bool
        /// When it happened, so a play sent later keeps its real time (C10). Older saved ones have none.
        var time: Date?
    }

    /// The queue on disk, with the server it belongs to.
    struct SavedQueue: Codable, Sendable, Equatable {
        var profileID: String
        var queue: PlayQueue.Saved
        var position: TimeInterval
        /// The queue is only the song kept for the mini-player (D81), not something the user queued.
        var isPlaceholder: Bool?
    }

    var volume: Double {
        get { defaults.object(forKey: "player_volume") as? Double ?? 1 }
        nonmutating set { defaults.set(newValue, forKey: "player_volume") }
    }

    var isShuffled: Bool {
        get { defaults.bool(forKey: "player_shuffle") }
        nonmutating set { defaults.set(newValue, forKey: "player_shuffle") }
    }

    var repeatMode: RepeatMode {
        get { RepeatMode(rawValue: defaults.integer(forKey: "player_repeat")) ?? .off }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "player_repeat") }
    }

    var isGaplessEnabled: Bool {
        get { defaults.object(forKey: "player_gapless") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "player_gapless") }
    }

    // MARK: The queue

    /// Counts the clears, and orders the file's writes and clears, so a save asked for before a clear
    /// never lands after it (a signed-out account's queue coming back).
    final class QueueFileGate: Sendable {
        let clears = Mutex(0)
    }

    let gate = QueueFileGate()

    /// How many times the saved queue has been cleared: what `saveQueue` checks against.
    var clearCount: Int { gate.clears.withLock { $0 } }

    func loadQueue() -> SavedQueue? {
        guard let data = try? Data(contentsOf: queueFile) else { return nil }
        return try? JSONDecoder().decode(SavedQueue.self, from: data)
    }

    /// Writes `queue`, unless the saved queue has been cleared since `clearCount` was `clears`.
    @concurrent
    func saveQueue(_ queue: SavedQueue, ifNotClearedSince clears: Int) async {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        let file = queueFile
        gate.clears.withLock { count in
            guard count == clears else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    func clearQueue() {
        let file = queueFile
        gate.clears.withLock { count in
            count += 1
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Scrobbles

    func heldScrobbles(profileID: String) -> [PendingScrobble] {
        guard let data = defaults.data(forKey: pendingKey(profileID)) else { return [] }
        return (try? JSONDecoder().decode([PendingScrobble].self, from: data)) ?? []
    }

    func setHeldScrobbles(_ scrobbles: [PendingScrobble], profileID: String) {
        if scrobbles.isEmpty {
            defaults.removeObject(forKey: pendingKey(profileID))
        } else if let data = try? JSONEncoder().encode(scrobbles) {
            defaults.set(data, forKey: pendingKey(profileID))
        }
    }

    private func pendingKey(_ profileID: String) -> String {
        "player_pending_scrobbles_\(profileID)"
    }
}

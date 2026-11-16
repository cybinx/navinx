import Foundation
import SubsonicKit

/// Resume Across Devices (C36, D143), set in Settings → Playback: the queue and the place in the song
/// are kept on the server (`savePlayQueue`), and a phone with nothing playing takes a newer one
/// (`getPlayQueue`). On by default.
public struct QueueSyncSettings: Sendable, Equatable {
    public static let enabledKey = "queue_sync_enabled"

    public var isEnabled = true

    public init() {}

    public init(defaults: UserDefaults) {
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }
}

/// What a queue holds, to tell two queues apart without comparing them song by song: the songs in
/// order (as a hash), the current one and the place in it. **No time in it:** Navidrome moves its
/// `changed` on every save, even of the same queue, and the save answers nothing, so this phone
/// never learns the server's time of its own save.
struct QueueSnapshot: Codable, Sendable, Equatable {
    var songsHash: String
    var currentID: String?
    var positionMs: Int

    /// How far two places in the same song may be apart and still count as one: a pause's fade-out
    /// moves the place on after the pause has been sent.
    static let positionTolerance = 2000

    init(songIDs: [String], currentID: String?, positionMs: Int) {
        songsHash = Self.hash(songIDs)
        self.currentID = currentID
        self.positionMs = positionMs
    }

    init(_ queue: ServerPlayQueue) {
        self.init(songIDs: queue.songs.map(\.id), currentID: queue.currentID, positionMs: queue.positionMs)
    }

    func matches(_ other: QueueSnapshot) -> Bool {
        songsHash == other.songsHash && currentID == other.currentID
            && abs(positionMs - other.positionMs) <= Self.positionTolerance
    }

    /// 64-bit FNV-1a over the IDs, each ended by a newline: stable between launches, unlike `Hasher`.
    static func hash(_ ids: [String]) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for id in ids {
            for byte in id.utf8 + [10] {
                value ^= UInt64(byte)
                value &*= 0x0000_0100_0000_01b3
            }
        }
        return String(value, radix: 16) + "-\(ids.count)"
    }
}

/// What this phone remembers about the server's queue, per profile, across launches and server switches.
struct QueueSyncRecord: Codable, Sendable, Equatable {
    /// The queue as the server held it after this phone's last save or take that went through.
    var mark: QueueSnapshot?
    /// When this phone's queue last changed without the server having it yet (playing offline, a
    /// save that failed); nil when the server has it.
    var changedHereAt: Date?
    /// The queue `changedHereAt` was noted for, so the same queue saved again (the app leaving the
    /// foreground, or coming back hours later) keeps the time of the change itself (C46, D163). Nil
    /// in a record from before C46.
    var changedSnapshot: QueueSnapshot?

    /// This phone's queue is `snapshot` now. The server holds it: nothing is unsent. A new change:
    /// its time is noted. The same unsent change again: its time stays, since "played most recently"
    /// (D143) is decided by it.
    mutating func note(_ snapshot: QueueSnapshot, at time: Date) {
        if mark?.matches(snapshot) == true {
            clearChange()
        } else if changedHereAt != nil, changedSnapshot?.matches(snapshot) ?? true {
            changedSnapshot = changedSnapshot ?? snapshot
        } else {
            changedHereAt = time
            changedSnapshot = snapshot
        }
    }

    /// The server has this phone's queue.
    mutating func clearChange() {
        changedHereAt = nil
        changedSnapshot = nil
    }
}

/// Taking or keeping (C36, D143). Pure, so its cases are tested without a player.
enum QueueSyncDecision: Sendable, Equatable {
    /// Nothing to do.
    case nothing
    /// The phone and the server hold the same queue: only the mark is brought up to date.
    case inSync
    /// The server's queue replaces this phone's, paused at its place; `announces` shows the toast
    /// (not when the queue is this phone's own coming back, after a server switch say).
    case take(announces: Bool)
    /// This phone's queue is the newer: it's sent.
    case send

    /// - Parameters:
    ///   - server: the server's queue and its time; nil when none is saved.
    ///   - local: this phone's queue; nil when it's empty or only the kept song (D81).
    static func decide(server: (snapshot: QueueSnapshot, changed: Date?)?, local: QueueSnapshot?, record: QueueSyncRecord) -> Self {
        guard let server else {
            // Nothing saved yet (or cleared by another app): this phone's goes up if it has one the
            // server never had.
            return local != nil && (record.changedHereAt != nil || record.mark == nil) ? .send : .nothing
        }
        // An empty phone (a first sign-in, a reinstall, a server switched away and back) always takes it.
        guard let local else {
            return .take(announces: !(record.mark?.matches(server.snapshot) ?? false))
        }
        if local.matches(server.snapshot) { return .inSync }
        // The server still holds what this phone last left there: this phone's is newer.
        if record.mark?.matches(server.snapshot) == true { return .send }
        // The server has moved on. No record at all is the first run with the feature: this phone's
        // own queue isn't swapped for another app's.
        guard record.mark != nil else { return .send }
        // Changed only elsewhere: taken.
        guard let here = record.changedHereAt else { return .take(announces: true) }
        // Changed on both: the one played most recently wins (D143), by each side's clock.
        if let changed = server.changed, changed > here { return .take(announces: true) }
        return .send
    }
}

extension PlayerStore {
    func queueSyncRecord(profileID: String) -> QueueSyncRecord {
        guard let data = defaults.data(forKey: queueSyncKey(profileID)) else { return QueueSyncRecord() }
        return (try? JSONDecoder().decode(QueueSyncRecord.self, from: data)) ?? QueueSyncRecord()
    }

    func setQueueSyncRecord(_ record: QueueSyncRecord, profileID: String) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: queueSyncKey(profileID))
    }

    private func queueSyncKey(_ profileID: String) -> String {
        "player_server_queue_\(profileID)"
    }
}

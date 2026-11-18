import Foundation

/// The player's fallback when a song fails for a network reason anyway (C68, D225): a stream that can't be
/// picked up where it broke (a transcoded one, sent whole), or a feed whose tries ran out. The song is
/// loaded again where it stopped once the network is back, and plays, as it was playing. Flutter stayed
/// stopped (an approved difference).
///
/// Only the decisions live here; `PlayerModel` waits, reloads and calls it off (Pause, a skip, another
/// song, Stop, a sign-out or another server).
struct StreamRecovery {
    struct Plan: Equatable {
        /// The queue place that failed.
        let entry: UUID
        let position: TimeInterval
        let failedAt: Date
    }

    /// Reloads of one queue place before it stays stopped as before C68.
    static let attemptLimit = 3
    /// How long after the failure the network may take to come back (seconds): later, it stays stopped.
    static let waitLimit: TimeInterval = 300
    /// Song-seconds a reloaded song plays before its reloads are counted afresh: a later drop in the same
    /// song (another tunnel on the drive) gets its own.
    static let playedToForgive: TimeInterval = 30

    /// The reload waiting for the network.
    private(set) var plan: Plan?
    /// The queue place the reloads are counted for, and how many it has had.
    private var entry: UUID?
    private var attempts = 0
    /// Where the last reload started, until `playedToForgive` later.
    private var reloadedAt: TimeInterval?

    var isWaiting: Bool { plan != nil }

    /// The current song failed: true when it's to be loaded again later (a network reason, it was
    /// playing, and it has reloads left).
    mutating func failed(entry: UUID, at position: TimeInterval, wasPlaying: Bool, isNetwork: Bool, now: Date) -> Bool {
        plan = nil
        guard isNetwork, wasPlaying else { return false }
        if self.entry != entry {
            self.entry = entry
            attempts = 0
            reloadedAt = nil
        }
        guard attempts < Self.attemptLimit else { return false }
        plan = Plan(entry: entry, position: position, failedAt: now)
        return true
    }

    /// The reload to make now, counted; nil when it's given up (too late, or another song is current).
    mutating func attempt(current: UUID?, now: Date) -> Plan? {
        defer { plan = nil }
        guard let plan, plan.entry == current, now.timeIntervalSince(plan.failedAt) <= Self.waitLimit else { return nil }
        attempts += 1
        reloadedAt = plan.position
        return plan
    }

    mutating func callOff() {
        plan = nil
    }

    /// The current song has played to `position`.
    mutating func played(_ entry: UUID?, to position: TimeInterval) {
        guard let reloadedAt, entry == self.entry, position - reloadedAt >= Self.playedToForgive else { return }
        attempts = 0
        self.reloadedAt = nil
    }
}

import Foundation

/// What the engine tells the player.
public enum AudioEngineEvent: Sendable, Equatable {
    case position(TimeInterval)
    case duration(TimeInterval)
    /// Whether it's playing or trying to. False means it stopped, perhaps by the system's doing.
    case playing(Bool)
    case buffering(Bool)
    /// The queued next item has taken over, by itself or through `advanceToNext`.
    case advanced
    /// The last item finished, with nothing queued after it.
    case ended
    case failed(String)
}

/// How the next song overlaps the current one's end (C19, D88).
public struct Crossfade: Sendable, Equatable {
    /// Wall-clock seconds the two songs sound together. It starts `length × speed` song-seconds
    /// before the current song's end, so it lasts as long at any speed (D94).
    public var length: TimeInterval
    /// The current song's listed length, for when its audio doesn't say.
    public var listedDuration: TimeInterval

    public init(length: TimeInterval, listedDuration: TimeInterval) {
        self.length = length
        self.listedDuration = listedDuration
    }
}

/// The audio itself, behind a protocol so the player's logic is tested without sound.
///
/// It holds at most two items: the current one, and the next one, for a gapless change or (with a
/// `Crossfade`) an overlap.
@MainActor
public protocol AudioEngine: AnyObject {
    var onEvent: (@MainActor (AudioEngineEvent) -> Void)? { get set }
    /// True when an item is loaded, so `play` has something to play.
    var hasItem: Bool { get }
    var volume: Float { get set }

    /// Replaces everything with `url`, starting at `start` seconds, paused.
    func load(_ url: URL, start: TimeInterval, next: URL?)
    /// Replaces the queued next item. With a `crossfade`, the next song starts before the current one
    /// ends and the two overlap, reporting `.advanced` as the overlap starts; with none, the change is
    /// gapless. A single `QueuePlayerEngine` can't overlap and always changes gaplessly; `CrossfadeEngine`
    /// (two of them) can.
    func setNext(_ url: URL?, crossfade: Crossfade?)
    /// Moves to the queued next item at once. It reports `.advanced` before returning.
    func advanceToNext()
    /// Plays, the volume rising from silence over `fadeIn` seconds (0: at once). A single
    /// `QueuePlayerEngine` doesn't fade; `CrossfadeEngine` does.
    func play(fadeIn: TimeInterval)
    /// Pauses, the volume falling over `fadeOut` seconds first (0: at once). While it falls the engine
    /// reports nothing playing, so the player shows paused at once.
    func pause(fadeOut: TimeInterval)
    /// Stops and unloads everything.
    func stop()
    func seek(to seconds: TimeInterval)
    /// Playback speed (1 is normal) and whether the pitch stays where it is (a time-stretch) or
    /// follows the speed (like a record played faster). Kept across `load` and the next items, and
    /// never starts a paused player. Every engine (a second player for crossfade, C19) takes it.
    func setRate(_ rate: Float, preservesPitch: Bool)
    /// Where the current song is now, in song-seconds, read from the player's own clock between its
    /// 4 Hz `.position` ticks (for the equalizer bars, C20). Nil when the engine can't say.
    var currentTime: TimeInterval? { get }
    /// The system's media services restarted, which kills every player: builds new ones, keeping the
    /// volume and speed, with nothing loaded (as after `stop`).
    func resetMediaServices()
}

extension AudioEngine {
    public var currentTime: TimeInterval? { nil }
    /// An engine with nothing of the system's to rebuild only stops.
    public func resetMediaServices() { stop() }
    /// A gapless next item, or none.
    public func setNext(_ url: URL?) { setNext(url, crossfade: nil) }
    public func play() { play(fadeIn: 0) }
    public func pause() { pause(fadeOut: 0) }
}

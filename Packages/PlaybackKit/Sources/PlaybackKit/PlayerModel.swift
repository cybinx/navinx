import Foundation
import Observation
import SubsonicKit

/// How a song stopped being the current one.
public enum ListenEnd: Sendable, Equatable {
    /// It played to its end.
    case ended
    /// The Next button.
    case next
    /// Anything else: another song or list, Previous, removing it, stopping.
    case replaced
}

/// What the recommendation engine learns from (D33).
public enum ListenEvent: Sendable, Equatable {
    /// The song has started making sound.
    case started(Song)
    /// The song has gone, after `played` seconds of actually playing.
    case finished(Song, played: TimeInterval, duration: TimeInterval, end: ListenEnd)
    case starred(Song, Bool)
    case rated(Song, Int)
}

/// The sleep timer's setting (Flutter's ⋯ menu).
public enum SleepTimerChoice: Sendable, Hashable {
    case off
    case minutes(Int)
    /// Stops when the current song plays to its end.
    case whenSongEnds
}

/// The player: Flutter `PlayerProvider`, for this phone's own audio. Radio stations were dropped
/// (D119); Cast, UPnP and jukebox were closed with nothing built (D93).
@Observable
@MainActor
public final class PlayerModel {
    public private(set) var playQueue: PlayQueue
    public private(set) var isPlaying = false
    /// Waiting for audio: a new song loading, or the network falling behind.
    public private(set) var isLoading = false
    /// Seconds.
    public private(set) var position: TimeInterval = 0
    /// Seconds: the song's listed length until the audio says otherwise.
    public private(set) var duration: TimeInterval = 0
    public private(set) var repeatMode: RepeatMode
    public private(set) var volume: Double
    public private(set) var volumeBeforeMute: Double
    public private(set) var isGaplessEnabled: Bool
    /// Songs like the last ones keep being added (Flutter `isRadioQueue`). It ends when another
    /// list starts (D34); Flutter's stayed on until the app restarted.
    public private(set) var queueIsStation = false
    public private(set) var sleepTimerChoice = SleepTimerChoice.off
    /// When a timed sleep timer runs out.
    public private(set) var sleepTimerDeadline: Date?
    /// One of `speedChoices`: the whole player's, so it carries over song changes and new lists. Not
    /// kept: every launch starts at 1× with the pitch kept, as Flutter (D87).
    public private(set) var playbackSpeed: Double = 1
    /// Flutter's "Preserve pitch": on, the speed changes without the pitch; off, the pitch follows it.
    public private(set) var preservesPitch = true
    /// Auto DJ (C21, D90): what's added, under "Autoplay", when two songs or fewer are left. A setting
    /// (Settings → Playback, and the queue's ∞ button), so a new list keeps it.
    public private(set) var refillSource: RefillSource
    public var isRefillOn: Bool { refillSource != .off }

    /// The now-playing menu's speeds (Flutter's slider: 0.5 to 2 in seven steps).
    public static let speedChoices: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    public var queue: [Song] { playQueue.songs }
    public var currentIndex: Int { playQueue.currentIndex }
    public var currentSong: Song? { playQueue.current }
    public var isShuffled: Bool { playQueue.isShuffled }
    public var hasNext: Bool { playQueue.indexForNext(repeat: repeatMode) != nil }
    public var hasPrevious: Bool { playQueue.indexForPrevious(repeat: repeatMode) != nil }

    /// Where the current song is now, in song-seconds: the engine's own clock where it has one,
    /// else the last `position` (for the equalizer bars, C20; it follows seeks and the speed).
    public var playbackTime: TimeInterval { engine.currentTime ?? position }

    /// Flutter `progress`: how far through the song, from 0 to 1.
    public var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    /// Called when what the lock screen shows has changed.
    @ObservationIgnored public var onNowPlayingChange: (@MainActor () -> Void)?
    /// Called before audio starts, to make the audio session active.
    @ObservationIgnored public var activateSession: (@MainActor () -> Void)?
    /// Called with what the recommendation engine learns from.
    @ObservationIgnored public var onListen: (@MainActor (ListenEvent) -> Void)?
    /// A downloaded song's file (C10), played before the server's stream, with no transcoding.
    @ObservationIgnored public var localFile: (@MainActor (Song) -> URL?)?
    /// Whether the phone is on mobile data now, which picks Mobile Quality over Wi-Fi Quality (C11).
    /// The app hands in its `NetworkMonitor`; tests hand in what they like.
    @ObservationIgnored public var isOnMobileData: @MainActor () -> Bool = { false }
    /// The downloaded songs (C10), for the last resort of `seedIfEmpty`: a song to show when the server
    /// can't be asked. The app hands in the downloads' list.
    @ObservationIgnored public var offlineSongs: @MainActor () -> [Song] = { [] }
    /// The listener's favourite genres, most liked first (the recommendation engine's), for Auto DJ's
    /// Smart Mix. The app hands in its `RecommendationModel`'s.
    @ObservationIgnored public var favouriteGenres: @MainActor (Int) -> [String] = { _ in [] }
    /// Called when a queue saved by another device has been taken (C36): the app shows its toast.
    @ObservationIgnored public var onQueueTaken: (@MainActor () -> Void)?

    @ObservationIgnored private let engine: any AudioEngine
    @ObservationIgnored private let store: PlayerStore
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var client: SubsonicClient?
    @ObservationIgnored private var profileID: String?
    @ObservationIgnored private var tracker = ScrobbleTracker()
    /// Whether the server has been told the current song is playing.
    @ObservationIgnored private var hasAnnounced = false
    @ObservationIgnored private var isBuffering = false
    /// The queue place the engine has lined up next, so an unchanged one keeps what it has buffered.
    @ObservationIgnored private var queuedNextID: UUID?
    /// Its address, meaningful only while `queuedNextID` is set.
    @ObservationIgnored private var queuedNextURL: URL?
    /// How it's lined up: nil for a gapless change, else the overlap (C19).
    @ObservationIgnored private var queuedCrossfade: Crossfade?
    /// The engine's song failed and it still holds it: Play loads it again rather than playing a dead item.
    @ObservationIgnored private var hasFailed = false
    @ObservationIgnored private var resumesAfterInterruption = false
    @ObservationIgnored private var pausedByUser = false
    /// When the audio last stopped without being asked to. iOS can pause the player just before it
    /// announces an interruption, which must still count as "was playing".
    @ObservationIgnored private var systemPausedAt: Date?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// The radio fetch under way.
    @ObservationIgnored private var radioTask: Task<Void, Never>?
    /// Auto DJ's fetch under way.
    @ObservationIgnored private var refillTask: Task<Void, Never>?
    /// Moves on when a new list starts, the queue is cleared or the server changes, so what an old
    /// fetch finds is dropped.
    @ObservationIgnored private var refillGeneration = 0
    /// The last songs Auto DJ added (Flutter kept 100 for the app's life; here 20, cleared with the server).
    @ObservationIgnored private var recentRefills: [String] = []
    /// Counts songs loaded into the engine, so a wait at the queue's end can tell one was started meanwhile.
    @ObservationIgnored private var startCount = 0
    /// The wait at the queue's end for radio's or Auto DJ's songs (`endOfQueue`). Stop, or anything
    /// else starting, calls it off.
    @ObservationIgnored private var endWait: Task<Void, Never>?
    /// The Next button has asked the engine to move on, and it hasn't said so yet.
    @ObservationIgnored private var isSkippingToNext = false
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    /// The look for a song to show when nothing is queued (`seedIfEmpty`).
    @ObservationIgnored private var seedTask: Task<Void, Never>?
    /// The queue is one song kept so the mini-player has something (D81), not a list the user made:
    /// queueing songs replaces it, as with an empty queue, and playing it makes it the user's.
    @ObservationIgnored private var isPlaceholder = false
    /// The look at the server's saved queue under way (C36, `checkServerQueue`).
    @ObservationIgnored private var serverCheckTask: Task<Void, Never>?
    /// The wait before the queue goes to the server, so a burst of changes sends once.
    @ObservationIgnored private var serverSaveTask: Task<Void, Never>?
    /// A save to the server is on its way; another asked meanwhile goes after it (`sendsAgain`).
    @ObservationIgnored private var isSendingQueue = false
    @ObservationIgnored private var sendsAgain = false
    /// When the queue last went to the server (or was last looked at for it), for the 30 s while playing.
    @ObservationIgnored private var lastServerSave: Date?
    /// What this run has changed on songs that the app's lists still hold old copies of.
    private var songEdits: [String: SongEdit] = [:]

    private struct SongEdit {
        var starred: Bool?
        var userRating: Int?
    }

    /// Now playing's star taps on one song still being written (C22): they go to the server one
    /// after another, and only the newest tap is written or changed back.
    private struct RatingWrites {
        /// The last write started, waited on by the next tap's.
        var tail: Task<Void, Never>?
        /// Counts the taps, so a write can tell a newer tap has come.
        var newest = 0
        /// The rating the server last took, what a failure goes back to.
        var confirmed: Int?
    }

    @ObservationIgnored private var ratingWrites: [String: RatingWrites] = [:]

    /// Now playing's heart taps on one song still being written, ordered as the star taps are.
    private struct FavoriteWrites {
        var tail: Task<Void, Never>?
        var newest = 0
        /// What the server last took, what a failure goes back to.
        var confirmed: Bool
    }

    @ObservationIgnored private var favoriteWrites: [String: FavoriteWrites] = [:]

    /// - Parameters:
    ///   - queueFile: where the queue is saved. Defaults to the app's Application Support folder.
    ///   - now: the clock for play-count timing.
    public init(
        engine: (any AudioEngine)? = nil,
        defaults: UserDefaults = .standard,
        queueFile: URL? = nil,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.engine = engine ?? CrossfadeEngine()
        let store = PlayerStore(
            defaults: defaults,
            queueFile: queueFile ?? URL.applicationSupportDirectory.appending(path: "PlayerQueue.json")
        )
        self.store = store
        self.now = now
        playQueue = PlayQueue(isShuffled: store.isShuffled)
        repeatMode = store.repeatMode
        volume = store.volume
        volumeBeforeMute = store.volume > 0 ? store.volume : 1
        isGaplessEnabled = store.isGaplessEnabled
        refillSource = RefillSettings(defaults: store.defaults).mode
        self.engine.onEvent = { [weak self] event in self?.handle(event) }
        self.engine.setRate(1, preservesPitch: true)
    }

    // MARK: Accounts

    /// A server is signed in. Brings back that server's saved queue the first time, paused where it
    /// was (Flutter `_restoreQueueState`), and sends any scrobbles still waiting. `checksServerQueue`
    /// false (a Siri or Shortcuts request with no window, D156): no look at another device's queue.
    public func connect(client: SubsonicClient, profileID: String, checksServerQueue: Bool = true) {
        self.client = client
        if self.profileID != profileID {
            self.profileID = profileID
            recentRefills = []
            restoreQueue(profileID: profileID)
        } else {
            // The same server on another address (home, away): the song lined up next is lined up
            // again from the new one, or it fails when the current one ends. The current song carries
            // on, and an unchanged address keeps what's buffered (`refreshTranscoding`).
            refreshTranscoding()
        }
        // Nothing saved for this server (or a look for a song that failed while offline): the player
        // is never left without a song (D81).
        seedIfEmpty()
        sendHeldScrobbles()
        // Another device's newer queue (C36); it replaces the kept song if that lands first.
        if checksServerQueue { checkServerQueue() }
    }

    /// Offline mode (C10): no server, so only downloaded songs play. Brings back that server's saved
    /// queue the first time, as `connect` does, and keeps plays to send once the server is back.
    public func connectOffline(profileID: String) {
        client = nil
        if self.profileID != profileID {
            self.profileID = profileID
            restoreQueue(profileID: profileID)
        }
        seedIfEmpty()
        // A song lined up next from the server can't play now: lined up again from its file, or not
        // at all (the audit's P5).
        refreshTranscoding()
    }

    /// Flutter `resetForServerSwitch`: playback stops and the queue goes.
    public func reset() {
        seedTask?.cancel()
        seedTask = nil
        // A save already sent finishes for its own server; the mark stays with that profile (C36).
        serverCheckTask?.cancel()
        serverCheckTask = nil
        serverSaveTask?.cancel()
        serverSaveTask = nil
        sendsAgain = false
        lastServerSave = nil
        retireCurrent()
        endRadio()
        dropRefillFetch()
        callOffEndWait()
        recentRefills = []
        clearSleepTimer()
        songEdits = [:]
        ratingWrites = [:]
        favoriteWrites = [:]
        engine.stop()
        saveTask?.cancel()
        // A flush under way keeps what fails for its own server; the next sign-in flushes its own.
        flushTask?.cancel()
        flushTask = nil
        store.clearQueue()
        playQueue.clear()
        isPlaceholder = false
        client = nil
        profileID = nil
        queuedNextID = nil
        queuedCrossfade = nil
        isPlaying = false
        isLoading = false
        isBuffering = false
        position = 0
        duration = 0
        resumesAfterInterruption = false
        pausedByUser = false
        onNowPlayingChange?()
    }

    // MARK: Starting something

    /// Flutter `playSong`. The current song, tapped in the same list, carries on rather than
    /// restarting. With no `playlist`, a song already queued is moved to; any other replaces the queue.
    public func playSong(
        _ song: Song,
        playlist: [Song]? = nil,
        startIndex: Int? = nil,
        initialPosition: TimeInterval = 0
    ) {
        // Against the user's own songs: Auto DJ's tail isn't on the page tapped.
        let isSameList = playlist.map { Song.sameIDs($0, playQueue.ownSongs) } ?? true
        if currentSong?.id == song.id, isSameList {
            if initialPosition > 0 { seek(to: initialPosition) }
            if !isPlaying { play() }
            return
        }
        retireCurrent()
        if let playlist {
            endRadio()
            dropRefillFetch()
            playQueue.load(playlist, startIndex: startIndex ?? playlist.firstIndex { $0.id == song.id } ?? 0)
        } else if let index = startIndex ?? queue.firstIndex(where: { $0.id == song.id }) {
            playQueue.move(to: index)
        } else {
            dropRefillFetch()
            playQueue.load([song])
        }
        startCurrent(autoplay: true, at: initialPosition)
        sendHeldScrobbles()
    }

    /// Flutter `playSongWithRadio` (a song tapped in Search): plays it, then keeps adding songs like it.
    public func playAsStation(_ song: Song) {
        endRadio()
        playSong(song)
        queueIsStation = true
        // The radio keeps its own refill (D90).
        dropRefillFetch()
        fetchRadioSongs(seed: song)
    }

    /// An album's Play button (D23): shuffle off, from the first song, even if it's already playing.
    public func playInOrder(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        retireCurrent()
        endRadio()
        dropRefillFetch()
        playQueue.loadInOrder(songs)
        store.isShuffled = false
        startCurrent(autoplay: true)
        sendHeldScrobbles()
    }

    /// An album's Shuffle button (D23): shuffle on, from a random song.
    public func playShuffled(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        retireCurrent()
        endRadio()
        dropRefillFetch()
        playQueue.loadShuffled(songs)
        store.isShuffled = true
        startCurrent(autoplay: true)
        sendHeldScrobbles()
    }

    // MARK: Transport

    /// Play, from any source (the button, the lock screen, a headphone button), with the fade-in if
    /// it's on (C19).
    public func play() {
        play(fadeIn: FadeSettings(defaults: store.defaults).length)
    }

    private func play(fadeIn: TimeInterval) {
        pausedByUser = false
        resumesAfterInterruption = false
        guard currentSong != nil else { return }
        // Waiting at the queue's end for more songs: what comes plays, and the song that ended stays done.
        if endWait != nil {
            isPlaying = true
            onNowPlayingChange?()
            return
        }
        // Nothing loaded (a restored song), or a song that failed: loaded where it was. A failed
        // song carries on its play count and what the server was told.
        guard engine.hasItem, !hasFailed else {
            startCurrent(autoplay: true, at: position, fadeIn: fadeIn, keepsListen: hasFailed)
            return
        }
        activateSession?()
        isPlaying = true
        engine.play(fadeIn: fadeIn)
        syncTracker()
        onNowPlayingChange?()
    }

    /// Pause, from any source, with the fade-out if it's on (C19): the player shows paused at once
    /// and the sound follows.
    public func pause() {
        pausedByUser = true
        resumesAfterInterruption = false
        isPlaying = false
        engine.pause(fadeOut: FadeSettings(defaults: store.defaults).length)
        syncTracker()
        scheduleSave()
        onNowPlayingChange?()
    }

    public func playOrPause() {
        isPlaying ? pause() : play()
    }

    /// Flutter `stop` (the lock screen's stop command): keeps the queue, back to the song's start.
    public func stop() {
        retireCurrent()
        callOffEndWait()
        engine.stop()
        isPlaying = false
        isLoading = false
        isBuffering = false
        position = 0
        queuedNextID = nil
        queuedCrossfade = nil
        // Stopped by the user: an interruption that ends later doesn't start it again (the audit's P3).
        resumesAfterInterruption = false
        systemPausedAt = nil
        if let song = currentSong { tracker.begin(songID: song.id) }
        hasAnnounced = false
        scheduleSave()
        onNowPlayingChange?()
    }

    public func seek(to seconds: TimeInterval) {
        position = max(seconds, 0)
        engine.seek(to: position)
        // Saved as a pause is (after the last of several seeks), so a seek made while paused isn't
        // lost if the app is closed before it goes to the background.
        scheduleSave()
        onNowPlayingChange?()
    }

    /// Flutter `seekToProgress`.
    public func seek(toProgress progress: Double) {
        seek(to: progress * duration)
    }

    /// The Next button. Keeps a paused player paused. Past the last song, the queue ends (D25).
    public func skipNext() {
        guard currentSong != nil else { return }
        guard let index = playQueue.indexForNext(repeat: repeatMode) else {
            retireCurrent(.next)
            // The song is done with, as if it had ended: it isn't heard while radio's or Auto DJ's
            // songs are fetched (`endOfQueue` waits for them), and a queue that ends stops anyway.
            engine.stop()
            queuedNextID = nil
            queuedCrossfade = nil
            endOfQueue()
            return
        }
        if queuedNextID != nil, queuedCrossfade == nil, playQueue.entryID(at: index) == queuedNextID, index != currentIndex {
            // Already queued gaplessly: the same change as a song ending, and just as quick. A song
            // lined up to crossfade is started afresh: Next never crossfades (D88).
            isSkippingToNext = true
            engine.advanceToNext()
            // The engine reports the change before returning, or not at all: the flag is only for
            // that. Still set, the engine had nothing lined up after all, so the song is started afresh.
            let movedNothing = isSkippingToNext
            isSkippingToNext = false
            if movedNothing {
                retireCurrent(.next)
                go(to: index, autoplay: isPlaying)
            }
        } else {
            retireCurrent(.next)
            go(to: index, autoplay: isPlaying)
        }
    }

    /// The Previous button: back to the song's start after 3 seconds, else the song before.
    public func skipPrevious() {
        guard currentSong != nil else { return }
        guard position <= 3, let index = playQueue.indexForPrevious(repeat: repeatMode), index != currentIndex else {
            seek(to: 0)
            return
        }
        go(to: index, autoplay: isPlaying)
    }

    /// Flutter `skipToIndex` (the queue page). It starts playing, as a tap in the queue should.
    public func skip(toIndex index: Int) {
        guard playQueue.songs.indices.contains(index) else { return }
        go(to: index, autoplay: true)
    }

    /// The shuffle button. The current song carries on playing either way.
    public func toggleShuffle(forceValue: Bool? = nil) {
        playQueue.setShuffle(forceValue ?? !isShuffled)
        store.isShuffled = playQueue.isShuffled
        refreshNext()
        scheduleSave()
        // The system's shuffle and repeat buttons show the player's (CarPlay, the lock screen).
        onNowPlayingChange?()
    }

    public func toggleRepeat() {
        changeRepeat(repeatMode.next)
    }

    public func changeRepeat(_ mode: RepeatMode) {
        repeatMode = mode
        store.repeatMode = mode
        refreshNext()
        // Auto DJ waits while Repeat is on (D90).
        refillIfNeeded()
        onNowPlayingChange?()
    }

    /// Flutter `toggleGaplessPlayback` (C11's setting). Off: songs change only once one has ended.
    public func toggleGapless() {
        isGaplessEnabled.toggle()
        store.isGaplessEnabled = isGaplessEnabled
        refreshNext()
    }

    // MARK: Changing the queue

    /// Adds to the end of the queue. With nothing playing, it starts playing.
    public func queueUp(_ song: Song) {
        queueUpAll([song])
    }

    public func queueUpAll(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        let wasEmpty = currentSong == nil || isPlaceholder
        if isPlaceholder { dropPlaceholder() }
        playQueue.append(songs)
        if wasEmpty {
            startCurrent(autoplay: true)
        } else {
            refreshNext()
            scheduleSave()
        }
    }

    /// Plays straight after the current song. With nothing playing, it starts playing.
    public func queueUpNext(_ song: Song) {
        let wasEmpty = currentSong == nil || isPlaceholder
        if isPlaceholder { dropPlaceholder() }
        playQueue.insertNext(song)
        if wasEmpty {
            startCurrent(autoplay: true)
        } else {
            refreshNext()
            scheduleSave()
        }
    }

    /// Flutter `removeFromQueue`: removing the current song plays the one that takes its place.
    /// Removing the last song left clears everything; here it stops the song and keeps it loaded (D81).
    public func dropFromQueue(at index: Int) {
        guard playQueue.songs.indices.contains(index) else { return }
        guard playQueue.count > 1 else {
            clearQueue()
            return
        }
        let isCurrent = index == currentIndex
        if isCurrent { retireCurrent() }
        playQueue.remove(at: index)
        if isCurrent {
            startCurrent(autoplay: isPlaying)
        } else {
            refreshNext()
            scheduleSave()
        }
    }

    public func reorderQueue(from oldIndex: Int, to newIndex: Int) {
        playQueue.reorder(from: oldIndex, to: newIndex)
        refreshNext()
        scheduleSave()
    }

    /// Stops and empties the queue, except the current song, which stays loaded and paused so the
    /// mini-player never goes (D81; Flutter's emptied the player). With nothing loaded there's nothing to keep.
    public func clearQueue() {
        retireCurrent()
        endRadio()
        dropRefillFetch()
        callOffEndWait()
        engine.stop()
        saveTask?.cancel()
        queuedNextID = nil
        queuedCrossfade = nil
        isPlaying = false
        isLoading = false
        isBuffering = false
        if let song = currentSong {
            playQueue.load([song], startIndex: 0)
            isPlaceholder = true
            adoptCurrent()
        } else {
            store.clearQueue()
            playQueue.clear()
            position = 0
            duration = 0
        }
        onNowPlayingChange?()
    }

    // MARK: Speed and pitch

    /// Auto DJ's mode (Settings → Playback). Off takes out the Autoplay songs not yet reached, as
    /// Apple Music (D90); on, songs are added straight away if the queue is running out.
    public func setRefillSource(_ mode: RefillSource) {
        guard mode != refillSource else { return }
        refillSource = mode
        store.defaults.set(mode.rawValue, forKey: RefillSettings.modeKey)
        refillTask?.cancel()
        refillTask = nil
        if mode == .off {
            if playQueue.removeAutoplay() > 0 {
                refreshNext()
                scheduleSave()
            }
        } else {
            store.defaults.set(mode.rawValue, forKey: RefillSettings.lastModeKey)
            refillIfNeeded()
        }
    }

    /// The queue's ∞ button: off, or back to the last mode chosen (Similar Songs the first time).
    public func toggleRefill() {
        setRefillSource(isRefillOn ? .off : RefillSettings(defaults: store.defaults).lastMode)
    }

    /// Flutter `setPlaybackSpeed`, held to 0.5–2. A paused song stays paused.
    public func changeSpeed(_ speed: Double) {
        let speed = min(max(speed, 0.5), 2)
        guard speed != playbackSpeed else { return }
        // What has played so far counts at the old speed (play counts follow song time, D87).
        tracker.pause(at: now())
        playbackSpeed = speed
        applyRate()
        // A crossfade is capped by the songs' lengths in wall time.
        refreshNext()
        syncTracker()
        onNowPlayingChange?()
    }

    /// Flutter `togglePitchCorrection`.
    public func setPreservesPitch(_ preserves: Bool) {
        guard preserves != preservesPitch else { return }
        preservesPitch = preserves
        applyRate()
    }

    private func applyRate() {
        engine.setRate(Float(playbackSpeed), preservesPitch: preservesPitch)
    }

    // MARK: Volume

    public func setVolume(_ value: Double) {
        volume = min(max(value, 0), 1)
        if volume > 0 { volumeBeforeMute = volume }
        store.volume = volume
        applyVolume()
    }

    public func toggleMute() {
        setVolume(volume > 0 ? 0 : volumeBeforeMute)
    }

    /// Flutter `refreshReplayGain`: Settings calls this after changing ReplayGain's settings, which
    /// apply at once (Flutter's waited for the next song).
    public func reapplyReplayGain() {
        applyVolume()
    }

    /// The streaming quality changed (a setting, or Wi-Fi vs mobile data). The current song carries
    /// on as it is, as in Flutter; the next one lined up is lined up again with the new address.
    public func refreshTranscoding() {
        guard engine.hasItem else { return }
        let next = nextPlace()
        // The app calls this on every network change: an unchanged address keeps what's buffered,
        // and a crossfade's preloaded song.
        if next?.id == queuedNextID, next?.crossfade == queuedCrossfade,
           next == nil || Self.sameStream(next?.url, queuedNextURL) { return }
        lineUp(next)
    }

    /// Whether two addresses are the same stream: each has its own login salt and token.
    private static func sameStream(_ left: URL?, _ right: URL?) -> Bool {
        func withoutLogin(_ url: URL?) -> URLComponents? {
            guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            components.queryItems = components.queryItems?.filter { $0.name != "t" && $0.name != "s" }
            return components
        }
        guard let left = withoutLogin(left) else { return false }
        return left == withoutLogin(right)
    }

    /// Settings changed the crossfade's length (C19): the next change uses it.
    public func refreshCrossfade() {
        refreshNext()
    }

    // MARK: The sleep timer

    /// Flutter `setSleepTimer`, without its fade, which nothing in Flutter's menu turns on. A new
    /// choice replaces the old one.
    public func armSleepTimer(_ choice: SleepTimerChoice) {
        if case .minutes(let minutes) = choice {
            startSleepTimer(after: TimeInterval(minutes) * 60, choice: choice)
        } else {
            clearSleepTimer()
            sleepTimerChoice = choice
        }
        // With "End of Song" nothing is lined up, so the next song never makes a sound.
        refreshNext()
    }

    func startSleepTimer(after seconds: TimeInterval, choice: SleepTimerChoice) {
        clearSleepTimer()
        sleepTimerChoice = choice
        sleepTimerDeadline = now().addingTimeInterval(seconds)
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.clearSleepTimer()
            self?.pause()
        }
    }

    private func clearSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimerDeadline = nil
        sleepTimerChoice = .off
    }

    /// "End of Song": the song has ended. The next one waits at its start, so Play carries on.
    private func stopForSleepTimer() {
        clearSleepTimer()
        pausedByUser = true
        if let index = playQueue.indexAfterEnd(repeat: repeatMode) {
            playQueue.move(to: index)
            startCurrent(autoplay: false)
        } else {
            finishQueue()
        }
    }

    // MARK: Favourites and ratings

    /// `song` with this run's favourite and rating changes on it. The app's lists hold copies from
    /// when they loaded, which would otherwise offer to favourite a song already favourited.
    public func latest(_ song: Song) -> Song {
        guard let edit = songEdits[song.id] else { return song }
        var latest = song
        if let starred = edit.starred { latest.starred = starred }
        if let rating = edit.userRating { latest.userRating = rating }
        return latest
    }

    /// Flutter's song options' rating, for any song: it changes once the server has taken it. 0
    /// removes the rating.
    public func rate(_ song: Song, rating: Int) async throws {
        guard let client else { throw SubsonicError.network }
        try await client.setRating(id: song.id, rating: rating)
        playQueue.updateSongs(id: song.id) { $0.userRating = rating }
        songEdits[song.id, default: SongEdit()].userRating = rating
        onListen?(.rated(song, rating))
    }

    /// Flutter `toggleFavorite`: the current song's heart changes at once and changes back on failure.
    /// Fast taps are ordered as `setRating`'s: one write after another, an overtaken tap skipped, and
    /// only the newest tap's failure changes the heart back (to what the server last took).
    public func toggleFavorite() async {
        guard let song = currentSong else { return }
        let starred = !song.starred
        var writes = favoriteWrites[song.id] ?? FavoriteWrites(confirmed: song.starred)
        writes.newest += 1
        let generation = writes.newest
        let previous = writes.tail
        setStarred(starred, songID: song.id)
        let write = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self else { return }
            await self.writeFavorite(starred, of: song, generation: generation)
        }
        writes.tail = write
        favoriteWrites[song.id] = writes
        await write.value
    }

    /// One heart tap's write, once the writes before it are done.
    private func writeFavorite(_ isStarred: Bool, of song: Song, generation: Int) async {
        let id = song.id
        // A newer tap has come while this one waited: that one writes instead.
        guard favoriteWrites[id]?.newest == generation else { return }
        do {
            try await writeFavorite(isStarred, songID: id)
            favoriteWrites[id]?.confirmed = isStarred
            onListen?(.starred(song, isStarred))
            if favoriteWrites[id]?.newest == generation { favoriteWrites[id] = nil }
        } catch {
            // A newer tap is waiting and will write its own; this one is forgotten.
            guard let writes = favoriteWrites[id], writes.newest == generation else { return }
            setStarred(writes.confirmed, songID: id)
            favoriteWrites[id] = nil
        }
    }

    /// Flutter `toggleFavoriteForSong`: any song, changing only once the server has taken it.
    public func toggleFavorite(for song: Song) async throws {
        let song = latest(song)
        try await writeFavorite(!song.starred, songID: song.id)
        setStarred(!song.starred, songID: song.id)
        onListen?(.starred(song, !song.starred))
    }

    /// Flutter `setRating`, for the current song only: it changes at once and changes back on failure.
    /// Fast taps keep the newest: the writes go one after another, a tap that a newer one has
    /// overtaken is skipped, and only the newest tap's failure changes the stars back (to what the
    /// server last took) and throws.
    public func setRating(songID: String, rating: Int) async throws {
        guard let song = currentSong, song.id == songID else { return }
        var writes = ratingWrites[songID] ?? RatingWrites(confirmed: song.userRating)
        writes.newest += 1
        let generation = writes.newest
        let previous = writes.tail
        showRating(rating, songID: songID)
        let write = Task<(any Error)?, Never> { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self else { return nil }
            return await self.writeRating(rating, of: song, generation: generation)
        }
        writes.tail = Task { _ = await write.value }
        ratingWrites[songID] = writes
        if let error = await write.value { throw error }
    }

    /// One tap's write, once the writes before it are done. Returns the error to show, if any.
    private func writeRating(_ rating: Int, of song: Song, generation: Int) async -> (any Error)? {
        let id = song.id
        // A newer tap has come while this one waited: that one writes instead.
        guard ratingWrites[id]?.newest == generation else { return nil }
        do {
            guard let client else { throw SubsonicError.network }
            try await client.setRating(id: id, rating: rating)
            ratingWrites[id]?.confirmed = rating
            onListen?(.rated(song, rating))
            if ratingWrites[id]?.newest == generation { ratingWrites[id] = nil }
            return nil
        } catch {
            // A newer tap is waiting and will write its own rating; this one is forgotten.
            guard let writes = ratingWrites[id], writes.newest == generation else { return nil }
            showRating(writes.confirmed, songID: id)
            ratingWrites[id] = nil
            return error
        }
    }

    /// Shows `rating` on the song everywhere: the queue, and the menus' copies through `latest`.
    private func showRating(_ rating: Int?, songID: String) {
        playQueue.updateSongs(id: songID) { $0.userRating = rating }
        songEdits[songID, default: SongEdit()].userRating = rating
    }

    private func writeFavorite(_ isStarred: Bool, songID: String) async throws {
        guard let client else { throw SubsonicError.network }
        if isStarred {
            try await client.star(id: songID)
        } else {
            try await client.unstar(id: songID)
        }
    }

    private func setStarred(_ isStarred: Bool, songID: String) {
        playQueue.updateSongs(id: songID) { $0.starred = isStarred }
        songEdits[songID, default: SongEdit()].starred = isStarred
    }

    // MARK: The audio session

    /// A phone call or another app has taken the audio.
    public func handleInterruptionBegan() {
        let justStopped = systemPausedAt.map { now().timeIntervalSince($0) < 1 } ?? false
        guard isPlaying || justStopped else { return }
        resumesAfterInterruption = true
        isPlaying = false
        engine.pause()
        syncTracker()
        onNowPlayingChange?()
    }

    /// The interruption is over. It resumes only if it was playing and the system says it may.
    public func handleInterruptionEnded(shouldResume: Bool) {
        let resumes = resumesAfterInterruption && !pausedByUser && shouldResume
        resumesAfterInterruption = false
        // No fade: the system has already brought the sound back (C19).
        if resumes { play(fadeIn: 0) }
    }

    /// Headphones came out, or the Bluetooth speaker went away: pause (Flutter's "becoming noisy").
    public func handleOutputLost() {
        resumesAfterInterruption = false
        pausedByUser = true
        if isPlaying {
            isPlaying = false
            engine.pause()
            syncTracker()
            onNowPlayingChange?()
        }
    }

    /// The system's media services restarted, which kills every player: the engine builds new ones
    /// and the song loaded is loaded again where it was, playing or paused as it was, its play count
    /// carrying on. The audio session must be set up again first.
    public func handleMediaServicesReset() {
        let wasPlaying = isPlaying
        let hadItem = engine.hasItem
        engine.resetMediaServices()
        queuedNextID = nil
        queuedCrossfade = nil
        // Nothing loaded is loaded by the next Play as usual; a wait at the queue's end loads what
        // comes on the new players.
        guard hadItem, endWait == nil, currentSong != nil else { return }
        startCurrent(autoplay: wasPlaying, at: position, keepsListen: true)
    }

    /// The app is going to the background: save the position now (Flutter's lifecycle observer).
    public func saveNow() {
        scheduleSave(after: .zero)
    }

    // MARK: Engine events

    private func handle(_ event: AudioEngineEvent) {
        switch event {
        case .position(let seconds):
            position = seconds
            // While playing, the place goes to the server every 30 s (C36), and into the phone's own
            // saved queue with it: a phone killed while playing (in the background, say) would
            // otherwise come back at an older place than the server's, and send that older one.
            if isPlaying, now().timeIntervalSince(lastServerSave ?? .distantPast) >= 30 {
                lastServerSave = now()
                scheduleSave(after: .zero)
            }
        case .duration(let seconds):
            duration = seconds
            onNowPlayingChange?()
        case .playing(let playing):
            if !playing, isPlaying { systemPausedAt = now() }
            if playing != isPlaying {
                isPlaying = playing
                onNowPlayingChange?()
            }
            syncTracker()
        case .buffering(let buffering):
            isBuffering = buffering
            isLoading = buffering
            syncTracker()
            // The lock screen's clock stops while the network falls behind.
            onNowPlayingChange?()
        case .advanced:
            retireCurrent(isSkippingToNext ? .next : .ended)
            isSkippingToNext = false
            hasFailed = false
            if let index = playQueue.indexAfterEnd(repeat: repeatMode) { playQueue.move(to: index) }
            queuedNextID = nil
            queuedCrossfade = nil
            adoptCurrent()
            refreshNext()
            syncTracker()
            onNowPlayingChange?()
            // "End of Song" set just as the engine moved on.
            if sleepTimerChoice == .whenSongEnds {
                clearSleepTimer()
                pause()
                refreshNext()
            }
        case .ended:
            retireCurrent(isSkippingToNext ? .next : .ended)
            isSkippingToNext = false
            queuedNextID = nil
            queuedCrossfade = nil
            if sleepTimerChoice == .whenSongEnds {
                stopForSleepTimer()
            } else if let index = playQueue.indexAfterEnd(repeat: repeatMode) {
                // Gapless is off, or the next song couldn't be lined up. A song that ends while a
                // pause fades out (C19) lines up the next one paused, as the user asked.
                playQueue.move(to: index)
                startCurrent(autoplay: !pausedByUser)
            } else {
                endOfQueue()
            }
        case .failed:
            // Flutter stops here too, without a message.
            isSkippingToNext = false
            hasFailed = true
            isPlaying = false
            isLoading = false
            isBuffering = false
            syncTracker()
            onNowPlayingChange?()
        }
    }

    // MARK: Moving between songs

    private func go(to index: Int, autoplay: Bool) {
        retireCurrent()
        playQueue.move(to: index)
        startCurrent(autoplay: autoplay)
    }

    /// Loads the current song into the engine.
    /// `fadeIn` only for Play on a song not yet loaded (a restored one): other starts don't fade (C19).
    /// `keepsListen`: the same song loaded again (after a failure), so its play count carries on.
    private func startCurrent(
        autoplay: Bool, at start: TimeInterval = 0, fadeIn: TimeInterval = 0, keepsListen: Bool = false
    ) {
        guard let song = currentSong else { return }
        callOffEndWait()
        if autoplay {
            // Starting music undoes an earlier pause, as Play does: an interruption can resume it
            // again, and a song ending moves on playing.
            pausedByUser = false
            resumesAfterInterruption = false
        }
        isPlaceholder = false
        startCount += 1
        adoptCurrent(at: start, keepsListen: keepsListen)
        guard let url = streamURL(for: song) else {
            // Offline, a song that isn't downloaded is skipped (C10).
            if let index = nextPlayableIndex() {
                playQueue.move(to: index)
                startCurrent(autoplay: autoplay)
                return
            }
            // With none left the queue has ended (D25), so Play starts it over rather than sitting on
            // a song that can't play. One never heard counts as no listen.
            if tracker.playedTime(at: now()) == 0 { tracker.clear() }
            finishQueue()
            return
        }
        queuedNextID = nil
        queuedCrossfade = nil
        hasFailed = false
        let next = nextPlace()
        engine.load(url, start: start, next: next?.crossfade == nil ? next?.url : nil)
        if let next, next.crossfade != nil { engine.setNext(next.url, crossfade: next.crossfade) }
        queuedNextID = next?.id
        queuedNextURL = next?.url
        queuedCrossfade = next?.crossfade
        if autoplay {
            activateSession?()
            isPlaying = true
            isBuffering = true
            isLoading = true
            engine.play(fadeIn: fadeIn)
        } else {
            isPlaying = false
            isLoading = false
            isBuffering = false
        }
        syncTracker()
        onNowPlayingChange?()
    }

    /// Everything a new current song owes, whatever brought it here.
    /// `refillsQueue` is false where the queue has just ended (D25): Auto DJ had nothing to add.
    /// `keepsListen` keeps the play count and what was announced, if they're this song's.
    private func adoptCurrent(at start: TimeInterval = 0, refillsQueue: Bool = true, keepsListen: Bool = false) {
        guard let song = currentSong else { return }
        if !keepsListen || tracker.songID != song.id {
            tracker.begin(songID: song.id)
            hasAnnounced = false
        }
        position = start
        duration = TimeInterval(song.duration ?? 0)
        applyVolume()
        scheduleSave()
        refillRadioIfNeeded()
        if refillsQueue { refillIfNeeded() }
    }

    /// Past the last song: a radio queue fetches more and carries on, as does Auto DJ (Flutter's
    /// `_checkAndRefillAutoQueue` at the end); any other ends (D25).
    private func endOfQueue() {
        guard queueIsStation else {
            refillAtQueueEnd()
            return
        }
        if radioTask == nil, let seed = queue.last { fetchRadioSongs(seed: seed) }
        isLoading = true
        let waiting = radioTask
        let starts = startCount
        endWait?.cancel()
        endWait = Task {
            await waiting?.value
            // Stopped, or a later wait has taken over.
            guard !Task.isCancelled else { return }
            endWait = nil
            // Something else has been played meanwhile (another Next, a tapped song), or radio ended.
            guard queueIsStation, starts == startCount else { return }
            moveOnAfterWait()
        }
    }

    /// A wait at the queue's end is over: on to what came, or the queue ends (D25). It plays unless
    /// paused meanwhile (Pause, the sleep timer, headphones out); held by an interruption, it waits
    /// paused for the interruption's end to resume it.
    private func moveOnAfterWait() {
        isLoading = false
        if let index = playQueue.indexAfterEnd(repeat: repeatMode) {
            playQueue.move(to: index)
            startCurrent(autoplay: !pausedByUser && !resumesAfterInterruption)
        } else {
            finishQueue()
        }
    }

    private func callOffEndWait() {
        endWait?.cancel()
        endWait = nil
    }

    /// The queue has ended (D25): back on its first song, paused, ready to start over.
    private func finishQueue() {
        retireCurrent()
        callOffEndWait()
        engine.stop()
        queuedNextID = nil
        queuedCrossfade = nil
        // The queue is over: an interruption that ends later doesn't start it again (the audit's P3).
        resumesAfterInterruption = false
        systemPausedAt = nil
        isPlaying = false
        isLoading = false
        isBuffering = false
        playQueue.move(to: 0)
        adoptCurrent(refillsQueue: false)
        onNowPlayingChange?()
    }

    /// The song after the current one, if it should be lined up now, and whether it crossfades.
    /// Crossfade lines it up even with gapless off: they're separate settings, as in Flutter.
    private func nextPlace() -> (id: UUID, url: URL, crossfade: Crossfade?)? {
        guard sleepTimerChoice != .whenSongEnds,
              let index = playQueue.indexAfterEnd(repeat: repeatMode),
              let id = playQueue.entryID(at: index),
              let url = streamURL(for: queue[index]) else { return nil }
        let crossfade = crossfade(into: index)
        guard crossfade != nil || isGaplessEnabled else { return nil }
        return (id, url, crossfade)
    }

    /// The overlap into the song at `index` when the current one ends by itself (D88), or nil for a
    /// gapless change: crossfade off; Repeat One (the song loops); the next track of the same album,
    /// which stays gapless; or a length that isn't known. Capped at half the shorter song, in wall
    /// time at the speed playing (Flutter's started a short song's fade at its start). The End-of-Song
    /// timer and the queue's end line nothing up at all (`nextPlace`).
    private func crossfade(into index: Int) -> Crossfade? {
        let seconds = CrossfadeSettings(defaults: store.defaults).seconds
        guard seconds > 0, index != currentIndex, let current = currentSong,
              queue.indices.contains(index) else { return nil }
        let next = queue[index]
        guard !Self.continuesAlbum(current, with: next) else { return nil }
        let listed = TimeInterval(current.duration ?? 0)
        guard listed > 0 else { return nil }
        let shorter = min(listed, TimeInterval(next.duration ?? Int.max))
        let length = min(TimeInterval(seconds), shorter / 2 / playbackSpeed)
        return Crossfade(length: length, listedDuration: listed)
    }

    /// Whether `next` is the track after `song` on the same album, in order: the next track on the
    /// same disc, or the first of the next disc.
    static func continuesAlbum(_ song: Song, with next: Song) -> Bool {
        guard let album = song.albumID, album == next.albumID,
              let track = song.track, let nextTrack = next.track else { return false }
        let disc = song.discNumber ?? 1
        let nextDisc = next.discNumber ?? 1
        if nextDisc == disc { return nextTrack == track + 1 }
        return nextDisc == disc + 1 && nextTrack == 1
    }

    /// Lines up the right next song, if it has changed.
    private func refreshNext() {
        guard engine.hasItem else { return }
        let next = nextPlace()
        guard next?.id != queuedNextID || next?.crossfade != queuedCrossfade else { return }
        lineUp(next)
    }

    private func lineUp(_ next: (id: UUID, url: URL, crossfade: Crossfade?)?) {
        engine.setNext(next?.url, crossfade: next?.crossfade)
        queuedNextID = next?.id
        queuedNextURL = next?.url
        queuedCrossfade = next?.crossfade
    }

    /// The first song after the current one that can play, in play order, wrapping with Repeat All.
    private func nextPlayableIndex() -> Int? {
        let count = playQueue.count
        guard count > 1, currentIndex >= 0 else { return nil }
        let after = Array((currentIndex + 1)..<count)
        let candidates = repeatMode == .all ? after + Array(0..<currentIndex) : after
        // Taken once: `queue` copies the whole queue each time it's read.
        let songs = queue
        return candidates.first { streamURL(for: songs[$0]) != nil }
    }

    private func streamURL(for song: Song) -> URL? {
        if let local = localFile?(song) { return local }
        let options = TranscodingSettings(defaults: store.defaults).streamOptions(onMobileData: isOnMobileData())
        return client?.streamURL(songID: song.id, maxBitRate: options.maxBitRate, format: options.format)
    }

    private func applyVolume() {
        let gain = currentSong?.replayGain ?? ReplayGain()
        let multiplier = ReplayGainSettings(defaults: store.defaults).multiplier(for: gain)
        engine.volume = Float(min(max(volume * multiplier, 0), 1))
    }

    // MARK: Radio

    private func endRadio() {
        queueIsStation = false
        radioTask?.cancel()
        radioTask = nil
    }

    /// Flutter `_checkAndRefillAutoQueue`: three songs or fewer left.
    private func refillRadioIfNeeded() {
        guard queueIsStation, radioTask == nil, queue.count - currentIndex <= 3, let seed = queue.last else { return }
        fetchRadioSongs(seed: seed)
    }

    private func fetchRadioSongs(seed: Song) {
        guard let client else { return }
        radioTask?.cancel()
        radioTask = Task {
            let similar = await Self.radioSongs(like: seed, client: client)
            guard !Task.isCancelled else { return }
            radioTask = nil
            let queued = Set(queue.map(\.id))
            queueUpAll(similar.filter { !queued.contains($0.id) })
        }
    }

    /// Flutter `_fetchAndQueueRadioTracks`' order: similar songs, then the genre, the artist's top
    /// songs, a search for the artist, and anything at all.
    private nonisolated static func radioSongs(like seed: Song, client: SubsonicClient) async -> [Song] {
        let count = 25
        var songs = (try? await client.similarSongs(id: seed.id, count: count)) ?? []
        if songs.isEmpty, let genre = trimmed(seed.genre) {
            songs = (try? await client.randomSongs(size: count, genre: genre)) ?? []
        }
        if songs.isEmpty, let artistID = trimmed(seed.artistID) {
            songs = (try? await client.topSongs(artistID: artistID, count: count)) ?? []
        }
        if songs.isEmpty, let artist = trimmed(seed.artist) {
            songs = ((try? await client.search(artist))?.songs ?? []).filter { $0.id != seed.id }
        }
        if songs.isEmpty {
            songs = (try? await client.randomSongs(size: count)) ?? []
        }
        return songs
    }

    private nonisolated static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    // MARK: Auto DJ (C21, D90)

    /// Songs Auto DJ remembers, as played or added, so it doesn't bring them straight back.
    static let refillMemory = 20

    /// Not for the kept placeholder (D81), offline, with Repeat on, or on a radio queue (which has its own).
    private var canRefill: Bool {
        refillSource != .off && !queueIsStation && !isPlaceholder && client != nil && repeatMode == .off && currentSong != nil
    }

    /// A new list, a cleared queue or another server: what a fetch under way finds is dropped.
    private func dropRefillFetch() {
        refillTask?.cancel()
        refillTask = nil
        refillGeneration += 1
    }

    /// Flutter `shouldAddSongs`: two songs or fewer after the current one, one fetch at a time.
    private func refillIfNeeded() {
        guard canRefill, refillTask == nil, playQueue.upcomingCount <= RefillSettings.threshold,
              let seed = currentSong else { return }
        fetchRefillSongs(seed: seed)
    }

    private func fetchRefillSongs(seed: Song) {
        guard let client else { return }
        let mode = refillSource
        let count = RefillSettings(defaults: store.defaults).refillCount
        let excluded = refillExcluded()
        let genres = mode == .fromBlend ? favouriteGenres(2) : []
        let generation = refillGeneration
        refillTask = Task {
            // Dropped before it began (Search's radio starting, a new list): ask the server nothing.
            guard !Task.isCancelled else { return }
            let found = await Self.refillSongs(
                mode: mode, seed: seed, count: count, excluding: excluded, favouriteGenres: genres, client: client
            )
            guard !Task.isCancelled, generation == refillGeneration else { return }
            refillTask = nil
            guard canRefill, !found.isEmpty else { return }
            recentRefills = Array((recentRefills + found.map(\.id)).suffix(Self.refillMemory))
            playQueue.appendAutoplay(found)
            refreshNext()
            scheduleSave()
        }
    }

    /// What Auto DJ doesn't add: what's still to come, the last songs played, and the last it added.
    /// Flutter left out the whole queue and its last 100, which runs dry on a small library.
    private func refillExcluded() -> Set<String> {
        let start = max(currentIndex, 0)
        let upcoming = queue[start...].map(\.id)
        let played = queue[..<start].suffix(Self.refillMemory).map(\.id)
        return Set(upcoming + played + recentRefills)
    }

    /// The queue ran out with Auto DJ on: wait for its songs, then go on, or end (D25) if none came.
    private func refillAtQueueEnd() {
        guard canRefill else {
            finishQueue()
            return
        }
        if refillTask == nil, let seed = currentSong { fetchRefillSongs(seed: seed) }
        isLoading = true
        let generation = refillGeneration
        let starts = startCount
        endWait?.cancel()
        endWait = Task {
            // A mode changed meanwhile starts a new fetch: wait for that one too.
            var waited: Task<Void, Never>?
            while let task = refillTask, task != waited {
                waited = task
                await task.value
            }
            // Stopped, or a later wait has taken over.
            guard !Task.isCancelled else { return }
            endWait = nil
            // Something else has been played meanwhile, or a new list started.
            guard generation == refillGeneration, starts == startCount else { return }
            moveOnAfterWait()
        }
    }

    /// Flutter `getSongsToQueue`: each mode asks for twice `count`, and keeps `count` new ones,
    /// shuffled. A source with nothing new falls to the next (Flutter's chain); errors count as
    /// nothing. With nothing new anywhere, anything but the seed, so it never silently stops.
    nonisolated static func refillSongs(
        mode: RefillSource,
        seed: Song,
        count: Int,
        excluding excluded: Set<String>,
        favouriteGenres: [String],
        client: SubsonicClient
    ) async -> [Song] {
        let genre = trimmed(seed.genre)
        let artistID = trimmed(seed.artistID)
        let fromGenre = genre.map(RefillPool.genre)
        let fromArtist = artistID.map(RefillPool.artist)
        let sources: [RefillPool] = switch mode {
        case .off: []
        case .fromLibrary: [.random]
        case .fromSimilar: [.similar] + [fromGenre, fromArtist].compactMap { $0 } + [.random]
        case .fromGenre: [fromGenre].compactMap { $0 } + [.random]
        case .fromArtist: [fromArtist].compactMap { $0 } + [.random]
        case .fromBlend: [.fromBlend, .random]
        }
        var everything: [Song] = []
        for source in sources {
            let songs = await refillSongs(
                from: source, seed: seed, count: count, favouriteGenres: favouriteGenres, client: client
            )
            let picked = pick(songs, count: count, excluding: excluded)
            if !picked.isEmpty { return picked }
            everything += songs
        }
        return pick(everything, count: count, excluding: [seed.id])
    }

    enum RefillPool: Sendable {
        case random, similar, genre(String), artist(String), fromBlend
    }

    /// One source's songs, twice `count` of them (Smart Mix asks for its own shares).
    private nonisolated static func refillSongs(
        from source: RefillPool,
        seed: Song,
        count: Int,
        favouriteGenres: [String],
        client: SubsonicClient
    ) async -> [Song] {
        let ask = count * 2
        switch source {
        case .random:
            return (try? await client.randomSongs(size: ask)) ?? []
        case .similar:
            return (try? await client.similarSongs(id: seed.id, count: ask)) ?? []
        case .genre(let genre):
            // Flutter's `getSongsByGenre` always gave the genre's first songs; random ones from it instead.
            return (try? await client.randomSongs(size: ask, genre: genre)) ?? []
        case .artist(let artistID):
            return (try? await client.topSongs(artistID: artistID, count: ask)) ?? []
        case .fromBlend:
            return await blendSongs(
                seed: seed, genre: trimmed(seed.genre), count: count, favouriteGenres: favouriteGenres, client: client
            )
        }
    }

    /// Flutter's Smart Mix without its tempo part, which never ran (nothing measured BPM): similar
    /// songs, the song's genre, the listener's two favourite genres, and random ones, together.
    private nonisolated static func blendSongs(
        seed: Song,
        genre: String?,
        count: Int,
        favouriteGenres: [String],
        client: SubsonicClient
    ) async -> [Song] {
        let similarCount = Int((Double(count) * 0.4).rounded(.up))
        let otherCount = Int((Double(count) * 0.3).rounded(.up))
        async let similar = (try? await client.similarSongs(id: seed.id, count: similarCount)) ?? []
        async let fromGenre = randomSongs(otherCount, genre: genre, client: client)
        async let random = (try? await client.randomSongs(size: otherCount)) ?? []
        let liked = await withTaskGroup(of: [Song].self) { group in
            for genre in favouriteGenres.prefix(2) {
                group.addTask { (try? await client.randomSongs(size: 3, genre: genre)) ?? [] }
            }
            var songs: [Song] = []
            for await found in group { songs += found }
            return songs
        }
        return await similar + fromGenre + liked + random
    }

    private nonisolated static func randomSongs(_ size: Int, genre: String?, client: SubsonicClient) async -> [Song] {
        guard let genre else { return [] }
        return (try? await client.randomSongs(size: size, genre: genre)) ?? []
    }

    /// Flutter `_filterAndLimit`: no repeats, shuffled, `count` at most.
    nonisolated static func pick(_ songs: [Song], count: Int, excluding excluded: Set<String>) -> [Song] {
        var seen = excluded
        var kept: [Song] = []
        for song in songs.shuffled() where !seen.contains(song.id) {
            seen.insert(song.id)
            kept.append(song)
        }
        return Array(kept.prefix(count))
    }

    // MARK: Scrobbling

    /// Play counts follow time actually playing, and the server hears about a song once it starts.
    private func syncTracker() {
        guard let song = currentSong else { return }
        if isPlaying, !isBuffering {
            tracker.resume(at: now(), rate: playbackSpeed)
            if !hasAnnounced {
                hasAnnounced = true
                scrobble(song.id, submission: false)
                onListen?(.started(song))
            }
        } else {
            tracker.pause(at: now())
        }
    }

    /// The song is on its way out, however that happened: it counts if it was played enough (D24).
    private func retireCurrent(_ end: ListenEnd = .replaced) {
        defer { tracker.clear() }
        guard let songID = tracker.songID else { return }
        if let song = currentSong, song.id == songID {
            onListen?(.finished(song, played: tracker.playedTime(at: now()), duration: duration, end: end))
        }
        guard tracker.hasPlayedEnough(duration: duration, at: now()) else { return }
        scrobble(songID, submission: true)
    }

    /// Flutter's `scrobble` + `queueScrobble`: what the server doesn't take waits for the next try.
    private func scrobble(_ songID: String, submission: Bool) {
        let pending = PlayerStore.PendingScrobble(songID: songID, submission: submission, time: now())
        guard let client else {
            if let profileID { store.setHeldScrobbles(store.heldScrobbles(profileID: profileID) + [pending], profileID: profileID) }
            return
        }
        let profileID = profileID
        let store = store
        Task {
            do {
                try await client.scrobble(id: songID, submission: submission)
            } catch is CancellationError {
            } catch {
                if let profileID {
                    store.setHeldScrobbles(store.heldScrobbles(profileID: profileID) + [pending], profileID: profileID)
                }
            }
        }
    }

    /// Flutter `flushPendingScrobbles`, at each sign-in and each new list. Plays go with the time they
    /// happened, and "now playing" notices are dropped, as they're no longer true (C10; Flutter sent
    /// both, without the time).
    private func sendHeldScrobbles() {
        guard flushTask == nil, let client, let profileID else { return }
        let waiting = store.heldScrobbles(profileID: profileID)
        guard !waiting.isEmpty else { return }
        let store = store
        flushTask = Task {
            var failed: [PlayerStore.PendingScrobble] = []
            for scrobble in waiting where scrobble.submission {
                do {
                    try await client.scrobble(id: scrobble.songID, submission: true, time: scrobble.time)
                } catch {
                    failed.append(scrobble)
                }
            }
            // Anything added while this ran is after the ones it took.
            let added = store.heldScrobbles(profileID: profileID).dropFirst(waiting.count)
            store.setHeldScrobbles(failed + added, profileID: profileID)
            // Called off by `reset`, which may have let a newer flush start.
            if !Task.isCancelled { flushTask = nil }
        }
    }

    // MARK: Saving the queue

    /// Flutter `_saveQueueState`: 200 ms after the last change.
    private func scheduleSave(after delay: Duration = .milliseconds(200)) {
        guard let profileID else { return }
        saveTask?.cancel()
        guard !playQueue.isEmpty else { return }
        let saved = PlayerStore.SavedQueue(
            profileID: profileID,
            queue: playQueue.saved,
            position: position,
            isPlaceholder: isPlaceholder ? true : nil
        )
        let store = store
        // A save already writing isn't stopped by cancelling it: one made before a clear (a sign-out)
        // is dropped by the store instead.
        let clears = store.clearCount
        saveTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await store.saveQueue(saved, ifNotClearedSince: clears)
        }
        // And to the server (C36): `saveNow` (the app leaving the foreground) at once, else a second
        // after the last change, past a pause's fade-out.
        scheduleServerSave(after: delay == .zero ? .zero : .seconds(1))
    }

    private func restoreQueue(profileID: String) {
        guard playQueue.isEmpty, let saved = store.loadQueue(), saved.profileID == profileID else { return }
        playQueue = PlayQueue(saved: saved.queue, isShuffled: store.isShuffled)
        isPlaceholder = saved.isPlaceholder ?? false
        guard let song = currentSong else { return }
        position = saved.position
        duration = TimeInterval(song.duration ?? 0)
        applyVolume()
        onNowPlayingChange?()
    }

    // MARK: The server's queue (C36, D143)

    /// At most this many songs go to the server, around the current one: a whole library can be queued.
    static let serverQueueLimit = 1000

    /// The songs sent: up to 100 before the current one, the rest after it.
    static func serverWindow(count: Int, current: Int) -> Range<Int> {
        guard count > serverQueueLimit else { return 0..<count }
        let start = min(max(current - 100, 0), count - serverQueueLimit)
        return start..<(start + serverQueueLimit)
    }

    /// The queue as the server would hold it; nil when there's nothing of the user's (empty, or the
    /// kept song of D81, which never goes to the server).
    private func queueForServer() -> (ids: [String], current: String, positionMs: Int, snapshot: QueueSnapshot)? {
        guard !isPlaceholder, let current = currentSong else { return nil }
        let songs = playQueue.songs
        let ids = songs[Self.serverWindow(count: songs.count, current: currentIndex)].map(\.id)
        let positionMs = Int((max(position, 0) * 1000).rounded())
        return (ids, current.id, positionMs, QueueSnapshot(songIDs: ids, currentID: current.id, positionMs: positionMs))
    }

    private var isIdle: Bool { !isPlaying && !isLoading && endWait == nil }

    /// Looks at the server's saved queue and takes it if it's newer, or sends this phone's if this
    /// one is (`QueueSyncDecision`). At sign-in and on each return from the background, and only while
    /// nothing plays: playing here is never interrupted. One look at a time.
    public func checkServerQueue() {
        guard QueueSyncSettings(defaults: store.defaults).isEnabled, let client, let profileID,
              serverCheckTask == nil, isIdle else { return }
        let before = playQueue
        let starts = startCount
        serverCheckTask = Task { [weak self] in
            let answer: ServerPlayQueue?
            do {
                answer = try await client.playQueue()
            } catch {
                // Out of reach: the next sign-in or return looks again.
                if !Task.isCancelled { self?.serverCheckTask = nil }
                return
            }
            guard !Task.isCancelled, let self else { return }
            serverCheckTask = nil
            // Anything the user did meanwhile wins; the kept song arriving meanwhile doesn't count.
            guard self.profileID == profileID, playQueue == before || isPlaceholder,
                  startCount == starts, isIdle else { return }
            settle(with: answer, client: client, profileID: profileID)
        }
    }

    private func settle(with answer: ServerPlayQueue?, client: SubsonicClient, profileID: String) {
        var record = store.queueSyncRecord(profileID: profileID)
        let server = answer.map { (snapshot: QueueSnapshot($0), changed: $0.changed) }
        switch QueueSyncDecision.decide(server: server, local: queueForServer()?.snapshot, record: record) {
        case .nothing:
            break
        case .inSync:
            record.mark = server?.snapshot
            record.clearChange()
            store.setQueueSyncRecord(record, profileID: profileID)
        case .send:
            sendQueue(client: client, profileID: profileID, decided: true)
        case .take(let announces):
            guard let answer, let server else { return }
            take(answer, mark: server.snapshot, profileID: profileID)
            if announces { onQueueTaken?() }
        }
    }

    /// Loads the server's queue as this phone's own, paused at its place, as `restoreQueue` does: no
    /// sound, no play counted; the lock screen and the saved file follow. Its songs come in the order
    /// they play, Auto DJ's and radio's as ordinary ones; shuffle and repeat stay as this phone has them.
    private func take(_ answer: ServerPlayQueue, mark: QueueSnapshot, profileID: String) {
        seedTask?.cancel()
        seedTask = nil
        retireCurrent()
        endRadio()
        dropRefillFetch()
        callOffEndWait()
        engine.stop()
        saveTask?.cancel()
        serverSaveTask?.cancel()
        queuedNextID = nil
        queuedCrossfade = nil
        hasFailed = false
        let found = answer.songs.firstIndex { $0.id == answer.currentID }
        let saved = PlayQueue.Saved(
            songs: answer.songs, originalOrder: nil, currentIndex: found ?? 0,
            currentSongID: answer.songs[found ?? 0].id, autoplayStart: nil
        )
        playQueue = PlayQueue(saved: saved, isShuffled: store.isShuffled)
        isPlaceholder = false
        isPlaying = false
        isLoading = false
        isBuffering = false
        hasAnnounced = false
        // A current song the server no longer finds: the queue's start.
        position = found == nil ? 0 : TimeInterval(answer.positionMs) / 1000
        duration = TimeInterval(currentSong?.duration ?? 0)
        applyVolume()
        // The mark first, so the save below sees nothing new to send (with a lost current song, it
        // sends the queue's start once).
        store.setQueueSyncRecord(QueueSyncRecord(mark: mark, changedHereAt: nil), profileID: profileID)
        scheduleSave()
        onNowPlayingChange?()
    }

    /// Notes a change of this phone's queue the server doesn't have yet, and sends it after `delay`.
    /// Nothing for the kept song, and nothing is sent offline or with the setting off (the change is
    /// still noted, for the next look). A send that fails is dropped: the next one carries the newer state.
    private func scheduleServerSave(after delay: Duration) {
        guard let profileID, let local = queueForServer() else { return }
        noteChangedHere(local.snapshot, profileID: profileID)
        guard let client, QueueSyncSettings(defaults: store.defaults).isEnabled else { return }
        serverSaveTask?.cancel()
        serverSaveTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            sendQueue(client: client, profileID: profileID)
        }
    }

    /// "Changed here" is the time of this phone's last change the server doesn't hold, kept across
    /// launches (it settles who wins when both sides changed, D143). The time of the change, not of
    /// the save: the same queue saved again keeps it (`QueueSyncRecord.note`).
    private func noteChangedHere(_ snapshot: QueueSnapshot, profileID: String) {
        let old = store.queueSyncRecord(profileID: profileID)
        var record = old
        record.note(snapshot, at: now())
        if record != old { store.setQueueSyncRecord(record, profileID: profileID) }
    }

    /// How old an unsent change may be and still be sent without a look first: a change is normally
    /// sent a second after it's made.
    static let heldChangeAge: TimeInterval = 10

    /// Sends the queue as it is now, unless the server already has it. One save at a time.
    /// **A change that has waited** (made offline, a save that failed, the app suspended before its
    /// save) **isn't sent blind:** another device may have played since, so the look reads the server
    /// first and decides (C46, D163; `decided`: it has). Playing here always sends.
    private func sendQueue(client: SubsonicClient, profileID: String, decided: Bool = false) {
        guard self.profileID == profileID, let local = queueForServer() else { return }
        guard !isSendingQueue else {
            sendsAgain = true
            return
        }
        var record = store.queueSyncRecord(profileID: profileID)
        guard record.mark?.matches(local.snapshot) != true else {
            if record.changedHereAt != nil || record.changedSnapshot != nil {
                record.clearChange()
                store.setQueueSyncRecord(record, profileID: profileID)
            }
            return
        }
        if !decided, isIdle, let here = record.changedHereAt, now().timeIntervalSince(here) > Self.heldChangeAge {
            checkServerQueue()
            return
        }
        isSendingQueue = true
        let started = now()
        lastServerSave = started
        let store = store
        // Not cancelled with the wait: a save on its way is let finish, and its mark kept.
        Task { [weak self] in
            let sent = (try? await client.savePlayQueue(
                songIDs: local.ids, current: local.current, positionMs: local.positionMs
            )) != nil
            if sent {
                var record = store.queueSyncRecord(profileID: profileID)
                record.mark = local.snapshot
                if let here = record.changedHereAt, here <= started { record.clearChange() }
                store.setQueueSyncRecord(record, profileID: profileID)
            }
            guard let self else { return }
            isSendingQueue = false
            if sendsAgain {
                sendsAgain = false
                if let client = self.client { sendQueue(client: client, profileID: profileID) }
            }
        }
    }

    // MARK: A song that's always there (D81)

    /// With nothing queued (a first sign-in, a server never played on, a switched server), loads one
    /// song, paused, so the mini-player always has something to show. It makes no sound, counts as no
    /// play and tells the server nothing: it's `restoreQueue` with a song picked here. In order: the
    /// newest recently played album's first song, a random song, and with the server out of reach a
    /// downloaded one; with none of those nothing is loaded. A song the user starts meanwhile wins.
    func seedIfEmpty() {
        guard playQueue.isEmpty, let profileID else { return }
        // A new sign-in (or the server back) starts the look again: the old one may have come up empty.
        seedTask?.cancel()
        let client = client
        seedTask = Task { [weak self] in
            let found = await Self.songToShow(client: client)
            guard !Task.isCancelled, let self else { return }
            seedTask = nil
            guard self.profileID == profileID, playQueue.isEmpty,
                  let song = found ?? offlineSongs().first else { return }
            playQueue.load([song], startIndex: 0)
            isPlaceholder = true
            isPlaying = false
            position = 0
            duration = TimeInterval(song.duration ?? 0)
            applyVolume()
            scheduleSave()
            onNowPlayingChange?()
        }
    }

    /// The kept song goes, before the songs the user queues take its place.
    private func dropPlaceholder() {
        tracker.clear()
        engine.stop()
        playQueue.clear()
        queuedNextID = nil
        queuedCrossfade = nil
        isPlaceholder = false
        isPlaying = false
        isLoading = false
        isBuffering = false
        position = 0
        duration = 0
    }

    private nonisolated static func songToShow(client: SubsonicClient?) async -> Song? {
        guard let client else { return nil }
        // The random song is asked for alongside the album look (C30 bug 14), so a server with nothing
        // played yet (a first set-up) has its song after one round trip, not three. The order stays.
        async let random = try? await client.randomSongs(size: 1).first
        if let album = try? await client.albumList(.recent, size: 1).first,
           let song = try? await client.album(id: album.id).songs.first {
            return song
        }
        return await random
    }
}

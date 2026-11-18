@preconcurrency import AVFoundation

/// `AudioEngine` over `AVQueuePlayer`, which is also what the Flutter app's `just_audio` uses on iOS.
/// Keeping the next song queued is what makes the change gapless.
///
/// AVFoundation's observers call back on arbitrary threads, so each one hops to the main actor and
/// reads the player's state there rather than trusting a captured value.
@MainActor
public final class QueuePlayerEngine: AudioEngine {
    public var onEvent: (@MainActor (AudioEngineEvent) -> Void)?

    /// Replaced only after a media-services reset (`resetMediaServices`).
    private var player = AVQueuePlayer()
    private var current: Tracked?
    private var next: Tracked?
    private var observers: [NSKeyValueObservation] = []
    nonisolated(unsafe) private var timeObserver: Any?

    /// Whether `play` has been asked for and not undone.
    private var wantsPlay = false
    /// Where to seek once the item is ready: an item can't seek before that.
    private var pendingSeek: TimeInterval?
    private var isSeeking = false
    private var seekGeneration = 0
    /// What was last reported; nil after a `load`, so the first report about a new song carries both
    /// (the player sets its own loading state, which an unchanged value would leave standing).
    private var lastPlaying: Bool? = false
    private var lastBuffering: Bool? = false
    /// The pitch mode every item gets (`setRate`); the speed is the player's `defaultRate`.
    private var preservesPitch = true

    /// An item with its observers, which end with it.
    private struct Tracked {
        let item: AVPlayerItem
        let observers: [NSKeyValueObservation]
        let failureObserver: any NSObjectProtocol
    }

    public init() {
        observePlayer()
    }

    private func observePlayer() {
        observers = [
            player.observe(\.currentItem) { [weak self] _, _ in
                Task { @MainActor in self?.currentItemChanged() }
            },
            player.observe(\.timeControlStatus) { [weak self] _, _ in
                Task { @MainActor in self?.statusChanged() }
            },
        ]
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated { self?.tick(seconds) }
        }
    }

    /// After a media-services reset the player is dead: a new one, with the old one's volume and speed.
    public func resetMediaServices() {
        stop()
        let volume = player.volume
        let rate = player.defaultRate
        observers.forEach { $0.invalidate() }
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player = AVQueuePlayer()
        player.volume = volume
        player.defaultRate = rate
        observePlayer()
    }

    isolated deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let current { NotificationCenter.default.removeObserver(current.failureObserver) }
        if let next { NotificationCenter.default.removeObserver(next.failureObserver) }
    }

    public var hasItem: Bool { current != nil }

    /// What the player runs at now (0 when paused), and the current item's pitch mode: for the live tests.
    var playerRate: Float { player.rate }
    var currentPitchAlgorithm: AVAudioTimePitchAlgorithm? { current?.item.audioTimePitchAlgorithm }
    var nextPitchAlgorithm: AVAudioTimePitchAlgorithm? { next?.item.audioTimePitchAlgorithm }
    /// Where the player is and whether it's making sound: for the live crossfade test.
    var currentSeconds: TimeInterval { player.currentTime().seconds }

    public var currentTime: TimeInterval? {
        guard current != nil else { return nil }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(seconds, 0) : nil
    }
    var isSoundingNow: Bool { player.timeControlStatus == .playing }

    public var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    // MARK: Commands

    public func load(_ url: URL, start: TimeInterval, next nextURL: URL?) {
        release(next)
        release(current)
        next = nil
        current = nil
        wantsPlay = false
        isSeeking = false
        seekGeneration += 1
        player.pause()
        player.removeAllItems()
        lastPlaying = nil
        lastBuffering = nil

        let tracked = track(makeItem(url))
        current = tracked
        player.insert(tracked.item, after: nil)
        pendingSeek = start > 0 ? start : nil
        setNext(nextURL)
    }

    /// One player can't overlap two songs, so a `crossfade` is ignored and the change is gapless
    /// (`CrossfadeEngine` does the overlap with two of these).
    public func setNext(_ url: URL?, crossfade: Crossfade?) {
        // The player has moved on by itself and `currentItemChanged` hasn't run yet: `current` has
        // left its queue and `next` may be the item playing, so nothing is touched. That change's
        // `.advanced` (or `.ended`) has the player line up the right next song.
        if let current, !player.items().contains(where: { $0 === current.item }) { return }
        if let next {
            player.remove(next.item)
            release(next)
            self.next = nil
        }
        guard let url, let current else { return }
        let item = makeItem(url)
        guard player.canInsert(item, after: current.item) else { return }
        let tracked = track(item)
        next = tracked
        player.insert(tracked.item, after: current.item)
    }

    public func advanceToNext() {
        guard next != nil else { return }
        player.advanceToNextItem()
        currentItemChanged()
    }

    /// No fade here: `CrossfadeEngine` fades the volume around this.
    public func play(fadeIn: TimeInterval) {
        wantsPlay = true
        startIfReady()
    }

    public func pause(fadeOut: TimeInterval) {
        wantsPlay = false
        player.pause()
    }

    public func stop() {
        release(next)
        release(current)
        next = nil
        current = nil
        wantsPlay = false
        pendingSeek = nil
        isSeeking = false
        seekGeneration += 1
        player.pause()
        player.removeAllItems()
        report(playing: false, buffering: false)
    }

    public func setRate(_ rate: Float, preservesPitch: Bool) {
        self.preservesPitch = preservesPitch
        let algorithm = Self.pitchAlgorithm(preservesPitch)
        current?.item.audioTimePitchAlgorithm = algorithm
        next?.item.audioTimePitchAlgorithm = algorithm
        // `play()` starts at `defaultRate`. Setting `rate` itself would start a paused player, so
        // it's only touched while playing.
        player.defaultRate = rate
        if wantsPlay, player.rate != 0 { player.rate = rate }
    }

    public func seek(to seconds: TimeInterval) {
        guard let current else { return }
        guard current.item.status == .readyToPlay else {
            pendingSeek = seconds
            return
        }
        perform(seekTo: seconds)
    }

    // MARK: Items

    private func makeItem(_ url: URL) -> AVPlayerItem {
        // Precise timing is what lets MP3 and AAC files' gapless information be used.
        let options: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        // A server that asks for the device's certificate: the app loads the stream and feeds it (C45).
        let asset = StreamFeeder.asset(for: url, options: options) ?? AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = Self.pitchAlgorithm(preservesPitch)
        return item
    }

    /// Spectral is the music-quality time-stretch (the old default snaps the rate to a few values);
    /// varispeed lets the pitch follow the speed.
    static func pitchAlgorithm(_ preservesPitch: Bool) -> AVAudioTimePitchAlgorithm {
        preservesPitch ? .spectral : .varispeed
    }

    private func track(_ item: AVPlayerItem) -> Tracked {
        Tracked(
            item: item,
            observers: [
                item.observe(\.status) { [weak self, weak item] _, _ in
                    Task { @MainActor in
                        if let item { self?.itemStatusChanged(item) }
                    }
                },
                item.observe(\.duration) { [weak self, weak item] _, _ in
                    Task { @MainActor in
                        if let item { self?.itemDurationChanged(item) }
                    }
                },
            ],
            failureObserver: NotificationCenter.default.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                object: item,
                queue: .main
            ) { [weak self, weak item] notification in
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? any Error
                let message = error?.localizedDescription
                let isNetwork = error.map(NetworkTrouble.isNetwork) ?? false
                Task { @MainActor in
                    if let item, self?.current?.item === item {
                        self?.fail(message ?? "Playback failed", isNetwork: isNetwork || QueuePlayerEngine.failedOnNetwork(item))
                    }
                }
            }
        )
    }

    private func release(_ tracked: Tracked?) {
        if let tracked { NotificationCenter.default.removeObserver(tracked.failureObserver) }
    }

    // MARK: What the player reports

    private func currentItemChanged() {
        let item = player.currentItem
        guard item !== current?.item else { return }
        if let next, item === next.item {
            release(current)
            current = next
            self.next = nil
            pendingSeek = nil
            isSeeking = false
            // A seek still in flight was for the old song: it mustn't land on this one.
            seekGeneration += 1
            onEvent?(.advanced)
            itemDurationChanged(next.item)
            if next.item.status == .failed {
                fail(next.item)
            } else {
                // What that seek's end would have done: a player held for it starts.
                startIfReady()
            }
        } else if item == nil {
            release(current)
            current = nil
            wantsPlay = false
            report(playing: false, buffering: false)
            onEvent?(.ended)
        }
    }

    private func itemStatusChanged(_ item: AVPlayerItem) {
        guard item === current?.item else { return }
        switch item.status {
        case .readyToPlay:
            itemDurationChanged(item)
            if let seconds = pendingSeek {
                pendingSeek = nil
                perform(seekTo: seconds)
            } else {
                startIfReady()
            }
        case .failed:
            fail(item)
        default:
            break
        }
    }

    private func itemDurationChanged(_ item: AVPlayerItem) {
        guard item === current?.item else { return }
        let seconds = item.duration.seconds
        if seconds.isFinite, seconds > 0 { onEvent?(.duration(seconds)) }
    }

    private func statusChanged() {
        switch player.timeControlStatus {
        case .playing:
            report(playing: true, buffering: false)
        case .waitingToPlayAtSpecifiedRate:
            report(playing: true, buffering: true)
        case .paused:
            // A paused player that was meant to be playing means the system stepped in. Before an
            // item starts (a seek still to come), paused is only what's expected.
            if wantsPlay, pendingSeek == nil, !isSeeking, current != nil, player.rate == 0,
               current?.item.status == .readyToPlay {
                wantsPlay = false
            }
            report(playing: wantsPlay, buffering: wantsPlay)
        @unknown default:
            break
        }
    }

    private func tick(_ seconds: TimeInterval) {
        guard !isSeeking, pendingSeek == nil, current != nil, seconds.isFinite else { return }
        onEvent?(.position(seconds))
    }

    private func report(playing: Bool, buffering: Bool) {
        if playing != lastPlaying {
            lastPlaying = playing
            onEvent?(.playing(playing))
        }
        if buffering != lastBuffering {
            lastBuffering = buffering
            onEvent?(.buffering(buffering))
        }
    }

    /// `item` failed: a network reason where its error, or what it wraps, is the network's, or where the
    /// app's own feed gave up on the network (C68).
    private func fail(_ item: AVPlayerItem) {
        let isNetwork = item.error.map(NetworkTrouble.isNetwork) ?? false
        fail(item.error?.localizedDescription ?? "Playback failed", isNetwork: isNetwork || Self.failedOnNetwork(item))
    }

    private static func failedOnNetwork(_ item: AVPlayerItem) -> Bool {
        StreamFeeder.failedOnNetwork(item.asset)
    }

    private func fail(_ message: String, isNetwork: Bool) {
        wantsPlay = false
        pendingSeek = nil
        player.pause()
        report(playing: false, buffering: false)
        onEvent?(.failed(message, isNetwork: isNetwork))
    }

    // MARK: Starting and seeking

    private func startIfReady() {
        guard wantsPlay, pendingSeek == nil, !isSeeking else { return }
        player.play()
    }

    private func perform(seekTo seconds: TimeInterval) {
        isSeeking = true
        seekGeneration += 1
        let generation = seekGeneration
        let time = CMTime(seconds: seconds, preferredTimescale: 1000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, generation == self.seekGeneration else { return }
                self.isSeeking = false
                self.onEvent?(.position(seconds))
                self.startIfReady()
            }
        }
    }
}

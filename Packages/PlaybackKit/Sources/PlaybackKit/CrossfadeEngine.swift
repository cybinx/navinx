import Foundation

/// Crossfade and fade in/out (C19, D88) over two child engines, each a `QueuePlayerEngine`.
///
/// **With no crossfade lined up and no fade asked for, it only forwards** to the child playing now:
/// the change to the next song is that child's own gapless hand-over, exactly as before C19.
///
/// **A crossfade** (`setNext(_:crossfade:)`): the playing child gets no next item. About ten seconds
/// before the overlap the other child loads the next song, paused; at `duration − length × speed` it
/// starts at silence and the two volumes cross on an equal-power curve over `length` seconds. It
/// reports `.advanced` as the overlap starts (the song shown, the lock screen and the play count move
/// to the new song then), forwards only the new child's events from then on, and stops the old child
/// at the end. **Anything that moves playback** (pause, seek, load, a skip, stop, a failure) ends an
/// overlap at once: the old song stops, the new one carries on at its full volume.
///
/// **Fades** multiply both children's volume: `play(fadeIn:)` rises from silence once the audio is
/// actually sounding; `pause(fadeOut:)` falls, then pauses, and reports nothing playing meanwhile.
@MainActor
public final class CrossfadeEngine: AudioEngine {
    public var onEvent: (@MainActor (AudioEngineEvent) -> Void)?

    /// Internal for the live test, which reads both players.
    let children: [any AudioEngine]
    private var active = 0
    private var idle: Int { 1 - active }

    /// The current song's volume (the player's volume × its ReplayGain).
    private var gain: Float = 1
    private var rate: Float = 1

    // The crossfade lined up for the current song.
    private var plan: (url: URL, crossfade: Crossfade)?
    /// Whether the idle child holds `plan`'s song, paused at its start.
    private var isPreloaded = false
    /// What each child last reported, by index.
    private var durations: [TimeInterval?] = [nil, nil]
    private var playing = [false, false]
    private var buffering = [false, false]

    // An overlap under way.
    private var outgoing: Int?
    /// The old song's volume as a share of the new one's (their ReplayGains differ), so a volume
    /// change or mute during the overlap reaches both.
    private var outgoingShare: Float = 1
    /// 0…1 along the curve: the new song at sin, the old at cos.
    private var mix: Double = 1
    private var mixTask: Task<Void, Never>?

    // Fades.
    private var fadeLevel: Double = 1
    private var fadeTask: Task<Void, Never>?
    /// A fade-in waiting for the audio to make sound.
    private var pendingFadeIn: TimeInterval?
    private var isFadingOut = false
    /// `play` asked for and not undone.
    private var wantsPlay = false

    /// How often the volumes are stepped during a fade or an overlap.
    private let step: Duration
    /// Song-seconds before the overlap that the next song is loaded, so a stream has time to buffer.
    static let preloadLead: TimeInterval = 10
    /// Half of `QueuePlayerEngine`'s tick, in song-seconds.
    static let tickLead: TimeInterval = 0.125

    /// Two `QueuePlayerEngine`s; tests hand in their own.
    public init(children: [any AudioEngine]? = nil, step: Duration = .milliseconds(20)) {
        let children = children ?? [QueuePlayerEngine(), QueuePlayerEngine()]
        precondition(children.count == 2)
        self.children = children
        self.step = step
        for index in children.indices {
            children[index].onEvent = { [weak self] event in self?.childEvent(index, event) }
        }
    }

    /// Whether two songs are sounding together now. `PlayerModel`'s current song is already the new
    /// one; the old one is still audible, fading (for C20's levels).
    public var isOverlapping: Bool { outgoing != nil }
    /// Which child plays the current song (for the live test).
    var activeIndex: Int { active }

    public var hasItem: Bool { children[active].hasItem }
    /// The current song's: during an overlap, the new song's (C20 shows its levels).
    public var currentTime: TimeInterval? { children[active].currentTime }

    public var volume: Float {
        get { gain }
        set {
            gain = newValue
            applyVolumes()
        }
    }

    // MARK: Commands

    public func load(_ url: URL, start: TimeInterval, next: URL?) {
        endOverlap()
        dropPlan()
        cancelFade()
        fadeLevel = 1
        wantsPlay = false
        durations[active] = nil
        applyVolumes()
        children[active].load(url, start: start, next: next)
    }

    public func setNext(_ url: URL?, crossfade: Crossfade?) {
        guard let url, let crossfade, crossfade.length > 0 else {
            dropPlan()
            children[active].setNext(url)
            return
        }
        children[active].setNext(nil)
        dropPlan()
        plan = (url, crossfade)
    }

    public func advanceToNext() {
        endOverlap()
        if isFadingOut {
            // Next during a pause's fade: the pause comes first, so the next song isn't heard.
            cancelFade()
            isFadingOut = false
            children[active].pause()
        }
        children[active].advanceToNext()
    }

    /// Both players, rebuilt, with nothing loaded.
    public func resetMediaServices() {
        stop()
        for child in children { child.resetMediaServices() }
    }

    public func play(fadeIn: TimeInterval) {
        wantsPlay = true
        isFadingOut = false
        cancelFade()
        if fadeIn > 0 {
            if isSounding(active) {
                // Back up from wherever a fade-out had got to.
                ramp(to: 1, over: fadeIn * (1 - fadeLevel))
            } else {
                fadeLevel = 0
                pendingFadeIn = fadeIn
            }
        } else {
            fadeLevel = 1
        }
        applyVolumes()
        children[active].play()
    }

    public func pause(fadeOut: TimeInterval) {
        wantsPlay = false
        cancelFade()
        guard fadeOut > 0, isSounding(active), fadeLevel > 0 else {
            endOverlap()
            children[active].pause()
            return
        }
        // An overlap fades out with it (both songs together), and ends at the pause.
        isFadingOut = true
        ramp(to: 0, over: fadeOut * fadeLevel) { [weak self] in
            guard let self else { return }
            isFadingOut = false
            endOverlap()
            children[active].pause()
        }
    }

    public func stop() {
        endOverlap()
        dropPlan()
        cancelFade()
        fadeLevel = 1
        wantsPlay = false
        durations = [nil, nil]
        children[idle].stop()
        children[active].stop()
    }

    public func seek(to seconds: TimeInterval) {
        endOverlap()
        children[active].seek(to: seconds)
    }

    public func setRate(_ rate: Float, preservesPitch: Bool) {
        self.rate = rate
        for child in children { child.setRate(rate, preservesPitch: preservesPitch) }
    }

    // MARK: What the children report

    private func childEvent(_ index: Int, _ event: AudioEngineEvent) {
        switch event {
        case .playing(let value): playing[index] = value
        case .buffering(let value): buffering[index] = value
        case .duration(let seconds): durations[index] = seconds
        case .advanced: durations[index] = nil
        default: break
        }
        guard index == active else {
            // The old song, fading out, or the next one waiting: nobody hears about them. The old
            // one ending or failing ends the overlap; the waiting one failing means no crossfade, and
            // the current song ends into the next as if crossfade were off.
            switch event {
            case .ended, .failed:
                if index == outgoing { endOverlap() } else if isPreloaded { isPreloaded = false; plan = nil }
            default:
                break
            }
            return
        }
        switch event {
        case .position(let seconds):
            onEvent?(event)
            checkPlan(at: seconds)
        case .playing(true) where isFadingOut:
            // Still sounding while it fades to the pause the player already shows.
            return
        case .playing(false):
            if isFadingOut {
                // The system stopped it first.
                cancelFade()
                isFadingOut = false
            }
            onEvent?(event)
        case .failed:
            endOverlap()
            onEvent?(event)
        default:
            onEvent?(event)
        }
        if pendingFadeIn != nil, case .playing = event { startPendingFadeInSoon() }
        if pendingFadeIn != nil, case .buffering = event { startPendingFadeInSoon() }
    }

    private func isSounding(_ index: Int) -> Bool {
        playing[index] && !buffering[index]
    }

    // MARK: The overlap

    private func checkPlan(at seconds: TimeInterval) {
        guard let plan, outgoing == nil else { return }
        let duration = durations[active] ?? plan.crossfade.listedDuration
        guard duration > 0 else { return }
        let start = duration - plan.crossfade.length * Double(rate)
        if !isPreloaded, seconds >= start - Self.preloadLead * Double(rate) {
            isPreloaded = true
            durations[idle] = nil
            children[idle].load(plan.url, start: 0, next: nil)
            children[idle].volume = 0
        }
        // Ticks come every quarter of a song-second: half a tick early puts the start on time on average.
        guard seconds >= start - Self.tickLead, wantsPlay, !isFadingOut, isPreloaded else { return }
        // A seek may have landed inside the fade: it lasts only as long as the song has left.
        let length = min(plan.crossfade.length, max(duration - seconds, 0) / Double(rate))
        beginOverlap(length: length)
    }

    private func beginOverlap(length: TimeInterval) {
        let old = active
        let oldGain = gain
        outgoing = old
        outgoingShare = 1
        active = idle
        plan = nil
        isPreloaded = false
        mix = 0
        applyVolumes()
        children[active].play()
        onEvent?(.advanced)
        // The player has set the new song's volume by now: the old one keeps its own, as a share of it.
        outgoingShare = gain > 0 ? oldGain / gain : 1
        applyVolumes()
        // The waiting song's length was held back while it waited.
        if let duration = durations[active] { onEvent?(.duration(duration)) }
        guard length > 0 else {
            endOverlap()
            return
        }
        let clock = ContinuousClock()
        let started = clock.now
        mixTask = Task { [weak self, step] in
            while !Task.isCancelled {
                try? await Task.sleep(for: step)
                guard let self, !Task.isCancelled else { return }
                let elapsed = (clock.now - started) / .seconds(1)
                mix = min(elapsed / length, 1)
                applyVolumes()
                if mix >= 1 {
                    endOverlap()
                    return
                }
            }
        }
    }

    /// The old song stops and the new one plays at its full volume.
    private func endOverlap() {
        mixTask?.cancel()
        mixTask = nil
        mix = 1
        guard let old = outgoing else { return }
        outgoing = nil
        durations[old] = nil
        children[old].stop()
        applyVolumes()
    }

    private func dropPlan() {
        if isPreloaded { children[idle].stop() }
        isPreloaded = false
        plan = nil
    }

    // MARK: Volumes and fades

    private func applyVolumes() {
        let fade = Float(fadeLevel)
        children[active].volume = gain * Float(sin(mix * .pi / 2)) * fade
        if let outgoing {
            children[outgoing].volume = min(gain * outgoingShare, 1) * Float(cos(mix * .pi / 2)) * fade
        }
    }

    private func cancelFade() {
        fadeTask?.cancel()
        fadeTask = nil
        pendingFadeIn = nil
    }

    /// The fade-in starts once the audio makes sound, so a song still buffering doesn't use it up in
    /// silence. Checked on the next turn: a child reports playing and buffering one after the other.
    private func startPendingFadeInSoon() {
        Task { [weak self] in
            guard let self, let length = pendingFadeIn, isSounding(active), wantsPlay else { return }
            pendingFadeIn = nil
            ramp(to: 1, over: length)
        }
    }

    /// Moves `fadeLevel` in a straight line to `target`.
    private func ramp(to target: Double, over length: TimeInterval, then finish: (@MainActor () -> Void)? = nil) {
        fadeTask?.cancel()
        let from = fadeLevel
        guard length > 0 else {
            fadeLevel = target
            applyVolumes()
            finish?()
            return
        }
        let clock = ContinuousClock()
        let started = clock.now
        fadeTask = Task { [weak self, step] in
            while !Task.isCancelled {
                try? await Task.sleep(for: step)
                guard let self, !Task.isCancelled else { return }
                let t = min((clock.now - started) / .seconds(1) / length, 1)
                fadeLevel = from + (target - from) * t
                applyVolumes()
                if t >= 1 {
                    fadeTask = nil
                    finish?()
                    return
                }
            }
        }
    }
}

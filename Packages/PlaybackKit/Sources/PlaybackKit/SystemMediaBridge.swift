@preconcurrency import AVFoundation
@preconcurrency import MediaPlayer
import SubsonicKit
import UIKit

/// Connects the player to iOS: the audio session, the lock screen and Control Center (what's showing
/// and its buttons), and interruptions and route changes. Flutter: `audio_service` and `audio_session`.
@MainActor
public final class SystemMediaBridge {
    private let player: PlayerModel
    private let artwork: @MainActor (Song) async -> UIImage?
    private var artworkSongID: String?
    private var artworkImage: UIImage?
    private var artworkTask: Task<Void, Never>?
    private var sessionTokens: [NotificationCenter.ObservationToken] = []
    private var routeObserver: (any NSObjectProtocol)?
    private var interruptionObserver: (any NSObjectProtocol)?
    private var resetObserver: (any NSObjectProtocol)?

    /// - Parameter artwork: finds a song's cover for the lock screen.
    public init(player: PlayerModel, artwork: @escaping @MainActor (Song) async -> UIImage?) {
        self.player = player
        self.artwork = artwork
        Self.setUpSession()
        player.activateSession = { try? AVAudioSession.sharedInstance().setActive(true) }
        player.onNowPlayingChange = { [weak self] in self?.update() }
        observeSession()
        registerRemoteCommands()
        publishModes()
    }

    isolated deinit {
        sessionTokens.forEach(NotificationCenter.default.removeObserver)
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let resetObserver { NotificationCenter.default.removeObserver(resetObserver) }
    }

    /// Plays with the silent switch on, and in the background. Flutter: `AudioSessionConfiguration.music`.
    private static func setUpSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    // MARK: What's showing

    private func update() {
        publishModes()
        guard let song = player.currentSong else {
            artworkTask?.cancel()
            artworkSongID = nil
            artworkImage = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }
        if song.id != artworkSongID {
            artworkSongID = song.id
            artworkImage = nil
            loadArtwork(for: song)
        }
        publish(song)
    }

    private func publish(_ song: Song) {
        var info = NowPlayingInfo.make(
            song: song,
            duration: player.duration,
            position: player.position,
            // Waiting for audio, the clock holds still (the buttons still show playing).
            isPlaying: player.isPlaying && !player.isLoading,
            speed: player.playbackSpeed
        )
        if let artworkImage {
            info[MPMediaItemPropertyArtwork] = Self.makeArtwork(artworkImage)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = player.isPlaying ? .playing : .paused
    }

    private func loadArtwork(for song: Song) {
        artworkTask?.cancel()
        artworkTask = Task {
            let image = await artwork(song)
            guard !Task.isCancelled, song.id == artworkSongID, let image else { return }
            artworkImage = image
            if let current = player.currentSong { publish(current) }
        }
    }

    /// What the system's repeat and shuffle buttons show (CarPlay, the lock screen): the player's.
    private func publishModes() {
        let center = MPRemoteCommandCenter.shared()
        center.changeRepeatModeCommand.currentRepeatType = switch player.repeatMode {
        case .off: .off
        case .one: .one
        case .all: .all
        }
        center.changeShuffleModeCommand.currentShuffleType = player.isShuffled ? .items : .off
    }

    /// `nonisolated`, because the system asks for the image off the main thread: a closure made on
    /// the main actor would crash there.
    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    // MARK: The lock screen's buttons

    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        // The same set as Flutter: no skip-by-seconds buttons, which would replace next and previous.
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false

        Self.register(center.playCommand) { [weak self] in self?.player.play() }
        Self.register(center.pauseCommand) { [weak self] in self?.player.pause() }
        Self.register(center.togglePlayPauseCommand) { [weak self] in self?.player.playOrPause() }
        Self.register(center.stopCommand) { [weak self] in self?.player.stop() }
        Self.register(center.nextTrackCommand) { [weak self] in self?.player.skipNext() }
        Self.register(center.previousTrackCommand) { [weak self] in self?.player.skipPrevious() }
        Self.registerSeek(center.changePlaybackPositionCommand) { [weak self] seconds in
            self?.player.seek(to: seconds)
        }
        Self.registerRepeat(center.changeRepeatModeCommand) { [weak self] mode in
            self?.player.changeRepeat(mode)
        }
        Self.registerShuffle(center.changeShuffleModeCommand) { [weak self] isOn in
            self?.player.toggleShuffle(forceValue: isOn)
        }
    }

    // `nonisolated`, for the same reason as `makeArtwork`.
    private nonisolated static func register(
        _ command: MPRemoteCommand,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) {
        command.isEnabled = true
        command.addTarget { @Sendable _ in
            Task { @MainActor in action() }
            return .success
        }
    }

    private nonisolated static func registerSeek(
        _ command: MPChangePlaybackPositionCommand,
        _ action: @escaping @MainActor @Sendable (TimeInterval) -> Void
    ) {
        command.isEnabled = true
        command.addTarget { @Sendable event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor in action(seconds) }
            return .success
        }
    }

    private nonisolated static func registerRepeat(
        _ command: MPChangeRepeatModeCommand,
        _ action: @escaping @MainActor @Sendable (RepeatMode) -> Void
    ) {
        command.isEnabled = true
        command.addTarget { @Sendable event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let mode: RepeatMode = switch event.repeatType {
            case .off: .off
            case .one: .one
            default: .all
            }
            Task { @MainActor in action(mode) }
            return .success
        }
    }

    private nonisolated static func registerShuffle(
        _ command: MPChangeShuffleModeCommand,
        _ action: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        command.isEnabled = true
        command.addTarget { @Sendable event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            let isOn = event.shuffleType != .off
            Task { @MainActor in action(isOn) }
            return .success
        }
    }

    // MARK: Interruptions and route changes

    private func observeSession() {
        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter.default
        sessionTokens = [
            center.addObserver(of: session, for: .didBecomeInactive) { [weak self] message in
                if case .systemInterruption = message.deactivationResult {
                    self?.player.handleInterruptionBegan()
                }
            },
            center.addObserver(of: session, for: .resumptionRecommendation) { [weak self] message in
                self?.player.handleInterruptionEnded(shouldResume: message.recommendation == .shouldResume)
            },
        ]
        routeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard SystemMediaBridge.isOutputLost(notification.userInfo) else { return }
            Task { @MainActor in self?.player.handleOutputLost() }
        }
        // The system's media services restarted: every player and the session's set-up are gone.
        resetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                SystemMediaBridge.setUpSession()
                self?.player.handleMediaServicesReset()
            }
        }
        // iOS 27 deprecated this for the two above, but the simulator can't fake a phone call, so
        // they're unproven here. The player copes with hearing the same thing twice. Check on the
        // first phone build, and drop this if the new ones arrive (see `docs/gotchas.md`).
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let change = SessionInterruption(userInfo: notification.userInfo)
            Task { @MainActor in
                switch change {
                case .began: self?.player.handleInterruptionBegan()
                case .ended(let shouldResume): self?.player.handleInterruptionEnded(shouldResume: shouldResume)
                case nil: break
                }
            }
        }
    }

    /// Headphones came out, or the Bluetooth speaker went away.
    nonisolated static func isOutputLost(_ userInfo: [AnyHashable: Any]?) -> Bool {
        guard let raw = userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return false }
        return AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
    }
}

/// What the older interruption notification says.
enum SessionInterruption: Equatable, Sendable {
    case began
    case ended(shouldResume: Bool)

    init?(userInfo: [AnyHashable: Any]?) {
        guard let raw = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return nil }
        switch type {
        case .began:
            self = .began
        case .ended:
            let options = AVAudioSession.InterruptionOptions(
                rawValue: userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            )
            self = .ended(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return nil
        }
    }
}

/// The lock screen's text and timing.
enum NowPlayingInfo {
    /// `speed` is the rate the lock screen's clock runs at while playing; the default rate stays 1.
    static func make(
        song: Song, duration: TimeInterval, position: TimeInterval, isPlaying: Bool, speed: Double = 1
    ) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyPlaybackDuration: duration > 0 ? duration : TimeInterval(song.duration ?? 0),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artist = song.artist { info[MPMediaItemPropertyArtist] = artist }
        if let album = song.album { info[MPMediaItemPropertyAlbumTitle] = album }
        return info
    }
}

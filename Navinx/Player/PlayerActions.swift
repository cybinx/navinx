import PlaybackKit
import SubsonicKit
import SwiftUI
import UIKit

/// The screens' ways of starting music that have to fetch the songs first, with Flutter's messages.
extension PlayerModel {
    /// A cover's play disc (Flutter `playNewTabAlbum`). Starting a whole album is the Play button (D23).
    /// Offline, the album's downloaded songs (C10).
    func playAlbum(_ album: Album, client: SubsonicClient?, toasts: ToastCenter, downloads: DownloadModel? = nil) async {
        do {
            guard let client else {
                let songs = OfflineLogic.sortedTracks(downloads?.songsByAlbum[album.id] ?? [])
                guard !songs.isEmpty else { throw SubsonicError.network }
                playInOrder(songs)
                return
            }
            let songs = try await client.albumSongs(albumID: album.id)
            guard !songs.isEmpty else { throw SubsonicError.invalidResponse }
            playInOrder(songs)
        } catch is CancellationError {
        } catch {
            toasts.show("Error loading songs")
        }
    }

    /// A playlist cover's play disc (Flutter `_playPlaylist`). Offline, its downloaded songs (C10).
    func playPlaylist(_ playlist: Playlist, client: SubsonicClient?, toasts: ToastCenter, downloads: DownloadModel? = nil) async {
        do {
            guard let client else {
                let songs = (downloads?.playlist(id: playlist.id)?.songs ?? []).filter { downloads?.isDownloaded($0.id) == true }
                guard !songs.isEmpty else { throw SubsonicError.network }
                playInOrder(songs)
                return
            }
            let songs = try await client.playlist(id: playlist.id).songs ?? []
            guard !songs.isEmpty else { throw SubsonicError.invalidResponse }
            playInOrder(songs)
        } catch is CancellationError {
        } catch {
            toasts.show("Error loading songs")
        }
    }

    /// "Add all to queue" on the album and playlist pages.
    func queueUpAll(_ songs: [Song], toasts: ToastCenter) {
        queueUpAll(songs)
        toasts.show(songs.count == 1 ? "1 song added to queue" : "\(songs.count) songs added to queue")
    }

    /// The playlist options' "Add all to queue", which has to fetch the songs first. As in Flutter,
    /// an empty playlist or a failed fetch does nothing.
    func addPlaylistToQueue(_ playlist: Playlist, client: SubsonicClient?, toasts: ToastCenter) async {
        guard let songs = try? await client?.playlist(id: playlist.id).songs, !songs.isEmpty else { return }
        queueUpAll(songs, toasts: toasts)
    }
}

extension SystemMediaBridge {
    /// The bridge for the app, with lock-screen covers from the shared image cache.
    static func forApp(player: PlayerModel, account: AccountModel) -> SystemMediaBridge {
        SystemMediaBridge(player: player) { song in
            // Flutter's size for the lock screen; a downloaded cover first.
            let local = OfflineCovers.shared.file(for: song.coverArt)
            guard let url = local ?? account.client?.coverArtURL(song.coverArt ?? song.id, size: 800) else { return nil }
            return await ArtworkCache.shared.image(url: url, maxPixel: 800)
        }
    }
}

/// Flutter `GlassArtPlayButton`: the 34 pt glass play disc in a cover's corner.
struct ArtPlayDisc: View {
    /// The New tab's tiles use 32.
    var size: CGFloat = 34
    let action: () -> Void

    var body: some View {
        Button("Play", systemImage: "play.fill", action: action)
            .labelStyle(.iconOnly)
            .font(.system(size: 14))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .contentShape(.circle)
            .appGlass(in: .circle, interactive: true)
            .buttonStyle(.plain)
            .padding(8)
    }
}

/// Flutter `AnimatedEqualizer`: three bars, standing still when paused. Flutter's are a made-up loop;
/// these follow the song (C20, D89): bass, middle and treble from the server's levels, read at
/// the player's position, so seeks, the speed and a crossfade follow. Until a song's levels arrive
/// (or with none, or in Low Power Mode) they run the loop, then blend into the levels. With Reduce
/// Motion they stand still.
struct LevelBars: View {
    let color: Color
    let isPlaying: Bool

    @Environment(PlayerModel.self) private var player
    @Environment(\.levelMeter) private var meter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Reduce Motion's still bars.
    private static let still: [CGFloat] = [10, 16, 7]

    var body: some View {
        Group {
            if reduceMotion {
                bars { Self.still[$0] }
            } else {
                // 30 frames a second: the levels' own rate (the old loop ran at the display's 120).
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying)) { context in
                    let real = realLevels(at: context.date)
                    bars { bar in Self.height(bar: bar, at: context.date, real: real) }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func bars(height: @escaping (Int) -> CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 3, height: height(bar))
            }
        }
        .frame(height: 16, alignment: .bottom)
    }

    /// The current song's levels now, unless Low Power Mode is on (D89: the loop).
    private func realLevels(at date: Date) -> (levels: SIMD3<Float>, weight: Float)? {
        guard let meter, let song = player.currentSong, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return nil }
        // During a crossfade the player's song is already the new one: its levels show (C19's overlap).
        return meter.sample(songID: song.id, at: player.playbackTime, date: date)
    }

    /// Between 4 and 16 pt: the loop blended into the levels by their weight.
    private static func height(bar: Int, at date: Date, real: (levels: SIMD3<Float>, weight: Float)?) -> CGFloat {
        let loop = loop(bar: bar, at: date)
        guard let real else { return 4 + 12 * loop }
        let weight = Double(real.weight)
        return 4 + 12 * (loop * (1 - weight) + Double(real.levels[bar]) * weight)
    }

    /// The made-up loop: up and back down over twice Flutter's 300, 400 and 500 ms.
    private static func loop(bar: Int, at date: Date) -> Double {
        let half = 0.3 + Double(bar) * 0.1
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: half * 2) / half
        return phase <= 1 ? phase : 2 - phase
    }
}

/// Flutter `SwipeableSongTile`: dragging a row right past 72 pt adds it to the queue, and the row
/// springs back. It's a UIKit recognizer so it can decline vertical drags and leave them to scrolling.
struct QueueSwipe: ViewModifier {
    let isEnabled: Bool
    let action: () -> Void

    private static let commitDistance: CGFloat = 72
    private static let maximum: CGFloat = 110

    @State private var offset: CGFloat = 0
    @State private var isPastThreshold = false

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .offset(x: offset)
                .background(alignment: .leading) { reveal }
                .gesture(HorizontalPan(direction: .right, onChange: changed) { _ in ended() })
        } else {
            content
        }
    }

    @ViewBuilder
    private var reveal: some View {
        if offset > 0 {
            let progress = min(offset / Self.commitDistance, 1)
            RoundedRectangle(cornerRadius: 10)
                .fill(Palette.accent.opacity(isPastThreshold ? 1 : 0.18))
                .frame(width: offset)
                .overlay(alignment: .leading) {
                    if offset > 15 {
                        Image(systemName: "text.badge.plus")
                            .font(.system(size: 22))
                            .foregroundStyle(isPastThreshold ? Color.white : Palette.accent)
                            .scaleEffect(0.6 + 0.5 * progress + (isPastThreshold ? 0.15 : 0))
                            .padding(.leading, 18)
                    }
                }
        }
    }

    private func changed(_ translation: CGFloat) {
        offset = min(max(translation, 0), Self.maximum)
        let isPast = offset >= Self.commitDistance
        if isPast, !isPastThreshold {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        isPastThreshold = isPast
    }

    private func ended() {
        if isPastThreshold {
            action()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        isPastThreshold = false
        withAnimation(.spring(duration: 0.26, bounce: 0.3)) { offset = 0 }
    }
}

/// Flutter's `Dismissible`, swiping left: the red shows behind the row, and past 40 % of its width, or
/// on a fast flick, the row is done with. A row that asks a question first (`slidesAway` false) comes
/// back at once, so cancelling leaves it in place; Flutter's stays gone and throws an error.
struct SwipeToRemove: ViewModifier {
    let systemImage: String
    var slidesAway = true
    let action: () -> Void

    /// Flutter's `dismissThreshold` and its fling speed.
    private static let threshold: CGFloat = 0.4
    private static let flingSpeed: CGFloat = 700

    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background(alignment: .trailing) {
                if offset < 0 {
                    Color.red
                        .frame(width: -offset)
                        .overlay(alignment: .trailing) {
                            Image(systemName: systemImage)
                                .foregroundStyle(.white)
                                .padding(.trailing, 20)
                        }
                        .clipped()
                }
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
            .gesture(HorizontalPan(direction: .left, onChange: { offset = min($0, 0) }, onEnd: ended))
            .accessibilityAction(named: "Remove", action)
    }

    private func ended(velocity: CGFloat) {
        guard -offset > width * Self.threshold || velocity < -Self.flingSpeed else {
            withAnimation(.spring(duration: 0.26, bounce: 0.3)) { offset = 0 }
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard slidesAway else {
            withAnimation(.spring(duration: 0.26, bounce: 0.3)) { offset = 0 }
            action()
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            offset = -width
        } completion: {
            action()
            offset = 0
        }
    }
}

/// A pan that only begins for a drag in one direction, so vertical drags are left to scrolling.
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    enum Direction { case left, right }

    let direction: Direction
    let onChange: (CGFloat) -> Void
    /// Given the speed sideways, in points a second.
    let onEnd: (CGFloat) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let direction: Direction

        init(direction: Direction) {
            self.direction = direction
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            let isRightWay = direction == .right ? velocity.x > 0 : velocity.x < 0
            return isRightWay && abs(velocity.x) > abs(velocity.y)
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator(direction: direction) }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .changed:
            onChange(recognizer.translation(in: recognizer.view).x)
        case .ended, .cancelled, .failed:
            onEnd(recognizer.velocity(in: recognizer.view).x)
        default:
            break
        }
    }
}

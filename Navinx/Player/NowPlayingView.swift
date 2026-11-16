import Lyrics
import PlaybackKit
import SubsonicKit
import SwiftUI
import UIKit

/// Flutter `NowPlayingScreen` in its glass look, always dark: three pages side by side (the player,
/// the lyrics and the queue) under one top bar. Star ratings show under the title when Settings
/// turns them on (C22).
struct NowPlayingView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(AccountModel.self) private var account
    @Environment(DownloadModel.self) private var downloads
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    /// The open and close (C26); nil in previews.
    @Environment(PlayerOpening.self) private var transition: PlayerOpening?
    @Environment(\.nowPlayingHidesCover) private var hidesCover
    @Environment(\.scenePhase) private var scenePhase
    /// Set on the Duo's inner display, where the page is a half beside the app (C30 bug 17).
    @Environment(\.nowPlayingArea) private var area
    @AppStorage(LyricsSettings.holdsScreenAwake) private var keepsScreenOn = true
    @AppStorage(LyricsSettings.showsCurrentLineCapsule) private var showsLyricPill = false
    @AppStorage(PlayerDisplayOptions.showsRatingStars) private var showsStarRatings = false

    /// What `loadCover` has decoded. What's already in memory is drawn without waiting for it
    /// (`NowPlayingCovers`), so the first frame has the cover and the backdrop.
    @State private var cover: UIImage?
    @State private var tinyCover: UIImage?
    @State private var coverFailed = false
    @State private var songSheets = SongSheets()
    /// The page showing: 0 the player, 1 the lyrics, 2 the queue.
    @State private var scrolledPage: Int? = 0
    /// The current song's lyrics; nil while loading.
    @State private var lyrics: [LyricLine]?
    /// The song `lyrics` are for.
    @State private var lyricsSongID: String?
    /// The lyrics' translation (C38), one for the app.
    @State private var translation = LyricsTranslationModel.shared

    /// What the cover or the lyrics are loaded for.
    private struct LoadKey: Hashable {
        var id: String?
        var isOnline: Bool
    }

    private var page: Int { scrolledPage ?? 0 }

    /// The cover and the backdrop to draw now: the cached ones for the current song, else the last
    /// ones, which stay up until the new song's are ready.
    private var cachedCovers: (cover: UIImage?, tiny: UIImage?) {
        NowPlayingCovers.cached(for: player.currentSong?.coverArt, client: account.client)
    }

    var body: some View {
        let backdrop = cachedCovers.tiny ?? tinyCover
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let metrics = NowPlayingMetrics(
                width: proxy.size.width + insets.leading + insets.trailing,
                height: proxy.size.height + insets.top + insets.bottom,
                top: insets.top,
                bottom: insets.bottom
            )
            let isLandscape = metrics.width > metrics.height
            pages(proxy, metrics: metrics, insets: insets, isLandscape: isLandscape)
        }
        .background { CoverWash(image: backdrop, brightness: NowPlayingCovers.brightness(of: backdrop)) }
        .overlay(alignment: .bottom) {
            // The root view's toasts stay behind this screen. Beside the app on the Duo it's in the root
            // view's own window, under its toasts, so they aren't drawn twice (C32).
            if area == nil, let toast = toasts.current {
                ToastView(toast: toast)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: toasts.current)
        // A pull down in the lyrics or the queue scrolls them; only the player's page closes (Flutter).
        .onChange(of: page, initial: true) { transition?.isOnPlayerPage = page == 0 }
        .songSheets(songSheets)
        // Both again when the server comes back (C32): offline, a cover not downloaded has no address and
        // lyrics not saved can't be asked for.
        .task(id: LoadKey(id: player.currentSong?.coverArt, isOnline: account.client != nil)) { await loadCover() }
        .task(id: LoadKey(id: player.currentSong?.id, isOnline: account.client != nil)) { await loadLyrics() }
        // Each new lyric is checked for a translation, and translated if the button was left on (C38).
        .onChange(of: lyrics, initial: true) { translation.show(songID: lyricsSongID, lines: lyrics) }
        .onAppear {
            translation.onFailure = { [toasts] in toasts.show("Translation isn't available for these lyrics") }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-UITestLyricsPage") { scrolledPage = 1 }
            #endif
        }
        // Nothing left to show.
        .onChange(of: player.currentSong == nil) { _, isEmpty in
            if isEmpty { close() }
        }
        .onChange(of: page) { syncKeepingScreenOn() }
        .onChange(of: scenePhase) { syncKeepingScreenOn() }
        .onChange(of: keepsScreenOn) { syncKeepingScreenOn() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        // Always dark. Beside the app on the Duo it's dark on its own: a preference would turn the app too.
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(area == nil ? .dark : nil)
    }

    /// Back into the mini-player, with the animation (C26).
    private func close() {
        if let transition { transition.close() } else { dismiss() }
    }

    /// Flutter `_syncLyricsWakelock`: the screen stays on while the lyrics are showing.
    private func syncKeepingScreenOn() {
        UIApplication.shared.isIdleTimerDisabled = page == 1 && keepsScreenOn && scenePhase == .active
    }

    /// Flutter's 300 ms slide between pages.
    private func go(toPage newPage: Int) {
        withAnimation(.easeInOut(duration: 0.3)) { scrolledPage = newPage }
    }

    /// The three pages side by side, which swipe: the player, the lyrics and the queue.
    private func pages(_ proxy: GeometryProxy, metrics: NowPlayingMetrics, insets: EdgeInsets, isLandscape: Bool) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                Group {
                    if isLandscape {
                        landscape(metrics, insets: insets)
                    } else {
                        portrait(metrics)
                    }
                }
                .pageFrame(proxy, insets: insets)
                .id(0)
                LyricsPage(
                    lines: lyrics,
                    songID: player.currentSong?.id,
                    metrics: metrics,
                    isLandscape: isLandscape,
                    isActive: page == 1
                )
                .pageFrame(proxy, insets: insets)
                .id(1)
                QueuePage(metrics: metrics, isLandscape: isLandscape, isActive: page == 2)
                    .pageFrame(proxy, insets: insets)
                    .id(2)
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrolledPage)
        .scrollIndicators(.hidden)
        // Paging goes by the scroll view's own width, so it spans the screen and each page keeps
        // clear of landscape's margins itself.
        .ignoresSafeArea(.container, edges: .horizontal)
        // The queue runs up behind the top bar.
        .scrollClipDisabled()
        .overlay(alignment: .top) { topBar(metrics, insets: insets, isLandscape: isLandscape) }
    }

    // MARK: Layouts

    private func portrait(_ metrics: NowPlayingMetrics) -> some View {
        VStack(spacing: 0) {
            artwork
                .padding(.horizontal, metrics.artHorizontal)
                .padding(.vertical, metrics.artVertical)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, metrics.topBarGap)
            lyricPill(isSmall: metrics.isSmall, isLandscape: false)
            titleRow(
                titleSize: metrics.isSmall ? 20 : 24,
                artistSize: metrics.isSmall ? 15 : 18,
                spacing: metrics.isSmall ? 2 : 4
            )
            .padding(.horizontal, 32)
            .padding(.vertical, metrics.titleVertical)
            starRow(isCompact: metrics.isSmall)
                .padding(.horizontal, 32)
                .padding(.vertical, metrics.isSmall ? 0 : 2)
            PlaybackProgress()
                .padding(.horizontal, 32)
                .padding(.bottom, metrics.sliderBottom)
            controls
                .padding(.horizontal, 32)
                .padding(.bottom, metrics.controlsBottom)
            VolumeBar()
                .padding(.horizontal, 32)
            bottomActions
                .padding(.bottom, metrics.bottomActions)
        }
    }

    /// Flutter's split: 5 parts artwork, 16 pt, 6 parts controls.
    private func landscape(_ metrics: NowPlayingMetrics, insets: EdgeInsets) -> some View {
        GeometryReader { proxy in
            let leading: CGFloat = insets.leading > 0 ? 16 : 20
            let trailing: CGFloat = insets.trailing > 0 ? 16 : 20
            let part = (proxy.size.width - leading - trailing - 16) / 11

            HStack(spacing: 16) {
                VStack(spacing: 0) {
                    artwork
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .frame(maxHeight: .infinity)
                    lyricPill(isSmall: true, isLandscape: true)
                }
                .frame(width: part * 5)
                .frame(maxHeight: .infinity)
                VStack(spacing: 0) {
                    titleRow(titleSize: 19, artistSize: 14, spacing: 2)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 2)
                    starRow(isCompact: true)
                        .padding(.horizontal, 16)
                    PlaybackProgress()
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 4)
                    controls
                        .padding(.horizontal, 16)
                        .padding(.bottom, 2)
                    VolumeBar()
                        .padding(.horizontal, 16)
                        .padding(.bottom, 2)
                    bottomActions
                }
                .frame(maxWidth: 500)
                .frame(width: part * 6)
            }
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            .padding(.top, insets.top > 0 ? 44 : 48)
            .padding(.bottom, 4)
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private func lyricPill(isSmall: Bool, isLandscape: Bool) -> some View {
        if showsLyricPill, let lyrics, !lyrics.isEmpty {
            CurrentLineCapsule(lines: lyrics, isSmall: isSmall, isLandscape: isLandscape) { go(toPage: 1) }
        }
    }

    /// Flutter `_buildStarRatingRow`: only with Settings' switch on and a song (C22).
    @ViewBuilder
    private func starRow(isCompact: Bool) -> some View {
        if showsStarRatings, player.currentSong != nil {
            RatingStars(isCompact: isCompact)
        }
    }

    /// The handle and the top bar.
    private func topBar(_ metrics: NowPlayingMetrics, insets: EdgeInsets, isLandscape: Bool) -> some View {
        let hasTopInset = metrics.top > 0
        // Clear of the display's rounded corners where no safe area keeps it so (the Duo, C30 bug 18).
        let sides = NowPlayingCorners.topBarSides(
            top: insets.top,
            leading: insets.leading,
            trailing: insets.trailing,
            isLandscape: isLandscape,
            leadingIsHinge: area != nil
        )
        return ZStack(alignment: .top) {
            if !isLandscape {
                Capsule()
                    .fill(.white.opacity(0.4))
                    .frame(width: 36, height: 5)
                    .padding(.top, hasTopInset ? 8 : 16)
            }
            HStack {
                // On the lyrics and queue pages, ✕ goes back to the player.
                GlassCircleButton(
                    label: page == 0 ? "Close" : "Back",
                    systemImage: page == 0 ? "chevron.down" : "xmark",
                    size: 38,
                    iconSize: 15.5
                ) {
                    if page == 0 { close() } else { go(toPage: 0) }
                }
                .accessibilityIdentifier("nowPlayingClose")
                Spacer()
                // On the lyrics page, when they can be translated here (C38).
                if page == 1, translation.showsButton {
                    GlassCircleButton(
                        label: "Translate",
                        systemImage: "translate",
                        size: 38,
                        iconSize: 16,
                        color: translation.isLit ? Palette.accent : .white
                    ) { translation.toggle() }
                    .accessibilityValue(translation.isLit ? "On" : "Off")
                    .accessibilityIdentifier("lyricsTranslate")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                GlassMenuButton(label: "More", systemImage: "ellipsis", size: 38, iconSize: 16.5) {
                    NowPlayingMoreItems()
                }
                .accessibilityIdentifier("nowPlayingMore")
            }
            .padding(.leading, sides.leading)
            .padding(.trailing, sides.trailing)
            .padding(.top, isLandscape ? (hasTopInset ? 4 : 8) : (hasTopInset ? 14 : 22))
            .animation(.easeOut(duration: 0.25), value: page == 1 && translation.showsButton)
        }
    }

    /// Flutter `_buildArtwork`: smaller while paused, springing back on playing, with a sideways
    /// swipe for the next and previous song.
    private var artwork: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { coverImage }
            .clipShape(.rect(cornerRadius: 16))
            // Where the flying cover lands (C26), before the paused scale, which the flight adds.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { transition?.coverMoved(to: $0) }
            .shadow(color: .black.opacity(0.35), radius: 12, y: 10)
            .scaleEffect(player.isPlaying ? 1 : 0.86)
            .opacity(hidesCover ? 0 : 1)
            .animation(.timingCurve(0.34, 1.25, 0.64, 1, duration: 0.48), value: player.isPlaying)
            .contentShape(.rect)
            .accessibilityElement()
            .accessibilityLabel("Cover")
            .accessibilityIdentifier("nowPlayingCover")
            .gesture(SidewaysFling { speed in
                if speed < -250 {
                    player.skipNext()
                } else if speed > 250 {
                    player.skipPrevious()
                }
            })
    }

    @ViewBuilder
    private var coverImage: some View {
        if let cover = cachedCovers.cover ?? cover {
            Image(uiImage: cover).resizable().scaledToFill()
        } else if player.currentSong?.coverArt == nil {
            // The plain clef (D187) on the failed cover's ground, in its grey.
            Color(hex: 0x303030).overlay {
                Image("Logo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 64)
                    .foregroundStyle(.white.opacity(0.54))
            }
        } else if coverFailed {
            Color(hex: 0x303030).overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.54))
            }
        }
    }

    private func titleRow(titleSize: CGFloat, artistSize: CGFloat, spacing: CGFloat) -> some View {
        let song = player.currentSong
        let isStarred = song?.starred ?? false
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: spacing) {
                ScrollingLabel(text: song?.title ?? "", font: .system(size: titleSize, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("nowPlayingTitle")
                ArtistNames(
                    artists: song?.displayArtists ?? [],
                    font: .system(size: artistSize),
                    color: .white.opacity(0.75)
                )
                .accessibilityIdentifier("nowPlayingArtist")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            GlassCircleButton(
                label: isStarred ? "Remove from favorites" : "Add to favorites",
                systemImage: isStarred ? "heart.fill" : "heart",
                size: 36,
                iconSize: 14.5,
                color: isStarred ? Palette.accent : .white
            ) {
                Task { await player.toggleFavorite() }
            }
            GlassMenuButton(label: "Add to", systemImage: "plus", size: 36, iconSize: 15) {
                if let song { AddToItems(song: song) }
            }
            .accessibilityIdentifier("nowPlayingAddTo")
        }
    }

    /// Flutter `PlaybackControls` (glass): evenly spaced, with Next never disabled (D25). Here and
    /// throughout this screen, symbols are sized to match Flutter's glyphs as drawn: at the same
    /// point size, SF Symbols come out larger than Cupertino icons.
    private var controls: some View {
        let repeatOn = player.repeatMode != .off
        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            toggle("Shuffle", systemImage: "shuffle", isOn: player.isShuffled) { player.toggleShuffle() }
            Spacer(minLength: 0)
            GlassCircleButton(label: "Previous", systemImage: "backward.fill", size: 62, iconSize: 25, persistent: false) {
                player.skipPrevious()
            }
            .accessibilityIdentifier("nowPlayingPrevious")
            Spacer(minLength: 0)
            GlassCircleButton(
                label: player.isPlaying ? "Pause" : "Play",
                systemImage: player.isPlaying ? "pause.fill" : "play.fill",
                size: 76,
                iconSize: 37,
                persistent: false
            ) {
                player.playOrPause()
            }
            .accessibilityIdentifier("nowPlayingPlayPause")
            Spacer(minLength: 0)
            GlassCircleButton(label: "Next", systemImage: "forward.fill", size: 62, iconSize: 25, persistent: false) {
                player.skipNext()
            }
            .accessibilityIdentifier("nowPlayingNext")
            Spacer(minLength: 0)
            toggle(
                "Repeat",
                systemImage: player.repeatMode == .one ? "repeat.1" : "repeat",
                isOn: repeatOn
            ) {
                player.toggleRepeat()
            }
            Spacer(minLength: 0)
        }
    }

    private func toggle(_ label: String, systemImage: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        GlassCircleButton(
            label: label,
            systemImage: systemImage,
            size: 40,
            iconSize: 17,
            color: isOn ? Palette.accent : .white.opacity(0.6),
            persistent: isOn,
            action: action
        )
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityIdentifier("nowPlaying\(label)")
    }

    /// Flutter `NowPlayingBottomActions` (glass).
    private var bottomActions: some View {
        let idle = Color.white.opacity(0.7)
        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            RoutePickerButton()
                .frame(width: 38, height: 38)
                .accessibilityIdentifier("airPlay")
            Spacer(minLength: 0)
            GlassCircleButton(label: "Lyrics", systemImage: "quote.bubble", size: 44, iconSize: 19, color: idle, persistent: page == 1) {
                go(toPage: page == 1 ? 0 : 1)
            }
            .accessibilityIdentifier("nowPlayingLyrics")
            Spacer(minLength: 0)
            GlassCircleButton(label: "Queue", systemImage: "list.bullet", size: 44, iconSize: 19, color: idle, persistent: page == 2) {
                go(toPage: page == 2 ? 0 : 2)
            }
            .accessibilityIdentifier("nowPlayingQueue")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 12)
    }

    // MARK: Loading

    /// Flutter `_fetchLyrics`, for each new song. The page goes straight to its spinner; Flutter
    /// leaves the last song's lines up until the new ones arrive.
    private func loadLyrics() async {
        guard let song = player.currentSong else {
            lyrics = []
            lyricsSongID = nil
            return
        }
        // Back online, a song whose lyrics were found keeps them; only one with none asks again.
        if lyricsSongID == song.id, lyrics?.isEmpty == false { return }
        lyrics = nil
        lyricsSongID = song.id
        // A downloaded song's saved lyrics first; offline, nothing else (C10).
        let saved = downloads.savedLyrics(songID: song.id)
        let loader = LyricsLoader(client: account.client, saved: { _ in saved })
        let lines = await loader.lines(songID: song.id, artist: song.artist, title: song.title)
        guard !Task.isCancelled else { return }
        lyrics = lines
    }

    // MARK: The cover

    /// Keeps the last cover showing until the new one is ready.
    private func loadCover() async {
        // (The placeholder, like the last cover, stays up until the new one has loaded or failed.)
        guard let url = NowPlayingCovers.url(for: player.currentSong?.coverArt, client: account.client) else {
            cover = nil
            tinyCover = nil
            // A cover with no address (offline, not downloaded) shows the placeholder, as the mini-player does.
            coverFailed = player.currentSong?.coverArt != nil
            return
        }
        let image = await ArtworkCache.shared.image(url: url, maxPixel: NowPlayingCovers.coverPixels)
        guard !Task.isCancelled else { return }
        cover = image
        coverFailed = image == nil
        let tiny = await ArtworkCache.shared.image(url: url, maxPixel: NowPlayingCovers.backdropPixels)
        guard !Task.isCancelled else { return }
        tinyCover = tiny
    }
}

private extension View {
    /// One page of the three: the whole screen's width, with landscape's margins inside it.
    func pageFrame(_ proxy: GeometryProxy, insets: EdgeInsets) -> some View {
        padding(.leading, insets.leading)
            .padding(.trailing, insets.trailing)
            .frame(width: proxy.size.width + insets.leading + insets.trailing, height: proxy.size.height)
    }
}

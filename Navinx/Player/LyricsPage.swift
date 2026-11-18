import Lyrics
import PlaybackKit
import SwiftUI
// `translationTask` hands its non-Sendable session to a main-actor closure, and the session's methods
// run off it: the Translation module (Swift 5 mode) has no annotations for that. The session is used only
// inside the closure, one call at a time.
@preconcurrency import Translation

/// Flutter's lyrics settings (`PlayerUiSettingsService`, `StorageService`), with its keys and
/// defaults. Their switches are C11's; until then they stay at the defaults.
nonisolated enum LyricsSettings {
    static let softensOtherLines = "lyrics_blur_unfocused"
    static let alignment = "lyrics_alignment"
    static let glowsCurrentLine = "lyrics_glow_effect"
    static let holdsScreenAwake = "lyrics_keep_screen_on"
    static let showsCurrentLineCapsule = "player_show_live_lyric_under_artwork"
    static let lrclibFallback = "lrclib_fallback"
    /// Now playing's Translate button (C38); not in Flutter.
    static let translate = "lyrics_translate"

    /// Off until the user says yes (D179, unlike Flutter's on by default): the question on the lyrics
    /// page or the Settings switch. Downloads follow the same answer and never ask.
    static var usesLRCLib: Bool { usesLRCLib(in: .standard) }

    static func usesLRCLib(in defaults: UserDefaults) -> Bool {
        LyricsLookupPermission.allows(answer: defaults.object(forKey: lrclibFallback) as? Bool)
    }
}

/// Whether lyrics may be looked up on LRCLIB (D179): asked once, the first time the lyrics page shows a
/// song with none. The answer is `LyricsSettings.lrclibFallback`: absent until asked, then `true` or `false`.
nonisolated enum LyricsLookupPermission {
    static let title = "Look for lyrics online?"
    static let message = "Your server has no lyrics for this song. Navinx can look them up on LRCLIB (lrclib.net), a free public lyrics service. Only the artist and song title are sent. You can change this in Settings → Playback."
    static let allowTitle = "Look Up Lyrics"
    static let declineTitle = "Not Now"

    /// Never answered is no.
    static func allows(answer: Bool?) -> Bool { answer ?? false }

    /// The question shows only on the lyrics page, online, never answered, once the current song's
    /// lyrics have loaded (`lines` not nil) and came back empty.
    static func asks(answer: Bool?, isLyricsPageShowing: Bool, lines: [LyricLine]?, linesAreForCurrentSong: Bool, isOnline: Bool) -> Bool {
        answer == nil && isLyricsPageShowing && isOnline && linesAreForCurrentSong && lines?.isEmpty == true
    }
}

/// Flutter's lyrics page in `PageView`: a spinner, "No lyrics available", or the lines.
struct LyricsPage: View {
    /// Nil while loading.
    let lines: [LyricLine]?
    /// The song, so a new one starts the page afresh.
    let songID: String?
    let metrics: NowPlayingMetrics
    let isLandscape: Bool
    let isActive: Bool

    @State private var translation = LyricsTranslationModel.shared

    var body: some View {
        Group {
            if let lines, !lines.isEmpty {
                LyricsList(
                    timeline: LyricsTimeline(lines: lines),
                    translations: translation.isLit ? translation.translations : [:],
                    screenHeight: metrics.height,
                    isActive: isActive
                )
                .id(songID)
                .accessibilityIdentifier("lyricsList")
            } else if lines == nil {
                ProgressView()
                    .tint(.white)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("lyricsLoading")
            } else {
                Text("No lyrics available")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("noLyrics")
            }
        }
        // Flutter's `headerClearance`: the lines stop under the top bar.
        .padding(.top, isLandscape ? 44 : 64)
        // The system's language download, only when the Translate button asks for one (C38). This page lives
        // as long as now playing, and the session is used only inside the closure, never kept: a
        // `translationTask` session must not outlive its view.
        .translationTask(translation.downloadRequest) { session in
            do {
                try await session.prepareTranslation()
                translation.downloadFinished(succeeded: true)
            } catch {
                translation.downloadFinished(succeeded: false)
            }
        }
    }
}

/// Flutter `LyricsListView`: follows the song, centring the current line. A scroll by hand holds
/// that off for 4 seconds; a tap on a line goes there.
private struct LyricsList: View {
    let timeline: LyricsTimeline
    /// Each line's translation by its place in the lyric (C38); empty when off.
    let translations: [Int: String]
    let screenHeight: CGFloat
    let isActive: Bool

    @Environment(PlayerModel.self) private var player
    @AppStorage(LyricsSettings.alignment) private var alignment = "left"
    @AppStorage(LyricsSettings.softensOtherLines) private var softensOtherLines = false
    @AppStorage(LyricsSettings.glowsCurrentLine) private var glowsCurrentLine = true
    @State private var isScrollingByHand = false
    @State private var resumeTask: Task<Void, Never>?

    var body: some View {
        let time = player.position
        let moment = timeline.moment(at: time)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(timeline.items) { item in
                        row(item, moment: moment, time: time).id(item.id)
                    }
                }
                .padding(.vertical, screenHeight / 2)
            }
            .scrollIndicators(.hidden)
            .onScrollPhaseChange { old, new in
                if new == .interacting || new == .decelerating || old == .interacting || old == .decelerating {
                    scrolledByHand(proxy, moment: moment)
                }
            }
            .onChange(of: moment.item) { _, item in
                if !isScrollingByHand { scroll(proxy, to: item, animated: true) }
            }
            // Translations coming or going change every line's height: back to the current line.
            .onChange(of: translations) {
                if !isScrollingByHand { scroll(proxy, to: moment.item, animated: true) }
            }
            // Flutter stays at the top until the next line starts; this goes straight to the place.
            .onAppear { scroll(proxy, to: moment.item, animated: false) }
            .onChange(of: isActive) { _, isActive in
                if isActive, !isScrollingByHand { scroll(proxy, to: moment.item, animated: false) }
            }
            .onDisappear { resumeTask?.cancel() }
        }
    }

    @ViewBuilder
    private func row(_ item: LyricsTimeline.Item, moment: LyricsTimeline.Moment, time: TimeInterval) -> some View {
        switch item.kind {
        case .interlude:
            InterludeDots(timeLeft: item.end - time)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
        case .line(let line, let index):
            LyricLineView(
                text: line.text,
                translation: translations[index],
                state: timeline.state(ofLine: index, item: item, at: moment, time: time),
                distance: timeline.distance(ofLine: index, at: moment),
                isCentered: alignment == "center",
                blursUnfocused: softensOtherLines,
                glows: glowsCurrentLine
            )
            .contentShape(.rect)
            .onTapGesture { tapped(line) }
            // Only synced lines go anywhere when tapped.
            .accessibilityAddTraits(timeline.isUnsynced ? [] : .isButton)
        }
    }

    /// With no timings to go to, a tap does nothing (D41). Flutter jumps the song back to 0:00.
    private func tapped(_ line: LyricLine) {
        guard !timeline.isUnsynced else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        player.seek(to: line.start)
        resumeTask?.cancel()
        isScrollingByHand = false
    }

    private func scrolledByHand(_ proxy: ScrollViewProxy, moment: LyricsTimeline.Moment) {
        isScrollingByHand = true
        resumeTask?.cancel()
        resumeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            isScrollingByHand = false
            scroll(proxy, to: timeline.moment(at: player.position).item, animated: true)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to item: Int?, animated: Bool) {
        guard let item else { return }
        // Flutter's 600 ms `easeOutCubic`.
        withAnimation(animated ? .timingCurve(0.215, 0.61, 0.355, 1, duration: 0.6) : nil) {
            proxy.scrollTo(item, anchor: .center)
        }
    }
}

/// Flutter `LyricsLineWidget`. Its word-by-word drawing isn't carried over: nothing fills word timings.
/// A translation (C38) sits under its line, smaller and dimmer; the two take the line's look as one.
private struct LyricLineView: View {
    let text: String
    let translation: String?
    let state: LyricsTimeline.LineState
    let distance: Int
    let isCentered: Bool
    let blursUnfocused: Bool
    let glows: Bool

    private var opacity: Double {
        switch state {
        case .past: 0.35
        case .current: 1
        case .future: 0.30
        }
    }

    private var blur: CGFloat {
        guard blursUnfocused, state == .future else { return 0 }
        return min(max(CGFloat(distance) * 0.8, 0), 3)
    }

    var body: some View {
        let isCurrent = state == .current
        VStack(alignment: isCentered ? .center : .leading, spacing: 6) {
            Text(text)
                .font(.system(size: 24, weight: isCurrent ? .heavy : .bold))
                // Flutter's line heights: about 34 pt, and 36 pt for the current line.
                .lineSpacing(isCurrent ? 6.5 : 5)
            if let translation {
                Text(translation)
                    .font(.system(size: 17, weight: .semibold))
                    .lineSpacing(3)
                    .opacity(0.6)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: translation)
        .accessibilityElement(children: .combine)
        .multilineTextAlignment(isCentered ? .center : .leading)
        .foregroundStyle(.white.opacity(opacity))
        .shadow(color: .white.opacity(isCurrent && glows ? 0.6 : 0), radius: 8)
        .blur(radius: blur)
        .frame(maxWidth: .infinity, alignment: isCentered ? .center : .leading)
        .scaleEffect(isCurrent ? 1.05 : 1, anchor: isCentered ? .center : .leading)
        .padding(.vertical, isCurrent ? 15.5 : 14.5)
        .padding(.horizontal, 24)
        // Flutter's 250 ms `easeOutBack` for the scale and 300 ms cross-fade, as one.
        .animation(.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.25), value: isCurrent)
        .animation(.easeOut(duration: 0.3), value: opacity)
    }
}

/// Flutter `InterludeDotsWidget`: pulsing dots, going out one by one as the next line nears.
private struct InterludeDots: View {
    let timeLeft: TimeInterval

    var body: some View {
        let visible = LyricsTimeline.visibleDots(timeLeft: timeLeft)
        Group {
            if visible > 0 {
                TimelineView(.animation) { context in
                    let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
                    HStack(spacing: 14) {
                        ForEach(0..<3, id: \.self) { index in
                            if index < visible { dot(phase: (cycle + Double(index) * 0.33).truncatingRemainder(dividingBy: 1)) }
                        }
                    }
                }
                .frame(height: 40)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.5), value: visible)
        .accessibilityHidden(true)
    }

    private func dot(phase: Double) -> some View {
        let wave = (0.5 - 0.5 * abs(1 - phase * 2)) * 2
        return Circle()
            .fill(.white.opacity(0.3 + 0.7 * wave))
            .frame(width: 10, height: 10)
            .scaleEffect(0.7 + 0.8 * wave)
    }
}

/// Flutter `_buildLiveLyricPill` (off by default; C11's switch): the current line, under the cover.
struct CurrentLineCapsule: View {
    let lines: [LyricLine]
    let isSmall: Bool
    let isLandscape: Bool
    let onTap: () -> Void

    @Environment(PlayerModel.self) private var player

    var body: some View {
        if let text = LyricsTimeline.activeLine(in: lines, at: player.position)?.text.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            let compact = isSmall || isLandscape
            Button(action: onTap) {
                HStack(spacing: 8) {
                    Image(systemName: "quote.bubble.fill")
                        .font(.system(size: compact ? 11 : 12.5))
                        .foregroundStyle(Palette.accent.opacity(0.95))
                        .frame(width: compact ? 21 : 23, height: compact ? 21 : 23)
                        .background(Palette.accent.opacity(0.25), in: .circle)
                    Text(text)
                        .id(text)
                        .font(.system(size: compact ? 12.5 : 13.5, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .offset(y: 4)))
                    Image(systemName: "chevron.right")
                        .font(.system(size: compact ? 10 : 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .animation(.easeOut(duration: 0.25), value: text)
                .padding(.horizontal, compact ? 12 : 14)
                .padding(.vertical, compact ? 5 : 7)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .appGlass(in: .capsule, interactive: true)
            .padding(.horizontal, isLandscape ? 12 : 28)
            .padding(.vertical, isLandscape || isSmall ? 2 : 4)
            .accessibilityIdentifier("currentLineCapsule")
        }
    }
}

import PlaybackKit
import SubsonicKit
import SwiftUI

/// "Navinx Playback", the yearly recap: Flutter `WrappedScreen` (C23, D92). Opened from Home's
/// banner in season and from Settings → About all year, over everything, with the status bar hidden.
/// Opening it pauses playback, as Flutter's did.
struct RecapView: View {
    @Environment(AccountModel.self) private var account
    @Environment(LibraryModel.self) private var library
    @Environment(RecommendationModel.self) private var recommendations
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var stats: RecapStats?

    private let year = RecapSeason.year(for: RecapSeason.today)

    var body: some View {
        Group {
            if let stats, !stats.isEmpty {
                RecapStory(stats: stats) { dismiss() }
            } else if stats != nil {
                RecapNotice(
                    title: "Nothing to recap yet",
                    text: "Play some music and your Playback will fill in.",
                    isLoading: false,
                    identifier: "recapEmpty"
                ) { dismiss() }
            } else {
                RecapNotice(
                    title: "Navinx Playback \(year)",
                    text: "Synthesizing your listening universe",
                    isLoading: true,
                    identifier: "recapLoading"
                ) { dismiss() }
            }
        }
        .statusBarHidden()
        .preferredColorScheme(.dark)
        .task {
            if player.isPlaying { player.pause() }
            stats = await RecapSource.load(
                client: account.client,
                librarySongs: library.allSongs,
                artists: library.artists,
                profiles: Array(recommendations.data.profiles.values),
                year: year
            )
        }
    }
}

/// Where the numbers come from (D92): every song's play count and last play from Navidrome, read
/// fresh (`search3` with an empty query, a page at a time), else the library as last synced (offline).
enum RecapSource {
    static func load(
        client: SubsonicClient?,
        librarySongs: [Song],
        artists: [Artist],
        profiles: [ListeningRecord],
        year: Int
    ) async -> RecapStats {
        var songs: [Song]?
        if let client { songs = await serverSongs(client) }
        if songs?.isEmpty ?? true { songs = librarySongs }
        var profiles = profiles
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-UITestRecapSample") {
            (songs, profiles) = sample(from: songs ?? [], year: year)
        }
        #endif
        let covers = Dictionary(artists.compactMap { artist in artist.coverArt.map { (artist.id, $0) } }) { first, _ in first }
        let found = songs ?? []
        let finalProfiles = profiles
        return await Task.detached(priority: .userInitiated) {
            RecapStats.make(songs: found, profiles: finalProfiles, artistCovers: covers, year: year)
        }.value
    }

    private static func serverSongs(_ client: SubsonicClient) async -> [Song]? {
        let fetchBatch = 500
        var songs: [Song] = []
        // 200 pages is 100,000 songs; a failed page means the library as synced instead.
        for _ in 0..<200 {
            guard let page = try? await client.search("", artistCount: 0, albumCount: 0, songCount: fetchBatch, songOffset: songs.count).songs
            else { return nil }
            songs += page
            if page.count < fetchBatch { break }
        }
        return songs
    }

    #if DEBUG
    /// `-UITestRecapSample` (debug builds, for the UI tests' pictures only): the library's first
    /// twelve songs by title with fixed play counts, genres and hours, since the test account has
    /// few plays and no genres. Never in a release build.
    static func sample(from songs: [Song], year: Int) -> ([Song], [ListeningRecord]) {
        let counts = [42, 31, 27, 22, 18, 15, 12, 9, 7, 5, 4, 3]
        let genres = ["Hip-Hop", "R&B", "Jazz", "Hip-Hop", "Electronic", "Pop"]
        let calendar = Calendar.current
        let day = calendar.date(from: DateComponents(year: year, month: 11, day: 20, hour: 12)) ?? .now
        let picked = songs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.prefix(counts.count)
        let sampled = picked.enumerated().map { index, song in
            var song = song
            song.playCount = counts[index]
            song.played = day.addingTimeInterval(TimeInterval(-index * 3600))
            song.genre = genres[index % genres.count]
            return song
        }
        guard let first = sampled.first else { return (sampled, []) }
        var profile = ListeningRecord(song: first)
        profile.playCount = 30
        profile.hourlyPlays = [7: 6, 8: 7, 9: 4, 13: 5, 15: 3, 20: 3, 23: 2]
        profile.lastPlayed = day
        return (sampled, [profile])
    }
    #endif
}

// MARK: - The story

/// The slides, Flutter's story: a progress segment each, filling over 8 s; a tap on the left 30 %
/// goes back and anywhere else on; a long press holds; the last slide stays.
private struct RecapStory: View {
    let stats: RecapStats
    let close: () -> Void

    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var index = 0
    @State private var elapsed: Double = 0
    @State private var isHeld = false
    @State private var holdTask: Task<Void, Never>?
    @State private var pressStart: Date?
    @State private var forward = true
    /// The drumroll before the top songs: 3, 2, 1, then they play (first visit only).
    @State private var countdown: Int?
    @State private var isRevealed = false
    @State private var drumrollTask: Task<Void, Never>?

    private static let slideSeconds = 8.0
    private var slides: [RecapStats.Slide] { stats.slides }
    private var slide: RecapStats.Slide { slides[index] }
    private var isCounting: Bool { countdown != nil }

    var body: some View {
        ZStack {
            RecapBackdrop(slide: slide)
            VStack(spacing: 0) {
                header
                content
            }
            if isHeld {
                Text("PAUSED")
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(1.6)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .appGlass(in: .capsule)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 48)
                    .transition(.opacity)
                    .accessibilityIdentifier("recapPaused")
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: index)
        .sensoryFeedback(.impact(weight: .heavy), trigger: countdown) { _, new in new != nil }
        .sensoryFeedback(.success, trigger: isRevealed) { _, new in new }
        .task {
            // The 8 s per slide, stopped while held, during the drumroll and with VoiceOver.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !isHeld, !isCounting, !voiceOver, elapsed < Self.slideSeconds else { continue }
                elapsed = min(elapsed + 0.05, Self.slideSeconds)
                if elapsed >= Self.slideSeconds, index < slides.count - 1 { step(1) }
            }
        }
        .onDisappear { drumrollTask?.cancel() }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 5) {
                ForEach(slides.indices, id: \.self) { segment in
                    Capsule()
                        .fill(.white.opacity(0.25))
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Capsule().fill(.white).frame(width: proxy.size.width * fill(segment))
                            }
                        }
                        .frame(height: 3.5)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Slide \(index + 1) of \(slides.count)")
            .accessibilityIdentifier("recapProgress")

            HStack {
                RecapChip(text: "PLAYBACK \(String(stats.year))", systemImage: "sparkles", color: Palette.accentRed)
                Spacer()
                Button("Close", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .contentShape(.circle)
                    .appGlass(in: .circle, interactive: true)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("recapClose")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private func fill(_ segment: Int) -> CGFloat {
        if segment < index { return 1 }
        if segment > index { return 0 }
        return elapsed / Self.slideSeconds
    }

    // MARK: Slides

    private var content: some View {
        GeometryReader { proxy in
            ZStack {
                slideView(slide)
                    .id(index)
                    .transition(transition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(press(width: proxy.size.width))
        }
    }

    private var transition: AnyTransition {
        reduceMotion ? .opacity : .push(from: forward ? .trailing : .leading)
    }

    @ViewBuilder
    private func slideView(_ slide: RecapStats.Slide) -> some View {
        Group {
            switch slide {
            case .intro: OpeningSlide(year: stats.year) { step(1) }
            case .minutes: TimeSlide(stats: stats)
            case .chronotype: ListeningClockSlide(chronotype: stats.chronotype ?? .sunrise)
            case .genres: GenresSlide(genres: stats.genres)
            case .topSongs:
                if isRevealed {
                    SongRankSlide(songs: stats.topSongs, isPlaying: isPlayingTopSongs)
                } else {
                    DrumrollSlide(count: countdown ?? 3)
                }
            case .topArtists: ArtistRankSlide(artists: stats.topArtists)
            case .personality: TraitSlide(archetype: stats.archetype ?? .alchemist)
            case .summary: SummarySlide(stats: stats) { playRankedSongs(); close() }
            }
        }
        // VoiceOver: a slide of text is one element with Next and Previous; one with buttons or rows
        // keeps them reachable (its buttons move on, and each row reads as one).
        .accessibilityElement(children: slide.hasOwnElements ? .contain : .combine)
        .accessibilityAction(named: "Next") { step(1) }
        .accessibilityAction(named: "Previous") { step(-1) }
        .accessibilityIdentifier("recapSlide.\(String(describing: slide))")
    }

    /// "NOW PLAYING" only while one of the top songs is actually playing (Flutter showed it regardless).
    private var isPlayingTopSongs: Bool {
        guard player.isPlaying, let id = player.currentSong?.id else { return false }
        return stats.topSongs.contains { $0.song.id == id }
    }

    // MARK: Moving

    /// A press: a quick one moves, a held one pauses until it lets go.
    private func press(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard pressStart == nil else { return }
                pressStart = .now
                holdTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.2)) { isHeld = true }
                }
            }
            .onEnded { value in
                holdTask?.cancel()
                pressStart = nil
                if isHeld {
                    withAnimation(.easeOut(duration: 0.2)) { isHeld = false }
                    return
                }
                guard abs(value.translation.width) < 30, abs(value.translation.height) < 30 else { return }
                step(value.location.x < width * 0.3 ? -1 : 1)
            }
    }

    private func step(_ delta: Int) {
        // Taps are locked while the drum rolls.
        guard !isCounting else { return }
        let target = index + delta
        guard slides.indices.contains(target) else { return }
        forward = delta > 0
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .easeInOut(duration: 0.38)) {
            index = target
            elapsed = 0
        }
        if slides[target] == .topSongs, !isRevealed { startDrumroll() }
    }

    private func startDrumroll() {
        drumrollTask?.cancel()
        drumrollTask = Task {
            for count in [3, 2, 1] {
                countdown = count
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled else { countdown = nil; return }
            }
            playRankedSongs()
            withAnimation(.spring(duration: 0.5)) {
                countdown = nil
                isRevealed = true
            }
        }
    }

    /// The top songs as a queue from #1 (D92; Flutter played the #1 alone).
    private func playRankedSongs() {
        player.playInOrder(stats.topSongs.map(\.song))
    }
}

private extension RecapStats.Slide {
    var hasOwnElements: Bool { [.intro, .topSongs, .topArtists, .summary].contains(self) }
}

// MARK: - Backdrop

/// Flutter's backdrop: near black, the slide's two colours as a slow-drifting aura, and faint dots.
private struct RecapBackdrop: View {
    let slide: RecapStats.Slide
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let dots: [(x: Double, y: Double, size: Double, speed: Double, phase: Double)] = (0..<18).map { i in
        let seed = Double(i)
        return (
            x: (seed * 0.618_034).truncatingRemainder(dividingBy: 1),
            y: (seed * 0.414_214 + 0.13).truncatingRemainder(dividingBy: 1),
            size: 1.5 + (seed * 0.37).truncatingRemainder(dividingBy: 1) * 2,
            speed: 0.006 + (seed * 0.23).truncatingRemainder(dividingBy: 1) * 0.01,
            phase: seed * 0.7
        )
    }

    var body: some View {
        let colors = slide.colors
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            // One drift every 10 s, as Flutter's.
            let angle = t / 10 * 2 * .pi
            ZStack {
                Color(hex: 0x05060A)
                RadialGradient(
                    colors: [Color(hex: colors.0, opacity: 0.55), .clear],
                    center: UnitPoint(x: 0.5 + 0.18 * sin(angle), y: 0.28 + 0.08 * cos(angle)),
                    startRadius: 0,
                    endRadius: 420
                )
                RadialGradient(
                    colors: [Color(hex: colors.1, opacity: 0.45), .clear],
                    center: UnitPoint(x: 0.5 - 0.2 * sin(angle * 0.8), y: 1.0),
                    startRadius: 0,
                    endRadius: 460
                )
                Canvas { canvas, size in
                    for dot in Self.dots {
                        let y = (dot.y - t * dot.speed).truncatingRemainder(dividingBy: 1)
                        let point = CGPoint(
                            x: (dot.x + 0.02 * sin(t * 0.3 + dot.phase)) * size.width,
                            y: (y < 0 ? y + 1 : y) * size.height
                        )
                        let rect = CGRect(x: point.x, y: point.y, width: dot.size, height: dot.size)
                        canvas.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.22)))
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.6), value: slide)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Pieces

/// The small tinted capsule over a slide ("PLAYBACK 2026", "DRUMROLL...").
private struct RecapChip: View {
    let text: String
    let systemImage: String?
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
            }
            Text(text)
                .font(.system(size: 11, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.18), in: .capsule)
        .overlay { Capsule().strokeBorder(color.opacity(0.4), lineWidth: 1) }
    }
}

/// A slide's small coloured heading ("TOP SONGS").
private struct SlideLabel: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .heavy))
            .tracking(1.6)
            .foregroundStyle(color)
    }
}

/// A slide's big heading.
private struct SlideTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 28, weight: .heavy))
            .tracking(-0.4)
            .foregroundStyle(.white)
    }
}

private extension View {
    /// Flutter's frosted cards, as system glass tinted with the slide's colour.
    func recapCard(_ color: Color, opacity: Double = 0.18, radius: CGFloat = 24) -> some View {
        appGlass(in: .rect(cornerRadius: radius), tint: color.opacity(opacity))
    }

    /// The slide's content, centred and kept to a readable width.
    func slideFrame(alignment: Alignment = .center) -> some View {
        frame(maxWidth: 560, maxHeight: .infinity, alignment: alignment)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
    }
}

// MARK: 0. Intro

private struct OpeningSlide: View {
    let year: Int
    let begin: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isUp = false

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 40)
                .fill(LinearGradient(colors: [Color(hex: 0xFA243C), Color(hex: 0x7928CA)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 120, height: 120)
                .overlay {
                    Image(systemName: "music.note.square.stack.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(.white)
                }
                .shadow(color: Color(hex: 0xFA243C, opacity: 0.55), radius: 30)
                .offset(y: isUp ? -6 : 6)
                .accessibilityHidden(true)
            Text("Your \(String(year))\nin Sound")
                .font(.system(size: 44, weight: .heavy))
                .tracking(-1)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.top, 38)
            Text("You explored sonic depths, relived moments, and built memories through music.")
                .font(.system(size: 15))
                .lineSpacing(4)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 16)
                .padding(.top, 18)
            Button(action: begin) {
                HStack(spacing: 10) {
                    Text("Tap to begin").font(.system(size: 14, weight: .bold))
                    Image(systemName: "arrow.right").font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .padding(.vertical, 14)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .appGlass(in: .capsule, interactive: true)
            .padding(.top, 44)
            .accessibilityIdentifier("recapBegin")
        }
        .slideFrame()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { isUp = true }
        }
    }
}

// MARK: 1. Minutes

private struct TimeSlide: View {
    let stats: RecapStats
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0

    var body: some View {
        VStack(spacing: 0) {
            Text(RecapStats.grouped(shown))
                .font(.system(size: 66, weight: .heavy))
                .tracking(-2)
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityLabel(RecapStats.grouped(stats.minutes))
            Text("MINUTES LISTENED")
                .font(.system(size: 14, weight: .heavy))
                .tracking(2.4)
                .foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 0) {
                stat(String(format: "%.1f", stats.hours), "Total hours")
                divider
                stat(RecapStats.grouped(stats.uniqueTracks), "Unique tracks")
                divider
                stat(RecapStats.grouped(stats.artistCount), "Artists")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 22)
            .recapCard(Color(hex: 0x00C6FF), opacity: 0.12)
            .padding(.top, 38)
        }
        .slideFrame()
        .task {
            guard !reduceMotion else { shown = stats.minutes; return }
            // Counts up over 1.6 s, easing out.
            let start = Date.now
            while !Task.isCancelled {
                let t = min(Date.now.timeIntervalSince(start) / 1.6, 1)
                shown = Int(Double(stats.minutes) * (1 - pow(1 - t, 3)))
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.24)).frame(width: 1, height: 42)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 20, weight: .heavy)).foregroundStyle(.white)
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: 2. Chronotype

private struct ListeningClockSlide: View {
    let chronotype: RecapStats.Chronotype

    var body: some View {
        VStack(spacing: 24) {
            SlideLabel(text: "YOUR MUSICAL CHRONOTYPE", color: Color(hex: 0xFF512F))
            VStack(spacing: 0) {
                Circle()
                    .fill(LinearGradient(colors: [Color(hex: 0xFF512F), Color(hex: 0xDD2476)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 72, height: 72)
                    .overlay { Image(systemName: "clock.fill").font(.system(size: 30)).foregroundStyle(.white) }
                    .shadow(color: Color(hex: 0xFF512F, opacity: 0.5), radius: 16)
                    .accessibilityHidden(true)
                Text(chronotype.name)
                    .font(.system(size: 26, weight: .heavy))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.top, 22)
                Text(chronotype.text)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 12)
            }
            .padding(28)
            .frame(maxWidth: .infinity)
            .recapCard(Color(hex: 0xFF512F))
        }
        .slideFrame()
    }
}

// MARK: 3. Genres

private struct GenresSlide: View {
    let genres: [RecapStats.GenreShare]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SlideLabel(text: "GENRE GALAXY", color: Color(hex: 0xA855F7))
            SlideTitle(text: "The sounds that guided you").padding(.top, 6)
            VStack(spacing: 12) {
                ForEach(Array(genres.enumerated()), id: \.offset) { rank, genre in
                    row(genre, isFirst: rank == 0)
                }
            }
            .padding(.top, 22)
            Spacer(minLength: 0)
        }
        .padding(.top, 24)
        .slideFrame(alignment: .top)
    }

    private func row(_ genre: RecapStats.GenreShare, isFirst: Bool) -> some View {
        let color = Color(hex: genre.color)
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                Circle().fill(color).frame(width: 10, height: 10).shadow(color: color, radius: 4)
                Text(genre.name).font(.system(size: 16, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                Spacer()
                Text("\(genre.percent)%").font(.system(size: 15, weight: .heavy)).foregroundStyle(color)
            }
            Capsule()
                .fill(.white.opacity(0.12))
                .frame(height: 8)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(color).frame(width: proxy.size.width * genre.share)
                    }
                }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .recapCard(isFirst ? color : .white, opacity: isFirst ? 0.25 : 0.06, radius: 20)
    }
}

// MARK: 4. Drumroll and top songs

private struct DrumrollSlide: View {
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "lock.fill").font(.system(size: 11, weight: .bold))
                Text("DRUMROLL...").font(.system(size: 12, weight: .heavy)).tracking(1.3)
            }
            .foregroundStyle(Color(hex: 0xFF0844))
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .background(Color(hex: 0xFF0844, opacity: 0.15), in: .capsule)
            .overlay { Capsule().strokeBorder(Color(hex: 0xFF0844, opacity: 0.4), lineWidth: 1) }
            Text("Ready to discover\nyour #1 song?")
                .font(.system(size: 34, weight: .heavy))
                .tracking(-0.6)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.top, 36)
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0xFFB199), Color(hex: 0xFF0844)], center: .center, startRadius: 0, endRadius: 70))
                .frame(width: 124, height: 124)
                .overlay {
                    Text("\(count)")
                        .font(.system(size: 60, weight: .heavy))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(countsDown: true))
                }
                .shadow(color: Color(hex: 0xFF0844, opacity: 0.7), radius: 30)
                .phaseAnimator(reduceMotion ? [1.0] : [1.0, 1.08], trigger: count) { disc, scale in
                    disc.scaleEffect(scale)
                } animation: { _ in .easeOut(duration: 0.3) }
                .animation(.easeOut(duration: 0.3), value: count)
                .padding(.top, 48)
            Text("Get ready for the beat drop...")
                .font(.system(size: 14).italic())
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 48)
        }
        .slideFrame()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recapDrumroll")
    }
}

private struct SongRankSlide: View {
    let songs: [RecapStats.RankedSong]
    let isPlaying: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SlideLabel(text: "TOP SONGS", color: Color(hex: 0xFF0844))
                Spacer()
                if isPlaying {
                    HStack(spacing: 6) {
                        LevelBars(color: Color(hex: 0x10B981), isPlaying: true)
                            .frame(width: 14, height: 12)
                        Text("NOW PLAYING").font(.system(size: 10, weight: .heavy)).tracking(1)
                    }
                    .foregroundStyle(Color(hex: 0x10B981))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4.5)
                    .background(Color(hex: 0x10B981, opacity: 0.15), in: .capsule)
                    .overlay { Capsule().strokeBorder(Color(hex: 0x10B981, opacity: 0.4), lineWidth: 1) }
                    .accessibilityIdentifier("recapNowPlaying")
                }
            }
            SlideTitle(text: "Your most listened songs").padding(.top, 6)
            if let first = songs.first { firstCard(first).padding(.top, 18) }
            VStack(spacing: 10) {
                ForEach(Array(songs.dropFirst().prefix(4).enumerated()), id: \.offset) { offset, ranked in
                    row(ranked, rank: offset + 2)
                }
            }
            .padding(.top, 14)
            Spacer(minLength: 0)
        }
        .padding(.top, 24)
        .slideFrame(alignment: .top)
    }

    private func firstCard(_ ranked: RecapStats.RankedSong) -> some View {
        HStack(spacing: 14) {
            AlbumArtwork(coverArt: ranked.song.coverArt, size: 70, cornerRadius: 12)
                .overlay(alignment: .topLeading) {
                    Text("#1")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Palette.accentRed, in: .rect(cornerRadius: 6))
                        .padding(4)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(ranked.song.title).font(.system(size: 17, weight: .heavy)).foregroundStyle(.white).lineLimit(1)
                Text(ranked.song.artist ?? "Unknown Artist").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                Text(RecapStats.plays(ranked.plays))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: 0xFFB199))
                    .padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .recapCard(Color(hex: 0xFF0844), opacity: 0.3)
        .accessibilityElement(children: .combine)
    }

    private func row(_ ranked: RecapStats.RankedSong, rank: Int) -> some View {
        HStack(spacing: 12) {
            Text("#\(rank)").font(.system(size: 16, weight: .heavy)).foregroundStyle(.white.opacity(0.5)).frame(width: 30, alignment: .leading)
            AlbumArtwork(coverArt: ranked.song.coverArt, size: 44, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(ranked.song.title).font(.system(size: 14, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                Text(ranked.song.artist ?? "Unknown Artist").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(RecapStats.grouped(ranked.plays)).font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .recapCard(.white, opacity: 0.05, radius: 20)
        .accessibilityElement(children: .combine)
    }
}

// MARK: 5. Top artists

private struct ArtistRankSlide: View {
    let artists: [RecapStats.RankedArtist]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SlideLabel(text: "TOP ARTISTS", color: Color(hex: 0x38EF7D))
            SlideTitle(text: "Your musical anchors").padding(.top, 6)
            if let first = artists.first {
                HStack(spacing: 16) {
                    picture(first, size: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("#1 ARTIST")
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(1)
                            .foregroundStyle(Color(hex: 0x38EF7D))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color(hex: 0x38EF7D, opacity: 0.18), in: .rect(cornerRadius: 6))
                        Text(first.name).font(.system(size: 20, weight: .heavy)).foregroundStyle(.white).lineLimit(1)
                        Text(RecapStats.plays(first.plays)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .recapCard(Color(hex: 0x11998E), opacity: 0.3)
                .accessibilityElement(children: .combine)
                .padding(.top, 18)
            }
            VStack(spacing: 10) {
                ForEach(Array(artists.dropFirst().enumerated()), id: \.offset) { offset, artist in
                    HStack(spacing: 12) {
                        Text("#\(offset + 2)").font(.system(size: 16, weight: .heavy)).foregroundStyle(.white.opacity(0.5)).frame(width: 30, alignment: .leading)
                        picture(artist, size: 40)
                        Text(artist.name).font(.system(size: 15, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(RecapStats.grouped(artist.plays)).font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .recapCard(.white, opacity: 0.05, radius: 20)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 14)
            Spacer(minLength: 0)
        }
        .padding(.top, 24)
        .slideFrame(alignment: .top)
    }

    /// Round: the artist's picture, else the initial (Flutter's).
    @ViewBuilder
    private func picture(_ artist: RecapStats.RankedArtist, size: CGFloat) -> some View {
        if artist.coverArt != nil {
            AlbumArtwork(coverArt: artist.coverArt, size: size, cornerRadius: size / 2)
        } else {
            Circle()
                .fill(Color(hex: 0x11998E, opacity: 0.5))
                .frame(width: size, height: size)
                .overlay {
                    Text(artist.name.prefix(1).uppercased())
                        .font(.system(size: size * 0.4, weight: .heavy))
                        .foregroundStyle(.white)
                }
        }
    }
}

// MARK: 6. Personality

private struct TraitSlide: View {
    let archetype: RecapStats.Archetype

    var body: some View {
        let colors = archetype.colors.map { Color(hex: $0) }
        VStack(spacing: 24) {
            SlideLabel(text: "YOUR LISTENING PERSONALITY", color: Color(hex: 0xFF007A))
            VStack(spacing: 0) {
                Circle()
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 72, height: 72)
                    .overlay { Text(archetype.emoji).font(.system(size: 34)) }
                    .shadow(color: colors[0].opacity(0.5), radius: 16)
                    .accessibilityHidden(true)
                Text(archetype.badge)
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1.3)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.15), in: .capsule)
                    .padding(.top, 20)
                Text(archetype.title)
                    .font(.system(size: 28, weight: .heavy))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.top, 14)
                Text(archetype.text)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 10)
                ViewThatFits {
                    HStack(spacing: 8) { ForEach(archetype.traits, id: \.self, content: pill) }
                    VStack(spacing: 8) {
                        HStack(spacing: 8) { ForEach(archetype.traits.prefix(2), id: \.self, content: pill) }
                        HStack(spacing: 8) { ForEach(archetype.traits.dropFirst(2), id: \.self, content: pill) }
                    }
                }
                .padding(.top, 20)
            }
            .padding(28)
            .frame(maxWidth: .infinity)
            .recapCard(colors[0])
        }
        .slideFrame()
    }

    private func pill(_ trait: String) -> some View {
        Text(trait)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.white.opacity(0.12), in: .capsule)
    }
}

// MARK: 7. Summary

private struct SummarySlide: View {
    let stats: RecapStats
    let play: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            card.accessibilityElement(children: .combine)
            Button(action: play) {
                HStack(spacing: 10) {
                    Image(systemName: "play.circle.fill").font(.system(size: 22))
                    Text("Play Your Top Songs").font(.system(size: 17, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(Palette.accentRed, in: .rect(cornerRadius: 18))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("recapPlayRankedSongs")
        }
        .slideFrame()
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Circle().fill(Palette.accentRed).frame(width: 8, height: 8)
                Text("NAVINX PLAYBACK").font(.system(size: 13, weight: .heavy)).tracking(1.6).foregroundStyle(Palette.accentRed)
                Spacer()
                Text(String(stats.year)).font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.6))
            }
            if let first = stats.topSongs.first {
                HStack(spacing: 14) {
                    AlbumArtwork(coverArt: first.song.coverArt, size: 56, cornerRadius: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Song #1").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.accentRed)
                        Text(first.song.title).font(.system(size: 16, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                        Text(first.song.artist ?? "Unknown Artist").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                // The nested card is a plain fill: glass doesn't sit on glass.
                .background(.white.opacity(0.08), in: .rect(cornerRadius: 18))
            }
            HStack(spacing: 0) {
                metric(RecapStats.grouped(stats.minutes), "Minutes")
                divider
                metric(stats.topArtists.first?.name ?? "N/A", "Top Artist")
                divider
                metric(stats.genres.first?.name ?? "N/A", "Genre")
            }
        }
        .padding(22)
        .recapCard(Palette.accentRed, opacity: 0.12, radius: 28)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.24)).frame(width: 1, height: 36)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
    }
}

// MARK: - Loading and empty

/// Flutter's seasonal screen's layout, for the loading and the empty state (no Test Mode button).
private struct RecapNotice: View {
    let title: String
    let text: String
    let isLoading: Bool
    let identifier: String
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(hex: 0x05060A).ignoresSafeArea()
            VStack(spacing: 0) {
                Circle()
                    .fill(LinearGradient(colors: [Color(hex: 0xFA243C), Color(hex: 0xFF512F)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 96, height: 96)
                    .overlay {
                        if isLoading {
                            ProgressView().tint(.white).controlSize(.large)
                        } else {
                            Image(systemName: "gift.fill").font(.system(size: 40)).foregroundStyle(.white)
                        }
                    }
                    .shadow(color: Color(hex: 0xFA243C, opacity: 0.5), radius: 30)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 26, weight: .heavy))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.top, 32)
                Text(text)
                    .font(.system(size: 14))
                    .lineSpacing(6)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 14)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)

            Button("Close", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .contentShape(.circle)
                .appGlass(in: .circle, interactive: true)
                .buttonStyle(.plain)
                .padding(.leading, 16)
                .padding(.top, 10)
                .accessibilityIdentifier("recapClose")
        }
    }
}

// MARK: - Home's banner

/// Flutter's Home banner, in season only (D92): "#NavinxPlayback 2026" over "Your Year in Review is ready!".
struct RecapBanner: View {
    let year: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 16) {
                Circle()
                    .fill(.white.opacity(0.2))
                    .frame(width: 48, height: 48)
                    .overlay { Image(systemName: "sparkles").font(.system(size: 22)).foregroundStyle(.white) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("#NavinxPlayback \(String(year))")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(1.1)
                        .foregroundStyle(.white.opacity(0.7))
                    Text("Your Year in Review is ready!")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                LinearGradient(colors: [Color(hex: 0xFA243C), Color(hex: 0x8B5CF6)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: .rect(cornerRadius: 18)
            )
            .shadow(color: Color(hex: 0xFA243C, opacity: 0.35), radius: 18, y: 6)
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("recapBanner")
    }
}

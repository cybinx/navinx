import AppIntents
import SharedKit
import SwiftUI
import WidgetKit

/// The player's song (the kept one, paused, when nothing plays, D81). A tap opens the app; the medium
/// size also has play or pause and next, which work without opening it.
struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.nowPlaying, provider: SnapshotProvider()) { entry in
            NowPlayingView(content: WidgetContent.nowPlaying(entry.snapshot))
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Now Playing")
        .description("See what's playing in Navinx, and play, pause or skip.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NowPlayingView: View {
    let content: WidgetContent.NowPlaying

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch content {
        case .signedOut: WidgetMessage.signedOut
        case .nothing: WidgetMessage.nothingPlayed
        case .song(let song):
            if family == .systemMedium { medium(song) } else { small(song) }
        }
    }

    private func small(_ song: WidgetSong) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CoverView(name: song.cover, size: 68)
            Spacer(minLength: 6)
            titles(song, lines: 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func medium(_ song: WidgetSong) -> some View {
        HStack(spacing: 14) {
            CoverView(name: song.cover, size: 126, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 0) {
                titles(song, lines: 2)
                if let album = song.album, !album.isEmpty {
                    Text(album)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.top, 2)
                }
                Spacer(minLength: 6)
                HStack(spacing: 10) {
                    if song.isPlaying {
                        Button(intent: PauseIntent()) {
                            Label("Pause", systemImage: "pause.fill")
                        }
                    } else {
                        Button(intent: ResumeIntent()) {
                            Label("Play", systemImage: "play.fill")
                        }
                    }
                    Button(intent: NextSongIntent()) {
                        Label("Next", systemImage: "forward.fill")
                    }
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .tint(navinxAccent)
                .widgetAccentable()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func titles(_ song: WidgetSong, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(song.title)
                .font(.headline)
                .lineLimit(lines)
            if let artist = song.artist, !artist.isEmpty {
                Text(artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

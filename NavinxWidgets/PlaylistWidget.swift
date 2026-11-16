import AppIntents
import SharedKit
import SwiftUI
import WidgetKit

/// The playlist the Playlist widget shows, chosen when it's added (from the playlists the app last
/// shared; the extension asks no server).
struct PlaylistWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Playlist"
    static let description: IntentDescription? = IntentDescription("Choose a playlist.")

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity?

    init() {}
}

struct PlaylistEntry: TimelineEntry {
    let date: Date
    let content: WidgetContent.Playlist
}

struct PlaylistProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PlaylistEntry {
        PlaylistEntry(date: .now, content: .playlist(WidgetItem(id: "", name: "Playlist")))
    }

    func snapshot(for configuration: PlaylistWidgetConfiguration, in context: Context) async -> PlaylistEntry {
        if context.isPreview, configuration.playlist == nil { return placeholder(in: context) }
        return entry(for: configuration)
    }

    func timeline(for configuration: PlaylistWidgetConfiguration, in context: Context) async -> Timeline<PlaylistEntry> {
        Timeline(entries: [entry(for: configuration)], policy: .never)
    }

    private func entry(for configuration: PlaylistWidgetConfiguration) -> PlaylistEntry {
        let chosen = configuration.playlist.map { (id: $0.id, name: $0.name) }
        return PlaylistEntry(date: .now, content: WidgetContent.playlist(WidgetStore.shared?.read(), chosen: chosen))
    }
}

/// One playlist: its play button plays it without opening the app; a tap anywhere else opens it.
struct PlaylistWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.playlist, intent: PlaylistWidgetConfiguration.self, provider: PlaylistProvider()) { entry in
            PlaylistView(content: entry.content)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Playlist")
        .description("Play one of your playlists in Navinx.")
        .supportedFamilies([.systemSmall])
    }
}

struct PlaylistView: View {
    let content: WidgetContent.Playlist

    var body: some View {
        switch content {
        case .signedOut:
            WidgetMessage.signedOut
        case .choose:
            WidgetMessage(systemImage: "music.note.list", text: "Choose a playlist")
        case .playlist(let playlist):
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    CoverView(name: playlist.cover, size: 68)
                    Spacer(minLength: 4)
                    Button(intent: PlayPlaylistIntent(playlist: PlaylistEntity(id: playlist.id, name: playlist.name))) {
                        Label("Play", systemImage: "play.fill")
                    }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .tint(navinxAccent)
                    .widgetAccentable()
                }
                Spacer(minLength: 6)
                Text(playlist.name)
                    .font(.headline)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(NavinxLink.url(for: .playlist(id: playlist.id)))
        }
    }
}

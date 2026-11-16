import SharedKit
import SwiftUI
import WidgetKit

/// Home's Recently Played: four albums (medium) or eight (large); a tap opens that album.
struct RecentlyPlayedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.recentlyPlayed, provider: SnapshotProvider()) { entry in
            RecentlyPlayedView(snapshot: entry.snapshot)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Recently Played")
        .description("Your recently played albums in Navinx.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct RecentlyPlayedView: View {
    let snapshot: WidgetSnapshot?

    @Environment(\.widgetFamily) private var family

    var body: some View {
        let isLarge = family == .systemLarge
        switch WidgetContent.latestAlbums(snapshot, count: isLarge ? 8 : 4) {
        case .signedOut: WidgetMessage.signedOut
        case .nothing: WidgetMessage.nothingPlayed
        case .albums(let albums):
            VStack(alignment: .leading, spacing: isLarge ? 10 : 8) {
                Text("Recently Played")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(navinxAccent)
                    .widgetAccentable()
                if isLarge {
                    Grid(horizontalSpacing: 10, verticalSpacing: 12) {
                        GridRow { row(albums, 0..<4, showsNames: true) }
                        GridRow { row(albums, 4..<8, showsNames: true) }
                    }
                } else {
                    HStack(spacing: 10) { row(albums, 0..<4, showsNames: false) }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func row(_ albums: [WidgetItem], _ range: Range<Int>, showsNames: Bool) -> some View {
        ForEach(range, id: \.self) { index in
            if index < albums.count {
                let album = albums[index]
                Link(destination: NavinxLink.url(for: .album(id: album.id))) {
                    VStack(alignment: .leading, spacing: 4) {
                        CoverView(name: album.cover, size: 68)
                        if showsNames {
                            Text(album.name)
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                                .frame(width: 68, alignment: .leading)
                        }
                    }
                }
            } else {
                Color.clear.frame(width: 68, height: 68)
            }
        }
    }
}

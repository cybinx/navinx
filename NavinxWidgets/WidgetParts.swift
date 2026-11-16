import SharedKit
import SwiftUI
import UIKit
import WidgetKit

/// The app's default accent, purple `8B5CF6` (`AppearanceModel.Accent.standard`, D193): the widgets
/// don't follow the accent chosen in the app.
let navinxAccent = Color(red: 0x8B / 255, green: 0x5C / 255, blue: 0xF6 / 255)

/// One snapshot, as every widget's timeline entry carries it.
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?

    static func now() -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: WidgetStore.shared?.read())
    }

    /// The gallery's and the placeholder's: made-up names, no covers.
    static let sample = SnapshotEntry(
        date: .now,
        snapshot: WidgetSnapshot(
            signedIn: true,
            nowPlaying: WidgetSong(id: "", title: "Song Title", artist: "Artist", album: "Album", cover: nil, isPlaying: true),
            latestAlbums: (1...8).map { WidgetItem(id: "\($0)", name: "Album", subtitle: "Artist") },
            playlists: [WidgetItem(id: "", name: "Playlist")]
        )
    )
}

/// The Now Playing and Recently Played widgets' timeline: the snapshot as it is. The app asks WidgetKit
/// to reload when it writes a new one, so nothing is scheduled.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(context.isPreview ? .sample : .now())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        completion(Timeline(entries: [.now()], policy: .never))
    }
}

/// A cover from the snapshot's folder, decoded at the size it's shown; the app's note placeholder when
/// there's none. Tinted with the Home Screen in its tinted and clear looks, as Apple's widgets are.
struct CoverView: View {
    let name: String?
    let size: CGFloat
    var cornerRadius: CGFloat = 8

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let pixels = Int(min(size * displayScale, 600))
        Group {
            if let image = WidgetStore.shared?.coverImage(name, maxPixel: max(pixels, 64)) {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .widgetAccentedRenderingMode(.accentedDesaturated)
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.fill.tertiary)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: max(size / 3, 12)))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius))
    }
}

/// A widget's one line when it has nothing to show: signed out, or nothing yet.
struct WidgetMessage: View {
    let systemImage: String
    let text: LocalizedStringKey

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(navinxAccent)
                .widgetAccentable()
            Text(text)
                .font(.footnote.weight(.medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension WidgetMessage {
    static let signedOut = WidgetMessage(systemImage: "person.crop.circle", text: "Open Navinx to sign in")
    static let nothingPlayed = WidgetMessage(systemImage: "music.note", text: "Nothing played yet")
}

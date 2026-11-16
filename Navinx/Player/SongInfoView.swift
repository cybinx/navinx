import SubsonicKit
import SwiftUI

/// Song Info (C35, D142): a new screen with no Flutter counterpart, so it's the system's own sheet
/// and grouped rows (D140). It opens at once with the song it was given, then shows the server's
/// answer when it comes (play counts in saved lists go stale); offline it shows what it has.
struct SongInfoView: View {
    let song: Song

    @Environment(AccountModel.self) private var account
    @Environment(DownloadModel.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @State private var fresh: Song?

    var body: some View {
        let shown = fresh ?? song
        let downloadedAt = downloads.isDownloaded(shown.id) ? downloads.records.songs[shown.id]?.downloadedAt : nil
        NavigationStack {
            List {
                Section { header(shown) }
                ForEach(SongInfoLogic.groups(for: shown, downloadedAt: downloadedAt), id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.rows, id: \.label) { row in
                            LabeledContent(row.label) {
                                Text(row.value)
                                    .multilineTextAlignment(.trailing)
                                    .textSelection(.enabled)
                            }
                            .accessibilityIdentifier("songInfo-\(row.label)")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Song Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("songInfo")
        .task(id: song.id) { await load() }
    }

    private func header(_ song: Song) -> some View {
        HStack(spacing: 14) {
            AlbumArtwork(coverArt: song.coverArt, size: 64, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.headline)
                    .lineLimit(2)
                    .textSelection(.enabled)
                let artists = song.displayArtists.map(\.name).joined(separator: ", ")
                if !artists.isEmpty {
                    Text(artists)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        guard let client = account.client, !account.isOffline else { return }
        if let found = try? await client.song(id: song.id), found.id == song.id {
            fresh = found
        }
    }
}

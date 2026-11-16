import SubsonicKit
import SwiftUI

/// What a collection's Download button acts on.
enum DownloadTarget {
    case album(Album)
    case playlist(Playlist)

    var id: String {
        switch self {
        case .album(let album): album.id
        case .playlist(let playlist): playlist.id
        }
    }

    var name: String {
        switch self {
        case .album(let album): album.name
        case .playlist(let playlist): playlist.name
        }
    }

    var songs: [Song] {
        switch self {
        case .album(let album): album.songs
        case .playlist(let playlist): playlist.songs ?? []
        }
    }

    var buttonTitle: String {
        switch self {
        case .album: "Download album"
        case .playlist: "Download playlist"
        }
    }
}

/// Flutter's three-state Download button on the album and playlist pages: the cloud, the spinner
/// ("Downloading — tap to cancel") and the green cloud ("Downloaded — tap to remove", which asks).
struct CollectionDownloadButton: View {
    let target: DownloadTarget
    /// The playlist page's trailing item keeps the system's bar look; the label alone otherwise.
    var showsAsCapsule = false

    @Environment(DownloadModel.self) private var downloads
    @Environment(ToastCenter.self) private var toasts
    @State private var asksToRemove = false

    var body: some View {
        let state = downloads.state(of: target.id, songs: target.songs)
        Group {
            if state.isActive {
                Button {
                    downloads.cancel(target.id)
                } label: {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 22, height: 22)
                }
                .accessibilityLabel("Downloading — tap to cancel")
            } else if state == .downloaded {
                Button("Downloaded — tap to remove", systemImage: "checkmark.circle.fill") {
                    asksToRemove = true
                }
                .tint(Palette.green)
                .foregroundStyle(Palette.green)
            } else {
                Button(target.buttonTitle, systemImage: "arrow.down.circle") {
                    download()
                }
            }
        }
        .accessibilityIdentifier("collectionDownload")
        .alert("Remove downloads?", isPresented: $asksToRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                downloads.remove(collectionID: target.id, songs: target.songs)
            }
        } message: {
            // "Remove all 3 downloaded songs", but "Remove 1 downloaded song".
            let count = downloads.downloadedCount(target.songs)
            Text("Remove \(count == 1 ? "" : "all ")\(CountText.of(count, "downloaded song")) from \"\(target.name)\"?")
        }
    }

    private func download() {
        let songs = target.songs
        guard !songs.isEmpty else { return }
        let count = switch target {
        case .album(let album): downloads.download(album: album, songs: songs)
        case .playlist(let playlist): downloads.download(playlist: playlist, songs: songs)
        }
        toasts.show("Queued \(CountText.of(count, "song")) for download…")
    }
}

/// Flutter's mark on a downloaded cover: the album header's grey arrow on white, the playlist
/// header's green check on white.
struct DownloadedCoverBadge: View {
    enum Style { case album, playlist }

    let style: Style

    var body: some View {
        Image(systemName: style == .album ? "arrow.down.circle.fill" : "checkmark.circle.fill")
            .font(.system(size: 21))
            .foregroundStyle(style == .album ? Color.gray : Palette.green)
            .background(Circle().fill(.white).padding(1))
            .padding(style == .album ? 4 : 6)
            .accessibilityLabel("Downloaded")
            .accessibilityIdentifier("downloadedBadge")
    }
}

import SubsonicKit
import SwiftUI

/// Flutter `AlbumCollectionScreen` for New Releases (the New tab's "Recently Added"), with its A–Z index.
struct AlbumCollectionView: View {
    @Environment(AccountModel.self) private var account
    @Environment(ToastCenter.self) private var toasts
    @State private var albums: [Album]?
    @State private var failed = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
            }
            // A separate task: a cancelled pull (the list changing under it) must not stop the load.
            .refreshable { await Task { await load() }.value }
            .overlay(alignment: .trailing) {
                if let albums, albums.count >= AlbumIndex.minimumAlbums {
                    AlbumIndexBar(albums: albums, proxy: proxy)
                        .padding(.trailing, 4)
                }
            }
        }
        .background(Palette.background)
        .navigationTitle("New Releases")
        .navigationBarTitleDisplayMode(.large)
        .task {
            if albums == nil { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let albums {
            if albums.isEmpty {
                DetailMessage(icon: "opticaldisc", text: "No albums found")
                    .padding(.top, 120)
            } else {
                AlbumWall(albums: albums)
            }
        } else if failed, account.isOffline {
            // Offline mode, in place of an error whose Retry couldn't work: the list is the server's.
            DetailMessage(icon: "wifi.slash", text: "New Releases need your server")
                .padding(.top, 120)
        } else if failed {
            DetailMessage(icon: "exclamationmark.circle", text: "Error loading albums") {
                Task { await load() }
            }
            .padding(.top, 120)
        } else {
            AlbumWallSkeleton()
        }
    }

    private func load() async {
        failed = false
        do {
            guard let client = account.client else { throw SubsonicError.network }
            albums = try await client.albumList(.newest, size: 60)
        } catch is CancellationError {
        } catch {
            // A failed refresh keeps what's shown, and says so (else a pull looks like it did nothing);
            // the error page shows only when there is nothing. Offline mode needs no word.
            failed = true
            if albums != nil, !account.isOffline { toasts.show("Error loading albums") }
        }
    }
}

/// Flutter's `AlbumCardShimmer`s, held still: eight cards, as a phone has two columns.
private struct AlbumWallSkeleton: View {
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 2), spacing: 16) {
            ForEach(0..<8, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Palette.fieldFill)
                        .aspectRatio(1, contentMode: .fit)
                    RoundedRectangle(cornerRadius: 3).fill(Palette.fieldFill).frame(width: 110, height: 14)
                    RoundedRectangle(cornerRadius: 3).fill(Palette.fieldFill).frame(width: 70, height: 10)
                }
            }
        }
        .padding(16)
    }
}

/// Flutter's A–Z index: a glass capsule at the side of the grid. A letter scrolls to the first album
/// under it, in the list's own order.
private struct AlbumIndexBar: View {
    let albums: [Album]
    let proxy: ScrollViewProxy

    var body: some View {
        ViewThatFits(in: .vertical) {
            letters
            ScrollView(showsIndicators: false) { letters }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .appGlass(in: .rect(cornerRadius: 16))
        .padding(.vertical, 8)
        .accessibilityIdentifier("albumIndex")
    }

    private var letters: some View {
        VStack(spacing: 0) {
            ForEach(AlbumIndex.letters, id: \.self) { letter in
                Button {
                    guard let album = AlbumIndex.firstAlbum(letter, in: albums) else { return }
                    withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(album.id, anchor: .top) }
                } label: {
                    // Flutter's 16 pt a letter, from its text's line height and 1 pt each side.
                    Text(letter)
                        .font(.system(size: 9.5, weight: .bold))
                        .frame(height: 16)
                        .padding(.horizontal, 4)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

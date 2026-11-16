import PlaybackKit
import SubsonicKit
import SwiftUI

/// Flutter `SongCollectionScreen` for Listening History (Home's clock button).
struct SongCollectionView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(RecommendationModel.self) private var recommendations
    @Environment(PlayerModel.self) private var player
    /// What the page lists: the played songs, following the library's songs as the sync fills them,
    /// worked out off the main actor once per change.
    @State private var songs: [Song]?
    /// The library has been asked for, so an empty list is the answer and not just the wait.
    @State private var isReady = false

    /// What a change of lists the songs again.
    private struct Inputs: Equatable {
        let songCount: Int
        let lastSynced: Date?
    }

    private var inputs: Inputs {
        Inputs(songCount: library.allSongs.count, lastSynced: library.lastSynced)
    }

    /// A first sync is still bringing in the songs, so the list may be only part of the library.
    private var isFillingUp: Bool {
        library.isSyncingQuietly && library.lastSynced == nil
    }

    /// What an empty list shows. "Nothing played" only when this iPhone has no plays (C54).
    private var emptyPage: SongCollectionLogic.EmptyPage {
        SongCollectionLogic.emptyPage(
            hasPlays: SongCollectionLogic.hasPlays(recommendations.data.profiles),
            libraryReady: isReady && !isFillingUp
        )
    }

    var body: some View {
        ScrollView {
            if let songs, !songs.isEmpty {
                LazyVStack(spacing: 0) {
                    actionRow(songs)
                    if isFillingUp {
                        Text("Still loading your library...")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondaryText)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        SongRow(song: song, list: songs, index: index, showsAlbum: true)
                    }
                }
            } else if songs != nil, let text = emptyPage.text {
                DetailMessage(icon: "music.note", text: text)
                    .padding(.top, 120)
                    .padding(.horizontal, 16)
            } else {
                ProgressView().padding(.top, 160)
            }
        }
        // A separate task: a cancelled pull (the list changing under it) must not stop the load.
        .refreshable { await Task { await load() }.value }
        .background(Palette.background)
        .navigationTitle("Listening History")
        .navigationBarTitleDisplayMode(.large)
        .task {
            if !isReady { await load() }
        }
        .task(id: inputs) { await refill() }
    }

    /// Flutter's solid Play All and outlined Shuffle, as prominent and plain glass.
    private func actionRow(_ songs: [Song]) -> some View {
        HStack(spacing: 12) {
            Button { player.playInOrder(songs) } label: {
                Label("Play All", systemImage: "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            Button { player.playShuffled(songs) } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.tint)
                    .padding(.vertical, 4)
            }
            .appGlassButtonStyle()
            Spacer(minLength: 0)
            Text("\(CountText.songs(songs.count)) • \(SongCollectionLogic.durationSummary(songs))")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func load() async {
        // It needs the full library; `refill` follows it as it arrives.
        await library.loadLibraryIfNeeded()
        isReady = true
        await refill()
    }

    /// The played songs, latest first.
    private func refill() async {
        let found = await SongCollectionLogic.historyInBackground(
            profiles: recommendations.data.profiles, allSongs: library.allSongs
        )
        // Another change came while this one was working: that one's answer is the one to show.
        if !Task.isCancelled { songs = found }
    }
}

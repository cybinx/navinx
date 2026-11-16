import PlaybackKit
import SubsonicKit
import SwiftUI

extension EnvironmentValues {
    /// Pushes a page onto the current tab's stack.
    @Entry var openLibraryRoute: (LibraryRoute) -> Void = { _ in }
}

/// Flutter `SongTile`. Tapping plays `list` from this song; swiping right adds it to the queue;
/// ⋯ and long press are the song options.
struct SongRow: View {
    let song: Song
    /// The list this row belongs to, which becomes the queue, and its place in it.
    var list: [Song]?
    var index: Int?
    var showsArtwork = true
    var showsArtist = true
    var showsAlbum = false
    var showsTrackNumber = false
    var height: CGFloat = 68
    /// Replaces playing `list` (Search's rows start radio).
    var onPlay: (() -> Void)?

    @Environment(ToastCenter.self) private var toasts
    @Environment(PlayerModel.self) private var player
    @Environment(AccountModel.self) private var account
    @Environment(DownloadModel.self) private var downloads

    private var isCurrent: Bool { player.currentSong?.id == song.id }
    /// Offline, a song that isn't downloaded shows greyed out and doesn't play (D52).
    private var isUnavailable: Bool { account.isOffline && !downloads.isDownloaded(song.id) }

    var body: some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            if let onPlay {
                onPlay()
            } else if account.isOffline, let list {
                let playable = OfflineLogic.playable(list, tapped: index, isDownloaded: downloads.isDownloaded)
                player.playSong(song, playlist: playable.songs, startIndex: playable.index)
            } else {
                player.playSong(song, playlist: list, startIndex: index)
            }
        } label: {
            HStack(spacing: 16) {
                leading
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.system(size: 15, weight: isCurrent ? .bold : .medium))
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.gray)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SongOptionsButton(song: song)
            }
            .padding(.horizontal, 16)
            .frame(height: height)
            .contentShape(.rect)
            .opacity(isUnavailable ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isUnavailable)
        .songContextMenu(song)
        .modifier(QueueSwipe(isEnabled: !isUnavailable) {
            player.queueUp(song)
            toasts.show("\"\(song.title)\" added to queue", systemImage: "text.badge.plus")
        })
        .accessibilityAction(named: "Add to Queue") {
            player.queueUp(song)
            toasts.show("\"\(song.title)\" added to queue", systemImage: "text.badge.plus")
        }
    }

    /// Flutter `_buildLeading`: the current song's equalizer over the cover or for the track number.
    @ViewBuilder
    private var leading: some View {
        if showsArtwork {
            AlbumArtwork(coverArt: song.coverArt, size: 44)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.5))
                        LevelBars(color: .white, isPlaying: player.isPlaying)
                    }
                }
        } else if showsTrackNumber, let track = song.track {
            Group {
                if isCurrent {
                    LevelBars(color: Palette.accent, isPlaying: player.isPlaying)
                } else {
                    Text(String(track))
                        .font(.system(size: 14))
                        .foregroundStyle(.gray)
                }
            }
            .frame(width: 32)
        } else if isCurrent {
            LevelBars(color: Palette.accent, isPlaying: player.isPlaying)
                .frame(width: 44)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if showsArtist, let artist = song.artist, !artist.isEmpty { parts.append(artist) }
        if showsAlbum, let album = song.album, !album.isEmpty { parts.append(album) }
        return parts.joined(separator: " • ")
    }
}

/// The Play and Shuffle capsules: Flutter's `GlassActionButton`s, the accent glyph and label on glass.
///
/// As in Apple Music (D23): Play turns shuffle off and starts from the top; Shuffle turns it on.
struct PlayShuffleRow: View {
    let songs: [Song]
    var playTitle = "Play"

    @Environment(PlayerModel.self) private var player
    @Environment(AccountModel.self) private var account
    @Environment(DownloadModel.self) private var downloads

    /// Offline, only the downloaded songs.
    private var playable: [Song] {
        account.isOffline ? songs.filter { downloads.isDownloaded($0.id) } : songs
    }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                capsule(playTitle, icon: "play.fill") { player.playInOrder(playable) }
                capsule("Shuffle", icon: "shuffle") { player.playShuffled(playable) }
            }
        }
        .disabled(playable.isEmpty && !songs.isEmpty)
    }

    private func capsule(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .appGlassButtonStyle()
    }
}

/// Flutter `MultiArtistWidget`: one artist opens their page, several open a list to pick from, and
/// an artist with no ID is looked up by name.
struct ArtistNames: View {
    let artists: [ArtistCredit]
    var font: Font = .system(size: 13)
    var color: Color = Palette.secondaryText
    var lineLimit = 1

    @Environment(AccountModel.self) private var account
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.openLibraryRoute) private var openRoute

    var body: some View {
        Group {
            if artists.isEmpty {
                label("Unknown Artist")
            } else if artists.count == 1 {
                Button { open(artists[0]) } label: { label(artists[0].name) }
                    .buttonStyle(.plain)
            } else {
                // Several artists: a menu of their names next to the link (D77, D30), not a sheet.
                Menu {
                    ArtistChoiceItems(artists: artists)
                } label: {
                    label(artists.map(\.name).joined(separator: ", "))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(font).foregroundStyle(color).lineLimit(lineLimit)
    }

    private func open(_ artist: ArtistCredit) {
        ArtistOpening.open(artist, client: account.client, toasts: toasts, route: openRoute)
    }
}

/// Flutter `ArtistsBottomSheet`'s artists, as menu rows to choose from: names only, no avatars (D77).
struct ArtistChoiceItems: View {
    let artists: [ArtistCredit]

    @Environment(AccountModel.self) private var account
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.openLibraryRoute) private var openRoute

    var body: some View {
        ForEach(Array(artists.enumerated()), id: \.offset) { _, artist in
            Button(artist.name.isEmpty ? "Unknown Artist" : artist.name) {
                ArtistOpening.open(artist, client: account.client, toasts: toasts, route: openRoute)
            }
        }
    }
}

/// Flutter `_pushArtist`: by ID, or by searching for the name when there's no ID.
enum ArtistOpening {
    static func open(_ artist: ArtistCredit, client: SubsonicClient?, toasts: ToastCenter, route: @escaping (LibraryRoute) -> Void) {
        guard artist.id.isEmpty else {
            route(.artist(Artist(id: artist.id, name: artist.name)))
            return
        }
        guard let client, !artist.name.isEmpty else { return }
        Task {
            do {
                let found = try await client.search(artist.name, artistCount: 5, albumCount: 0, songCount: 0).artists
                let match = found.first { $0.name.lowercased() == artist.name.lowercased() } ?? found.first
                if let match {
                    route(.artist(match))
                } else {
                    toasts.show("Artist \"\(artist.name)\" not found")
                }
            } catch {
                toasts.show("Error searching for artist: \(error.localizedDescription)")
            }
        }
    }
}

/// Flutter `AlbumCard`, without its hover effects. The card opens the album; the name opens the artist.
struct AlbumPoster: View {
    let album: Album
    /// The cover's side, when it's narrower than the card (Flutter's collection grids).
    var artSide: CGFloat?

    @Environment(\.openLibraryRoute) private var openRoute
    @Environment(AccountModel.self) private var account
    @Environment(ToastCenter.self) private var toasts
    @Environment(PlayerModel.self) private var player
    @Environment(DownloadModel.self) private var downloads

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { AlbumArtwork(coverArt: album.coverArt, size: 180, cornerRadius: 8, flexible: true) }
                .overlay(alignment: .bottomTrailing) {
                    ArtPlayDisc {
                        Task { await player.playAlbum(album, client: account.client, toasts: toasts, downloads: downloads) }
                    }
                }
                .frame(width: artSide)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(album.name)
                        .font(.system(size: 15))
                        .lineLimit(1)
                    // Flutter `AlbumCard`'s mark after the name.
                    if downloads.isAlbumDownloaded(album) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.gray)
                            .accessibilityLabel("Downloaded")
                    }
                }
                if album.artist != nil || album.artists != nil {
                    ArtistNames(artists: album.displayArtists)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onTapGesture { openRoute(.album(album)) }
        .accessibilityAddTraits(.isButton)
    }
}

/// The album and playlist pages' filter: Flutter's `GlassSearchField`.
struct SongFilterField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .appGlass(in: .capsule)
    }
}

/// The large cover at the top of the album and playlist pages. It shrinks and fades as it scrolls
/// away, like Flutter's collapsing header.
extension View {
    func collapsingHeaderArt() -> some View {
        scrollTransition(.interactive, axis: .vertical) { content, phase in
            let leaving = min(phase.value, 0)
            return content
                .scaleEffect(1 + leaving, anchor: .bottom)
                .opacity(1 + leaving * 1.3)
        }
    }
}

/// Flutter's error and empty states on the genre page and elsewhere.
struct DetailMessage: View {
    let icon: String
    let text: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundStyle(Palette.secondaryText)
            Text(text)
                .font(.system(size: 24))
                .multilineTextAlignment(.center)
            if let retry {
                Button("Retry", systemImage: "arrow.clockwise", action: retry)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The album page's loading state: Flutter's shimmer placeholders, held still.
struct AlbumSkeleton: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                RoundedRectangle(cornerRadius: 14).fill(Palette.fieldFill).frame(width: 250, height: 250)
                VStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(Palette.fieldFill).frame(width: 200, height: 24)
                    RoundedRectangle(cornerRadius: 4).fill(Palette.fieldFill).frame(width: 150, height: 18)
                }
            }
            .padding(24)
            SongListSkeleton()
        }
        .scrollDisabled(true)
    }
}

/// Flutter's `SongTileShimmer`s, held still.
struct SongListSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<10, id: \.self) { _ in
                HStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: 6).fill(Palette.fieldFill).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(Palette.fieldFill).frame(width: 180, height: 14)
                        RoundedRectangle(cornerRadius: 3).fill(Palette.fieldFill).frame(width: 110, height: 10)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(height: 68)
            }
        }
    }
}

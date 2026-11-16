import PlaybackKit
import SubsonicKit
import SwiftUI

/// The Library tab (D210): Liked Songs, Downloaded Songs and the account's playlists, with the sort
/// menu for the playlists.
struct LibraryView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(ToastCenter.self) private var toasts
    @Environment(AccountModel.self) private var account
    @Environment(PlayerModel.self) private var player
    @Environment(PlaylistSheets.self) private var playlistSheets
    @Environment(DownloadModel.self) private var downloads

    /// Kept by `MainTabView`, so now playing can open an artist's page here.
    @Binding var path: [LibraryRoute]
    @State private var sort: LibrarySort = .recents
    @State private var isGrid = false
    /// The rows, built off the main actor once per change of `inputs` (as `SongCollectionView` does);
    /// nil until the first build.
    @State private var items: [LibraryEntry]?

    /// What a change builds the rows again for.
    private struct Inputs: Equatable {
        let sort: LibrarySort
        let source: LibraryEntries.Source
    }

    private var inputs: Inputs {
        Inputs(sort: sort, source: .init(playlists: library.playlists, downloadedCount: downloads.downloadedIDs.count))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                sortRow
                content
            }
            // A separate task: a cancelled pull (the list changing under it) must not stop the load.
            .refreshable { await Task { await library.refresh() }.value }
            .keepsBottomRoom()
            .background(Palette.background)
            .navigationTitle("Your Library")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // The capsule's icons in the primary colour, not red (D72).
                    Button("Create playlist", systemImage: "plus") { playlistSheets.isCreating = true }
                        .accessibilityIdentifier("libraryAdd")
                        .tint(.primary)
                    Button("Settings", systemImage: "gearshape") { path.pushOnce(.settings) }
                        .accessibilityIdentifier("librarySettingsGear")
                        .tint(.primary)
                }
            }
            .navigationDestination(for: LibraryRoute.self) { RouteDestination(route: $0, path: $path) }
        }
        .environment(\.openLibraryRoute) { path.append($0) }
        // The library's sync, which Spotlight, Siri, the widgets and offline mode read.
        .task { await library.loadLibraryIfNeeded() }
        .task(id: inputs) {
            let inputs = inputs
            let built = await LibraryEntries.buildInBackground(sort: inputs.sort, source: inputs.source)
            // Another change came while this one was working: that one's answer is the one to show.
            if !Task.isCancelled { items = built }
        }
    }

    // MARK: The sort row

    private var sortRow: some View {
        HStack {
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(LibrarySort.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(sort.title, systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
            }
            .appGlassButtonStyle()
            .accessibilityIdentifier("librarySort")
            Spacer()
            Button(isGrid ? "Switch to List" : "Switch to Grid", systemImage: isGrid ? "list.bullet" : "square.grid.2x2") {
                isGrid.toggle()
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 15))
            .appGlassButtonStyle()
            .buttonBorderShape(.circle)
            .accessibilityIdentifier("libraryLayout")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let items { rows(items) } else { ProgressView().padding(.vertical, 64) }
    }

    @ViewBuilder
    private func rows(_ items: [LibraryEntry]) -> some View {
        if isGrid {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 16) {
                ForEach(items) { item in
                    Button { open(item) } label: { gridCell(item) }
                        .buttonStyle(.plain)
                        .opacity(isGreyed(item) ? 0.4 : 1)
                        .modifier(PlaylistLongPress(item: item))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    Button { open(item) } label: { listRow(item) }
                        .buttonStyle(.plain)
                        .opacity(isGreyed(item) ? 0.4 : 1)
                        .modifier(PlaylistLongPress(item: item))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func listRow(_ item: LibraryEntry) -> some View {
        HStack(spacing: 16) {
            listArtwork(item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 15, weight: isPinned(item) ? .bold : .semibold))
                    .lineLimit(1)
                if isPinned(item) {
                    Label {
                        Text(item.subtitle).lineLimit(1)
                    } icon: {
                        Image(systemName: "pin.fill").font(.system(size: 12))
                    }
                    .labelStyle(PinnedSubtitleStyle())
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tint)
                } else {
                    Text(item.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if case .playlist(let playlist) = item.kind {
                PlaylistOptionsButton(playlist: playlist)
            }
        }
        .frame(minHeight: 72)
        .contentShape(.rect)
    }

    @ViewBuilder
    private func listArtwork(_ item: LibraryEntry) -> some View {
        switch item.kind {
        case .playlist(let playlist): PlaylistArtwork(playlist: playlist, size: 54)
        default:
            tile(item, cornerRadius: 6, iconSize: 24, startPoint: .leading, endPoint: .trailing)
                .frame(width: 54, height: 54)
        }
    }

    private func gridCell(_ item: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { gridArtwork(item) }
                .overlay(alignment: .bottomTrailing) { gridPlayDisc(item) }
            Text(item.title)
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)
                .padding(.top, 8)
            Text(item.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
                .lineLimit(1)
                .padding(.top, 2)
        }
        .contentShape(.rect)
    }

    /// The glass play disc, on playlists only.
    @ViewBuilder
    private func gridPlayDisc(_ item: LibraryEntry) -> some View {
        if case .playlist(let playlist) = item.kind {
            ArtPlayDisc {
                Task { await player.playPlaylist(playlist, client: account.client, toasts: toasts, downloads: downloads) }
            }
        }
    }

    @ViewBuilder
    private func gridArtwork(_ item: LibraryEntry) -> some View {
        switch item.kind {
        case .playlist(let playlist):
            PlaylistArtwork(playlist: playlist, size: 240, cornerRadius: 8, flexible: true)
        default:
            tile(item, cornerRadius: 8, iconSize: 32, glassDisc: true, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    /// The two pinned rows' artwork: their gradients.
    private func tile(
        _ item: LibraryEntry,
        cornerRadius: CGFloat,
        iconSize: CGFloat,
        glassDisc: Bool = false,
        startPoint: UnitPoint,
        endPoint: UnitPoint
    ) -> some View {
        let (icon, gradient): (String, [Color]) = switch item.kind {
        case .heartedSongs: ("heart.fill", [Color(hex: 0x450AF5), Color(hex: 0x8E8EE5)])
        default: ("arrow.down.circle.fill", [Color(hex: 0x006450), Color(hex: 0x00897B)])
        }
        return ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(LinearGradient(colors: gradient, startPoint: startPoint, endPoint: endPoint))
            let glyph = Image(systemName: icon)
                .font(.system(size: iconSize))
                .foregroundStyle(.white)
            if glassDisc {
                glyph
                    .frame(width: 72, height: 72)
                    .appGlass(in: .circle)
            } else {
                glyph
            }
        }
    }

    private func isGreyed(_ item: LibraryEntry) -> Bool {
        LibraryEntries.isGreyed(item.kind, isOffline: account.isOffline)
    }

    private func isPinned(_ item: LibraryEntry) -> Bool {
        switch item.kind {
        case .heartedSongs, .offlineSongs: true
        case .playlist: false
        }
    }

    private func open(_ item: LibraryEntry) {
        switch item.kind {
        case .heartedSongs: path.append(.favorites)
        case .offlineSongs: path.append(.downloads)
        case .playlist(let playlist): path.append(.playlist(playlist))
        }
    }
}

/// A long press on a playlist opens its options; the pinned rows have none.
private struct PlaylistLongPress: ViewModifier {
    let item: LibraryEntry

    func body(content: Content) -> some View {
        if case .playlist(let playlist) = item.kind {
            content.playlistContextMenu(playlist)
        } else {
            content
        }
    }
}

private struct PinnedSubtitleStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

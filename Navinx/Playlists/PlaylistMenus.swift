import PlaybackKit
import SubsonicKit
import SwiftUI

/// Flutter `PlaylistOptionsModal`'s rows in its order, as a menu next to its button (D48), with
/// Rename added (D47).
struct PlaylistOptionsItems: View {
    let playlist: Playlist
    /// Whether the account is an administrator, who may change any playlist (see `DetailLogic.canEdit`).
    var isAdmin = false

    @Environment(PlayerModel.self) private var player
    @Environment(PinnedPlaylistsModel.self) private var favorites
    @Environment(PlaylistSheets.self) private var sheets
    @Environment(AccountModel.self) private var account
    @Environment(ToastCenter.self) private var toasts
    @Environment(DownloadModel.self) private var downloads

    var body: some View {
        let isFavorite = favorites.isFavorite(playlist.id)
        let canEdit = DetailLogic.canEdit(playlist, username: account.active?.username, isAdmin: isAdmin)
        Button("Play", systemImage: "play.circle") {
            Task { await player.playPlaylist(playlist, client: account.client, toasts: toasts, downloads: downloads) }
        }
        Button("Add all to queue", systemImage: "text.badge.plus") {
            Task { await player.addPlaylistToQueue(playlist, client: account.client, toasts: toasts) }
        }
        BatchItems(source: .playlist(playlist))
        Button(
            isFavorite ? "Remove from Favorites" : "Add to Favorites",
            systemImage: isFavorite ? "heart.fill" : "heart"
        ) {
            favorites.toggle(playlist.id)
        }
        // Another user's playlist can't be changed; the server would refuse.
        if canEdit {
            Button("Rename Playlist", systemImage: "pencil") {
                sheets.renaming = PlaylistEdit(playlist: playlist)
            }
            Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                sheets.deleting = PlaylistEdit(playlist: playlist)
            }
        }
    }
}

/// Whether the account is an administrator, asked only for a playlist that isn't its own.
@MainActor
private func isAdminForPlaylist(_ playlist: Playlist, account: AccountModel) async -> Bool {
    guard !DetailLogic.canEdit(playlist, username: account.active?.username, isAdmin: false) else { return false }
    return await account.isAdmin()
}

/// A ⋯ button that opens the playlist options next to itself.
struct PlaylistOptionsButton: View {
    let playlist: Playlist

    @Environment(AccountModel.self) private var account
    @State private var isAdmin = false

    var body: some View {
        Menu {
            PlaylistOptionsItems(playlist: playlist, isAdmin: isAdmin)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17))
                .rotationEffect(.degrees(90))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .task(id: account.active) { isAdmin = await isAdminForPlaylist(playlist, account: account) }
        .accessibilityLabel("Playlist options")
    }
}

extension View {
    /// A long press opens the playlist options, under Flutter's header of cover, name and song count.
    func playlistContextMenu(_ playlist: Playlist) -> some View {
        modifier(PlaylistContextMenu(playlist: playlist))
    }

    func playlistSheets(_ sheets: PlaylistSheets) -> some View {
        modifier(PlaylistSheetsModifier(sheets: sheets))
    }
}

private struct PlaylistContextMenu: ViewModifier {
    let playlist: Playlist

    @Environment(AccountModel.self) private var account
    @State private var isAdmin = false

    func body(content: Content) -> some View {
        content.contextMenu {
            PlaylistOptionsItems(playlist: playlist, isAdmin: isAdmin)
        } preview: {
            // A preview is hosted on its own, without the environment: the cover needs this.
            PlaylistMenuHeader(playlist: playlist).environment(account)
        }
        .task(id: account.active) { isAdmin = await isAdminForPlaylist(playlist, account: account) }
    }
}

private struct PlaylistMenuHeader: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 14) {
            PlaylistArtwork(playlist: playlist, size: 54, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                Text(PlaylistMembership.countText(playlist.songCount))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 320)
        .background(Palette.surface)
    }
}

/// A playlist being renamed or deleted, and what the page showing it does afterwards.
struct PlaylistEdit: Identifiable {
    let id = UUID()
    let playlist: Playlist
    /// Given the new name when renaming; deleting gives the old one.
    var onDone: ((String) -> Void)?
}

/// The alerts the playlist menus open once they've closed. It lives above the tabs, since a menu's
/// own content can't present anything.
@Observable
final class PlaylistSheets {
    var isCreating = false
    var renaming: PlaylistEdit?
    var deleting: PlaylistEdit?
}

private struct PlaylistSheetsModifier: ViewModifier {
    let sheets: PlaylistSheets

    @Environment(LibraryModel.self) private var library
    @Environment(PinnedPlaylistsModel.self) private var favorites
    @Environment(ToastCenter.self) private var toasts
    @Environment(DownloadModel.self) private var downloads
    @State private var name = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    func body(content: Content) -> some View {
        @Bindable var sheets = sheets
        content
            .environment(sheets)
            .alert("Create playlist", isPresented: $sheets.isCreating) {
                TextField("Playlist Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Create") { create(trimmedName) }
                    .disabled(trimmedName.isEmpty)
            }
            .alert(
                "Rename Playlist",
                isPresented: Binding(get: { sheets.renaming != nil }, set: { if !$0 { sheets.renaming = nil } }),
                presenting: sheets.renaming
            ) { edit in
                TextField("Playlist Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Save") { rename(edit, to: trimmedName) }
                    .disabled(trimmedName.isEmpty)
            }
            .alert(
                "Delete Playlist",
                isPresented: Binding(get: { sheets.deleting != nil }, set: { if !$0 { sheets.deleting = nil } }),
                presenting: sheets.deleting
            ) { edit in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { delete(edit) }
            } message: { edit in
                Text("Are you sure you want to delete the playlist \"\(edit.playlist.name)\"?")
            }
            .onChange(of: sheets.isCreating) { _, isCreating in
                if isCreating { name = "" }
            }
            .onChange(of: sheets.renaming?.id) {
                if let renaming = sheets.renaming { name = renaming.playlist.name }
            }
    }

    private func create(_ name: String) {
        Task {
            do {
                try await library.createPlaylist(name: name)
            } catch {
                toasts.show("Error creating playlist: \(error.localizedDescription)")
            }
        }
    }

    private func rename(_ edit: PlaylistEdit, to name: String) {
        Task {
            do {
                try await library.renamePlaylist(id: edit.playlist.id, to: name)
                edit.onDone?(name)
            } catch {
                toasts.show("Error renaming playlist: \(error.localizedDescription)")
            }
        }
    }

    /// Flutter says it's deleted before asking the server and keeps quiet on failure. Here a page
    /// only closes, and the message only shows, once the server has taken it.
    private func delete(_ edit: PlaylistEdit) {
        Task {
            do {
                try await library.deletePlaylist(id: edit.playlist.id)
                favorites.remove(edit.playlist.id)
                // Flutter: its download stops and its songs' downloads go (those another
                // downloaded album or playlist has stay, D60).
                if downloads.records.collections[edit.playlist.id] != nil {
                    downloads.remove(collectionID: edit.playlist.id, leavingSmartSongs: true)
                }
                toasts.show("Playlist \"\(edit.playlist.name)\" deleted")
                edit.onDone?(edit.playlist.name)
            } catch {
                toasts.show("Error deleting playlist: \(error.localizedDescription)")
            }
        }
    }
}

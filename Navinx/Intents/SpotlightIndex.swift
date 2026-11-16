import AppIntents
import CoreSpotlight
import Foundation
import SubsonicKit
import SharedKit

/// The signed-in server's albums, artists and playlists in Spotlight (C39; songs are left out, a
/// library can hold tens of thousands). Indexed from the saved library after each full sync and at
/// sign-in when Spotlight has another save; all of it removed on sign-out, a server switch and
/// Disconnect. A tap runs the matching open intent. The thumbnails are pictures already on the phone.
@MainActor
enum SpotlightIndex {
    /// "<account>|<the save's time>" of what Spotlight holds (`AccountKey.mark`).
    private static let markKey = "spotlight_indexed"
    /// One change at a time, in order: a removal is never overtaken by the next server's indexing.
    private static var last: Task<Void, Never>?
    /// Counts `serverChanged`: a refresh that one overtook doesn't mark its index as current, since the
    /// removal queued after it takes the index away again.
    private static var changes = 0

    /// `profileID` names the saved library; `account` is whose it must be.
    static func refresh(profileID: String, account: String) {
        let before = last
        let started = changes
        last = Task {
            await before?.value
            guard started == changes,
                  let snapshot = await LibraryCache.standard.load(key: profileID, account: account) else { return }
            let mark = "\(account)|\(snapshot.savedAt.timeIntervalSince1970)"
            guard UserDefaults.standard.string(forKey: markKey) != mark else { return }
            // The intents' lists and Siri's playlist names follow the new save.
            SavedLibrary.shared.forget()
            NavinxShortcuts.updateAppShortcutParameters()
            let entities = await Self.entities(of: snapshot, profileID: profileID)
            await removeEverything()
            let index = CSSearchableIndex.default()
            do {
                try await index.indexAppEntities(entities.albums)
                try await index.indexAppEntities(entities.artists)
                try await index.indexAppEntities(entities.playlists)
                if started == changes { UserDefaults.standard.set(mark, forKey: markKey) }
            } catch {
                // Spotlight refused: the next sync or sign-in tries again.
                UserDefaults.standard.removeObject(forKey: markKey)
            }
        }
    }

    /// Signed out, Disconnect, or another server.
    static func serverChanged() {
        changes += 1
        SavedLibrary.shared.forget()
        UserDefaults.standard.removeObject(forKey: markKey)
        NavinxShortcuts.updateAppShortcutParameters()
        let before = last
        last = Task {
            await before?.value
            await removeEverything()
        }
    }

    private static func removeEverything() async {
        let index = CSSearchableIndex.default()
        try? await index.deleteAppEntities(ofType: AlbumEntity.self)
        try? await index.deleteAppEntities(ofType: ArtistEntity.self)
        try? await index.deleteAppEntities(ofType: PlaylistEntity.self)
    }

    /// Off the main thread: thousands of covers are read and shrunk.
    @concurrent
    private nonisolated static func entities(
        of snapshot: LibrarySnapshot,
        profileID: String
    ) async -> (albums: [AlbumEntity], artists: [ArtistEntity], playlists: [PlaylistEntity]) {
        func thumbnail(_ coverArt: String?) -> Data? {
            guard let url = OfflineCovers.shared.file(for: coverArt)
                ?? ArtworkCache.shared.offlineURL(coverArt, size: 600, profileID: profileID) else { return nil }
            return ArtworkCache.shared.thumbnailData(url: url, maxPixel: 128)
        }
        let lists = SavedLibrary.lists(from: snapshot)
        let albums = lists.albums.map { album in
            AlbumEntity(id: album.id, name: album.name, artist: album.artist, artwork: thumbnail(album.coverArt))
        }
        // One item per name, a combined name's included (each its own identifier).
        let artists = LibraryMatching.unique(lists.artists.map { artist in
            ArtistEntity(artistID: artist.id, name: artist.name, artwork: thumbnail(artist.coverArt ?? "ar-\(artist.id)"))
        })
        let playlists = lists.playlists.map { playlist in
            PlaylistEntity(id: playlist.id, name: playlist.name, artwork: thumbnail(playlist.coverArt))
        }
        return (albums, artists, playlists)
    }
}

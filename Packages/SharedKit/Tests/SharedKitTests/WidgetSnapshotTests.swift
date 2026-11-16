import Foundation
import Testing
@testable import SharedKit

struct WidgetSnapshotTests {
    private func temporaryStore() -> WidgetStore {
        WidgetStore(directory: FileManager.default.temporaryDirectory.appending(path: "widgets-\(UUID().uuidString)"))
    }

    private let song = WidgetSong(id: "s1", title: "Song", artist: "Artist", album: "Album", cover: "cover-al-1.jpg", isPlaying: true)
    private let album = WidgetItem(id: "al-1", name: "Album", subtitle: "Artist", cover: "cover-al-1.jpg")
    private let playlist = WidgetItem(id: "pl-1", name: "Mix", cover: "cover-pl-1.jpg")

    @Test func aWrittenSnapshotReadsBack() throws {
        let store = temporaryStore()
        #expect(store.read() == nil)
        let snapshot = WidgetSnapshot(signedIn: true, nowPlaying: song, latestAlbums: [album], playlists: [playlist])
        try store.write(snapshot)
        #expect(store.read() == snapshot)
    }

    @Test func coversNoLongerNamedAreRemoved() throws {
        let store = temporaryStore()
        try store.saveCover(Data([1]), name: "cover-al-1.jpg")
        try store.saveCover(Data([2]), name: "cover-old.jpg")
        try store.write(WidgetSnapshot(signedIn: true, latestAlbums: [album]))
        #expect(store.hasCover("cover-al-1.jpg"))
        #expect(!store.hasCover("cover-old.jpg"))
    }

    @Test func signingOutClearsEverything() throws {
        let store = temporaryStore()
        try store.saveCover(Data([1]), name: "cover-al-1.jpg")
        try store.write(WidgetSnapshot(signedIn: true, nowPlaying: song, latestAlbums: [album], playlists: [playlist]))
        store.clear()
        #expect(store.read() == .signedOut)
        #expect(!store.hasCover("cover-al-1.jpg"))
        #expect(WidgetContent.nowPlaying(store.read()) == .signedOut)
    }

    @Test func coverNamesHoldNoPathOrQuery() {
        #expect(WidgetStore.coverName(for: "al-1_5f3a") == "cover-al-1_5f3a.jpg")
        #expect(WidgetStore.coverName(for: "../x?u=a&t=b") == "cover-___x_u_a_t_b.jpg")
        #expect(WidgetStore.coverName(for: "") == nil)
        #expect(WidgetStore.coverName(for: "//") == nil)
    }

    @Test func nowPlayingFromTheSnapshot() {
        #expect(WidgetContent.nowPlaying(nil) == .signedOut)
        #expect(WidgetContent.nowPlaying(.signedOut) == .signedOut)
        #expect(WidgetContent.nowPlaying(WidgetSnapshot(signedIn: true)) == .nothing)
        #expect(WidgetContent.nowPlaying(WidgetSnapshot(signedIn: true, nowPlaying: song)) == .song(song))
    }

    @Test func latestAlbumsFromTheSnapshot() {
        let albums = (1...8).map { WidgetItem(id: "al-\($0)", name: "Album \($0)") }
        let snapshot = WidgetSnapshot(signedIn: true, latestAlbums: albums)
        #expect(WidgetContent.latestAlbums(snapshot, count: 4) == .albums(Array(albums.prefix(4))))
        #expect(WidgetContent.latestAlbums(snapshot, count: 8) == .albums(albums))
        #expect(WidgetContent.latestAlbums(WidgetSnapshot(signedIn: true), count: 4) == .nothing)
        #expect(WidgetContent.latestAlbums(nil, count: 4) == .signedOut)
    }

    @Test func thePlaylistFromTheSnapshot() {
        let renamed = WidgetItem(id: "pl-1", name: "Mix (new)", cover: "cover-pl-1.jpg")
        let snapshot = WidgetSnapshot(signedIn: true, playlists: [renamed])
        #expect(WidgetContent.playlist(snapshot, chosen: (id: "pl-1", name: "Mix")) == .playlist(renamed))
        #expect(WidgetContent.playlist(snapshot, chosen: (id: "pl-gone", name: "Gone")) == .choose)
        #expect(WidgetContent.playlist(snapshot, chosen: nil) == .choose)
        // The same account's library loading again: the chosen name, no cover.
        #expect(WidgetContent.playlist(WidgetSnapshot(signedIn: true, playlistsReloading: true), chosen: (id: "pl-1", name: "Mix"))
            == .playlist(WidgetItem(id: "pl-1", name: "Mix")))
        // Another account's, still loading: not the last account's choice.
        #expect(WidgetContent.playlist(WidgetSnapshot(signedIn: true), chosen: (id: "pl-1", name: "Mix")) == .choose)
        #expect(WidgetContent.playlist(nil, chosen: (id: "pl-1", name: "Mix")) == .signedOut)
    }

    @Test func anEarlierBuildsFileReadsAsNotReloading() throws {
        let data = Data(#"{"signedIn":true,"recentAlbums":[],"playlists":[]}"#.utf8)
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        #expect(snapshot == WidgetSnapshot(signedIn: true))
        let written = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(WidgetSnapshot(signedIn: true, playlistsReloading: true)))
        #expect(written.playlistsReloading)
    }
}

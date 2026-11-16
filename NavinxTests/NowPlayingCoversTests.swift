import Foundation
import Testing
import UIKit
@testable import Navinx

/// The covers now playing has on its first frame (C15, D76): once warmed, a cover and its backdrop
/// are in memory, so the screen draws them without waiting for a load.
@MainActor
struct NowPlayingCoversTests {
    /// A downloaded cover, which is a file: the same lookup the server's covers go through.
    private func downloadedCover(_ coverArt: String) throws -> DownloadStore {
        let store = DownloadStore(profileID: "c15-\(UUID().uuidString)", root: FileManager.default.temporaryDirectory)
        try FileManager.default.createDirectory(at: store.coversDirectory, withIntermediateDirectories: true)
        let size = CGSize(width: 300, height: 300)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let file = store.coverFile(coverArt)
        try #require(image.jpegData(compressionQuality: 0.9)).write(to: file)
        OfflineCovers.shared.set(store: store, covers: [coverArt])
        return store
    }

    @Test func aWarmedCoverIsInMemoryForTheFirstFrame() async throws {
        let coverArt = "c15-warm-\(UUID().uuidString)"
        let store = try downloadedCover(coverArt)
        defer { OfflineCovers.shared.set(store: nil, covers: []) }

        let before = NowPlayingCovers.cached(for: coverArt, client: nil)
        #expect(before.cover == nil && before.tiny == nil, "nothing is decoded before it is warmed")

        // The covers list and the artwork cache are the whole process's: while this waits, the host
        // app's own downloads or another test may set their covers, and a test that logs out empties
        // the cache (C32: that failed this test in every full run). So this test's list is put back
        // and the warming repeated until nothing came between it and the look.
        var after = before
        for _ in 0..<20 where after.cover == nil || after.tiny == nil {
            OfflineCovers.shared.set(store: store, covers: [coverArt])
            await NowPlayingCovers.warm(coverArt: coverArt, client: nil)
            OfflineCovers.shared.set(store: store, covers: [coverArt])
            after = NowPlayingCovers.cached(for: coverArt, client: nil)
        }
        let cover = try #require(after.cover)
        let tiny = try #require(after.tiny)
        #expect(max(cover.size.width, cover.size.height) <= CGFloat(NowPlayingCovers.coverPixels))
        #expect(max(tiny.size.width, tiny.size.height) <= CGFloat(NowPlayingCovers.backdropPixels))
        // The same pictures every time, so the backdrop doesn't see a "new" cover and fade again.
        let again = NowPlayingCovers.cached(for: coverArt, client: nil)
        #expect(again.cover === cover && again.tiny === tiny)
    }

    @Test func aSongWithoutACoverHasNothingToWarm() async {
        await NowPlayingCovers.warm(coverArt: nil, client: nil)
        let none = NowPlayingCovers.cached(for: nil, client: nil)
        #expect(none.cover == nil && none.tiny == nil)
    }

    @Test func theBrightnessOfABackdropIsKeptAndOfNothingIsFlutters() throws {
        let size = CGSize(width: 16, height: 16)
        let white = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let first = NowPlayingCovers.brightness(of: white)
        #expect(first > 0.9)
        #expect(NowPlayingCovers.brightness(of: white) == first)
        #expect(NowPlayingCovers.brightness(of: nil) == CoverLuminance.unknown)
    }
}

import SubsonicKit
import SwiftUI
import UIKit

/// The covers now playing draws, found in memory without waiting (C15, D76). Now playing used to
/// start with no cover and a black backdrop, and the backdrop faded in over 0.7 s after the zoom had
/// finished. Looking the cover up in `ArtworkCache` when the screen is built, and warming it when
/// the song changes, puts both on the first frame, as Flutter's screen has (it is handed the image).
@MainActor
enum NowPlayingCovers {
    /// Flutter's request size for this screen, and its decode size for the backdrop.
    static let coverPixels = 800
    static let backdropPixels = 64

    /// Where a song's cover comes from: its downloaded file first, so it shows offline too.
    static func url(for coverArt: String?, client: SubsonicClient?) -> URL? {
        OfflineCovers.shared.file(for: coverArt) ?? client?.coverArtURL(coverArt, size: coverPixels)
    }

    /// The decoded covers already in memory, if any.
    static func cached(for coverArt: String?, client: SubsonicClient?) -> (cover: UIImage?, tiny: UIImage?) {
        guard let url = url(for: coverArt, client: client) else { return (nil, nil) }
        return (
            ArtworkCache.shared.cached(url: url, maxPixel: coverPixels),
            ArtworkCache.shared.cached(url: url, maxPixel: backdropPixels)
        )
    }

    /// Decodes both into the cache, for the song that is about to be opened.
    static func warm(coverArt: String?, client: SubsonicClient?) async {
        guard let url = url(for: coverArt, client: client) else { return }
        _ = await ArtworkCache.shared.image(url: url, maxPixel: coverPixels)
        _ = await ArtworkCache.shared.image(url: url, maxPixel: backdropPixels)
    }

    /// `CoverLuminance.estimate` of a backdrop image, kept so a repeat costs nothing.
    private static let brightnesses = NSMapTable<UIImage, NSNumber>.weakToStrongObjects()

    static func brightness(of tiny: UIImage?) -> Double {
        guard let tiny else { return CoverLuminance.unknown }
        if let known = brightnesses.object(forKey: tiny) { return known.doubleValue }
        let value = tiny.cgImage.flatMap(CoverLuminance.estimate(image:)) ?? CoverLuminance.unknown
        brightnesses.setObject(NSNumber(value: value), forKey: tiny)
        return value
    }
}

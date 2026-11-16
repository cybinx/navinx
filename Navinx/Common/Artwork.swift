import DeviceIdentity
import ImageIO
import SubsonicKit
import SwiftUI
import UIKit

/// The image cache: a large on-disk `URLCache` under a small in-memory cache of decoded images,
/// so grids scroll without decoding full-size covers (Flutter: `CachedNetworkImage`). A server's
/// cover is kept under its address without the login (`cacheKey`), and only once it decodes.
nonisolated final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()

    private let memory = NSCache<NSString, UIImage>()
    private let urlCache: URLCache
    private let sessions: RenewableSession
    private let lock = NSLock()
    /// Each server's cover address without the login, by profile, so offline the keys can be formed.
    private var addresses: [String: String]
    /// The server and login `remember` saw last, so the same again returns at once.
    private var remembered: String?
    private static let addressesKey = "artwork_cover_addresses"

    private init() {
        memory.totalCostLimit = 256 * 1024 * 1024
        let directory = URL.cachesDirectory.appending(path: "Artwork", directoryHint: .isDirectory)
        urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 1024 * 1024 * 1024, directory: directory)
        // A server that asks for the device's certificate gets it (C45), and a new session whenever that
        // certificate changes, so no connection opened before goes on with the old one (or none).
        sessions = RenewableSession {
            let configuration = URLSessionConfiguration.default
            // Kept by hand (`image`): only what decodes, and under a key without the login.
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            // Pictures can come from other hosts than the server: none of them keeps a cookie here.
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            return URLSession(configuration: configuration, delegate: DeviceChallengeAnswer.shared, delegateQueue: nil)
        }
        addresses = UserDefaults.standard.dictionary(forKey: Self.addressesKey) as? [String: String] ?? [:]
    }

    func cached(url: URL, maxPixel: Int) -> UIImage? {
        memory.object(forKey: Self.key(url, maxPixel))
    }

    /// A downloaded cover (a file URL) or the server's. `cacheOnly` (offline): only what the cache has,
    /// with no request.
    @concurrent
    func image(url: URL, maxPixel: Int, cacheOnly: Bool = false) async -> UIImage? {
        if let hit = cached(url: url, maxPixel: maxPixel) { return hit }
        let image: UIImage
        if url.isFileURL {
            guard let file = try? Data(contentsOf: url), let decoded = Self.decode(file, maxPixel: maxPixel) else { return nil }
            image = decoded
        } else {
            let key = Self.cacheKey(url)
            let request = URLRequest(url: key)
            if let kept = urlCache.cachedResponse(for: request), let decoded = Self.decode(kept.data, maxPixel: maxPixel) {
                image = decoded
            } else {
                guard !cacheOnly, let (body, http) = await download(url),
                      let decoded = Self.decode(body, maxPixel: maxPixel) else { return nil }
                // Kept only as a picture: a server answers an error, and a portal its page, with HTTP 200 too.
                let type = http.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg"
                if let keptResponse = HTTPURLResponse(url: key, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": type]) {
                    urlCache.storeCachedResponse(CachedURLResponse(response: keptResponse, data: body), for: request)
                }
                image = decoded
            }
        }
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        memory.setObject(image, forKey: Self.key(url, maxPixel), cost: cost)
        return image
    }

    /// The longest picture read: far more than any cover. An address (the tab's pictures are the
    /// server's add-on's to name) can't make the phone take in an endless body.
    static let maxPictureBytes = 25 * 1024 * 1024

    /// A picture's body with an HTTP 200, read up to `maxPictureBytes`: a longer one, stated or as it
    /// comes, is a failed load.
    private func download(_ url: URL) async -> (Data, HTTPURLResponse)? {
        guard let (bytes, response) = try? await sessions.session.bytes(from: url) else { return nil }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.expectedContentLength <= Int64(Self.maxPictureBytes) else {
            bytes.task.cancel()
            return nil
        }
        var body: [UInt8] = []
        if http.expectedContentLength > 0 { body.reserveCapacity(Int(http.expectedContentLength)) }
        do {
            for try await byte in bytes {
                guard body.count < Self.maxPictureBytes else {
                    bytes.task.cancel()
                    return nil
                }
                body.append(byte)
            }
        } catch {
            return nil
        }
        return (Data(body), http)
    }

    /// A small JPEG of a cover already on the phone (a downloaded file or the cache), with no request
    /// and nothing kept in memory: Spotlight's thumbnails (C39), which must hold no address.
    func thumbnailData(url: URL, maxPixel: Int) -> Data? {
        let data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url)
        } else {
            data = urlCache.cachedResponse(for: URLRequest(url: Self.cacheKey(url)))?.data
        }
        guard let data, let image = Self.decode(data, maxPixel: maxPixel) else { return nil }
        return image.jpegData(compressionQuality: 0.7)
    }

    /// Bytes on disk (Settings → Storage).
    var diskUsage: Int64 { Int64(urlCache.currentDiskUsage) }

    /// Empties both caches (on logout, as Flutter does, and from Settings → Storage).
    func clear() {
        memory.removeAllObjects()
        urlCache.removeAllCachedResponses()
        lock.withLock {
            addresses = [:]
            remembered = nil
        }
        UserDefaults.standard.removeObject(forKey: Self.addressesKey)
    }

    // MARK: Keys

    /// What a Subsonic address carries for the login (and the client), left out of the cache's key.
    private static let loginItems: Set<String> = ["t", "s", "p", "v", "c", "f", "apiKey"]

    /// The cache's key for a cover: a server's address without the login's items, so nothing secret
    /// is kept with it, a changed password keeps the covers, and offline (no client) the same key is
    /// formed from the address `remember` kept. Any other address is its own key.
    static func cacheKey(_ url: URL) -> URL {
        guard !url.isFileURL, var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path.hasSuffix("/rest/getCoverArt"), let items = components.queryItems else { return url }
        components.queryItems = items.filter { !loginItems.contains($0.name) }
        return components.url ?? url
    }

    /// Online: keeps where this server's covers are (no login in it), for `offlineURL`.
    func remember(_ client: SubsonicClient, profileID: String) {
        let identity = "\(profileID)|\(client.baseURL.absoluteString)|\(client.config.username)"
        if lock.withLock({ remembered == identity }) { return }
        guard let sample = client.coverArtURL("_", size: 1),
              var components = URLComponents(url: Self.cacheKey(sample), resolvingAgainstBaseURL: false) else { return }
        components.queryItems = components.queryItems?.filter { $0.name != "id" && $0.name != "size" }
        guard let address = components.url?.absoluteString else { return }
        let changed: [String: String]? = lock.withLock {
            remembered = identity
            guard addresses[profileID] != address else { return nil }
            addresses[profileID] = address
            return addresses
        }
        if let changed { UserDefaults.standard.set(changed, forKey: Self.addressesKey) }
    }

    /// Offline (no client): a cover's key as `cacheKey` makes it online, from the address `remember`
    /// kept for this server. For `image(url:maxPixel:cacheOnly: true)`, never for a request.
    func offlineURL(_ coverArt: String?, size: Int, profileID: String?) -> URL? {
        guard let coverArt, !coverArt.isEmpty, let profileID else { return nil }
        if coverArt.hasPrefix("http://") || coverArt.hasPrefix("https://") { return URL(string: coverArt) }
        guard let address = lock.withLock({ addresses[profileID] }), var components = URLComponents(string: address) else { return nil }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "id", value: coverArt))
        if size > 0 { items.append(URLQueryItem(name: "size", value: String(size))) }
        components.queryItems = items
        return components.url
    }

    /// Whether the file is a picture ImageIO can read (from its header): a server's error, or a
    /// portal's page, that came with HTTP 200 isn't.
    static func isImage(at file: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetType(source) != nil,
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0) > 0
    }

    /// Decodes at no more than `maxPixel` on the long side.
    static func decode(_ data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    /// Flutter `AlbumArtwork`'s "normal" resolution: what to ask the server for (at least 600 px,
    /// at most 1000) and what to decode (device pixels, 64–200, for thumbnails of 80 pt or less).
    static func pixels(size: CGFloat, scale: CGFloat) -> (request: Int, decode: Int) {
        // A size can come from the server (a row's): one that's huge or not a number is kept in range.
        let device = size * scale
        let base = device.isFinite ? Int(min(max(device, 0), 10_000)) : 0
        let request = base > 600 ? min(base, 1000) : 600
        return (request, size <= 80 ? min(max(base, 64), 200) : request)
    }

    private static func key(_ url: URL, _ maxPixel: Int) -> NSString {
        "\(maxPixel)|\(cacheKey(url).absoluteString)" as NSString
    }
}

/// Flutter `AlbumArtwork`: a cover by Subsonic ID or full URL, with its gradient and note
/// placeholder while loading or on failure, and the default soft shadow above 60 pt. A downloaded
/// cover comes from its file first, so it shows offline too (Flutter's `art_<coverArt>.jpg`).
struct AlbumArtwork: View {
    let coverArt: String?
    let size: CGFloat
    var cornerRadius: CGFloat = 6
    /// Fills the space it's given (the grid) instead of a fixed `size` frame.
    var flexible = false
    /// The album and playlist pages' larger header shadow.
    var prominentShadow = false

    @Environment(AccountModel.self) private var account
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    /// With the URL it's for: a view whose cover changes in place shows nothing of the last one.
    @State private var loaded: (url: URL, image: UIImage)?

    var body: some View {
        let pixels = ArtworkCache.pixels(size: size, scale: displayScale)
        let client = account.client
        // Offline, a cover not downloaded may still be in the cache from when the app was online.
        let url = OfflineCovers.shared.file(for: coverArt) ?? client?.coverArtURL(coverArt, size: pixels.request)
            ?? ArtworkCache.shared.offlineURL(coverArt, size: pixels.request, profileID: account.active?.id.uuidString)
        let image = (loaded?.url == url ? loaded?.image : nil) ?? url.flatMap { ArtworkCache.shared.cached(url: $0, maxPixel: pixels.decode) }
        let isDark = colorScheme == .dark

        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .frame(width: flexible ? nil : size, height: flexible ? nil : size)
            .shadow(
                color: .black.opacity(prominentShadow ? (isDark ? 0.35 : 0.2) : (size > 60 ? (isDark ? 0.22 : 0.14) : 0)),
                radius: prominentShadow ? 8 : size / 20,
                y: prominentShadow ? 8 : size / 30
            )
            .task(id: url) {
                loaded = nil
                guard let url else { return }
                if let client, let profileID = account.active?.id.uuidString {
                    ArtworkCache.shared.remember(client, profileID: profileID)
                }
                let image = await ArtworkCache.shared.image(url: url, maxPixel: pixels.decode, cacheOnly: client == nil)
                // An earlier cover's load that ends late doesn't put it back.
                guard !Task.isCancelled else { return }
                loaded = image.map { (url: url, image: $0) }
            }
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [Color(light: 0xE0E0E0, dark: 0x2A2A2A), Color(light: 0xEEEEEE, dark: 0x1A1A1A)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "music.note")
                .font(.system(size: min(max(size / 3, 16), 60)))
                .foregroundStyle(colorScheme == .dark ? .white.opacity(0.24) : .black.opacity(0.12))
        }
    }
}

/// Flutter `PlaylistArtwork`: the playlist's cover, else a mosaic of its songs' covers, else the
/// red tile. Flutter also saves mosaics (`PlaylistCoverService`) for a playlist with songs and no cover,
/// which isn't here: Navidrome leaves one without a cover only for a moment (measured in C9, once in
/// 40 renames, back within 2 seconds). An empty playlist often has none after a rename: the red tile.
struct PlaylistArtwork: View {
    let playlist: Playlist
    let size: CGFloat
    var cornerRadius: CGFloat = 6
    var flexible = false
    var prominentShadow = false

    var body: some View {
        if let cover = playlist.coverArt, !cover.isEmpty {
            AlbumArtwork(coverArt: cover, size: size, cornerRadius: cornerRadius, flexible: flexible, prominentShadow: prominentShadow)
        } else {
            let covers = Self.mosaic(playlist.songs ?? [])
            switch covers.count {
            case 4:
                mosaic(covers)
            case 1:
                AlbumArtwork(coverArt: covers[0], size: size, cornerRadius: cornerRadius, flexible: flexible, prominentShadow: prominentShadow)
            default:
                placeholderTile
            }
        }
    }

    /// Flutter's four mosaic slots from the distinct covers (fewer than four repeat), or the only one.
    nonisolated static func mosaic(_ songs: [Song]) -> [String] {
        var seen = Set<String>()
        var covers: [String] = []
        for song in songs {
            let cover = song.coverArt ?? song.id
            if !cover.isEmpty, seen.insert(cover).inserted { covers.append(cover) }
        }
        switch covers.count {
        case 0, 1: return covers
        case 2: return [covers[0], covers[1], covers[1], covers[0]]
        case 3: return [covers[0], covers[1], covers[2], covers[0]]
        default: return Array(covers.prefix(4))
        }
    }

    private func mosaic(_ covers: [String]) -> some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<2, id: \.self) { column in
                        AlbumArtwork(coverArt: covers[row * 2 + column], size: size / 2, cornerRadius: 0, flexible: true)
                    }
                }
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius))
        .frame(width: flexible ? nil : size, height: flexible ? nil : size)
    }

    /// In the chosen accent, as the Library's other playlist tiles (Flutter's fixed red; D193).
    private var placeholderTile: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Palette.accent.opacity(0.15))
            .overlay {
                Image(systemName: "music.note.list")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(Palette.accent)
            }
            .frame(width: flexible ? nil : size, height: flexible ? nil : size)
    }
}

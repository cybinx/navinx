import Foundation

/// A Subsonic/OpenSubsonic API client for one server. Flutter: `SubsonicService`
/// (`lib/services/subsonic_service.dart`), Subsonic backend only.
///
/// Every call throws `SubsonicError` (or `CancellationError`). Where the Flutter service swallows
/// an error and returns an empty list or nil, the caller decides; the screens (C3 on) show the
/// Flutter app's empty states. Where it falls back to another endpoint, so does this client.
public struct SubsonicClient: Sendable {
    public let config: ServerConfig
    /// The address in use: the LAN address if `connect` reached it, else the server address.
    public let baseURL: URL
    /// The fixed salt for cover-art URLs, so one image keeps one URL. The app stores it.
    public let coverArtSalt: String
    private(set) var transport: any HTTPTransport

    /// The same client (address, login, salt) over another transport: a sign-in checked over its own
    /// sessions is used over the shared ones once it's signed in (the review after C56).
    public func using(_ transport: any HTTPTransport) -> SubsonicClient {
        var copy = self
        copy.transport = transport
        return copy
    }

    /// Flutter's Dio timeouts.
    public static let requestTimeout: TimeInterval = 30
    /// How long `connect` waits for the LAN address.
    public static let lanProbeTimeout: TimeInterval = 3
    /// Longer addresses go as a POST with a form body: a reverse proxy refuses an address of some
    /// kilobytes (HTTP 414), which a playlist of a few hundred songs makes.
    static let longestGET = 2000

    /// A client for `baseURL` (default: the server address), with no network check.
    public init(
        config: ServerConfig,
        baseURL: URL? = nil,
        coverArtSalt: String,
        transport: any HTTPTransport = URLSessionTransport()
    ) throws(SubsonicError) {
        // No host, or a space in it ("https://my server"), is a typing error, not a network one.
        guard let url = baseURL ?? URL(string: config.normalizedURL),
              let host = url.host(percentEncoded: false), !host.isEmpty,
              !host.contains(where: \.isWhitespace) else {
            throw .invalidURL
        }
        self.config = config
        self.baseURL = url
        self.coverArtSalt = coverArtSalt
        self.transport = transport
    }

    /// A client that uses the LAN address when it answers `ping` with HTTP 200 and a Subsonic
    /// response within `lanProbeTimeout`, else the server address (Flutter
    /// `SubsonicService.configure`, which took any HTTP 200: on another network, a router at that
    /// private address answers too). Doesn't check the server address itself: call `ping()` for that.
    ///
    /// **The probe carries no login (D180):** only `v`, `c` and `f`, no `u`, `t`, `s` or `p`. On
    /// someone else's network, whatever device has that private address would otherwise get the
    /// user name and token, or with legacy auth the password itself, over plain http. It needs
    /// none: a Subsonic server answers an unsigned `ping` with HTTP 200 and a failed envelope
    /// (Navidrome: code 10, a missing parameter), and any envelope with a status counts. Flutter
    /// sends the signed ping. The limit: the login still goes to the LAN address in the requests
    /// that follow, so a device that deliberately answers as a Subsonic server there gets it; plain
    /// http can't prove who answers. This only keeps it from whatever happens to be there.
    public static func connect(
        config: ServerConfig,
        coverArtSalt: String,
        transport: any HTTPTransport = URLSessionTransport()
    ) async throws(SubsonicError) -> SubsonicClient {
        let main = try SubsonicClient(config: config, coverArtSalt: coverArtSalt, transport: transport)
        guard let lan = config.normalizedHomeNetworkURL.flatMap(URL.init(string:)), lan.host() != nil else {
            return main
        }
        let probe = Auth.url(base: lan, endpoint: "ping", items: Auth.clientItems)
        if let answer = try? await transport.get(probe, timeout: lanProbeTimeout),
           answer.1.statusCode == 200,
           (try? Response<NoPayload>.decode(answer.0, payloadKey: nil))?.status != nil {
            return try SubsonicClient(config: config, baseURL: lan, coverArtSalt: coverArtSalt, transport: transport)
        }
        return main
    }

    /// `connect`, then `ping`, which checks the login. When the home-network address refuses the login, the
    /// main address is asked once before the refusal stands: on another network a different music server
    /// can be at that private address, and the password isn't wrong (the re-check, item 10). If the main
    /// address takes it, its client comes back made without the home-network address, so for as long as that
    /// client is used nothing goes back there: no request, no signed login, no choosing it again. Any other
    /// failure at the main address leaves the refusal as it was.
    public static func connectAndPing(
        config: ServerConfig,
        coverArtSalt: String,
        transport: any HTTPTransport = URLSessionTransport()
    ) async throws -> (SubsonicClient, ServerInfo) {
        let client = try await connect(config: config, coverArtSalt: coverArtSalt, transport: transport)
        do {
            return (client, try await client.ping())
        } catch let refusal as SubsonicError
                    where refusal.isAuthenticationFailure && client.baseURL.absoluteString != config.normalizedURL {
            var mainOnly = config
            mainOnly.homeNetworkURL = nil
            let main = try SubsonicClient(config: mainOnly, coverArtSalt: coverArtSalt, transport: transport)
            do {
                return (main, try await main.ping())
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw refusal
            }
        }
    }

    /// A new 16-character salt for `coverArtSalt` (the app makes one per install and keeps it).
    public static func makeCoverArtSalt() -> String {
        Auth.makeSalt(length: 16)
    }

    /// This account's signed login as a query string, `u`, `t` and `s` with a fresh salt, for the
    /// server's own routes at `destination` (the levels and the hub, C27), which check it with the
    /// Navidrome next to them, so no account is stored on the server (D100). A token and salt never expire, so it goes only
    /// where this account's own requests already go (the review, D101):
    /// - **the same host** as the server's address or its LAN address, so no other machine gets it;
    /// - **no downgrade:** not to plain `http` when that address is `https`;
    /// - **never with legacy auth,** whose `p` is the password itself.
    /// Otherwise nil, and the bars keep their loop.
    public func signedLoginQuery(for destination: URL) -> String? {
        guard !config.sendsPlainPassword, let host = destination.host()?.lowercased() else { return nil }
        let addresses = [config.normalizedURL, config.normalizedHomeNetworkURL].compactMap { $0 }.compactMap(URL.init(string:))
        guard let server = addresses.first(where: { $0.host()?.lowercased() == host }) else { return nil }
        if server.scheme?.lowercased() == "https", destination.scheme?.lowercased() != "https" { return nil }
        return Auth.queryItems(for: config, salt: Auth.makeSalt())
            .filter { ["u", "t", "s"].contains($0.0) }
            .map { "\(Auth.encode($0.0))=\(Auth.encode($0.1))" }
            .joined(separator: "&")
    }

    // MARK: - Requests

    func url(_ endpoint: String, _ params: [(String, String)] = [], salt: String = Auth.makeSalt()) -> URL {
        Auth.url(base: baseURL, endpoint: endpoint, items: Auth.queryItems(for: config, salt: salt) + params)
    }

    func get<Payload: Decodable>(
        _ endpoint: String,
        _ params: [(String, String)] = [],
        payload key: String?,
        as type: Payload.Type = Payload.self
    ) async throws -> Response<Payload> {
        let data: Data
        let http: HTTPURLResponse
        let address = url(endpoint, params)
        do {
            if address.absoluteString.utf8.count > Self.longestGET {
                (data, http) = try await transport.post(address, timeout: Self.requestTimeout)
            } else {
                (data, http) = try await transport.get(address, timeout: Self.requestTimeout)
            }
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw SubsonicError.from(error)
        }
        if let error = SubsonicError.from(status: http.statusCode) {
            throw error
        }
        let response: Response<Payload>
        do {
            response = try Response<Payload>.decode(data, payloadKey: key)
        } catch {
            throw SubsonicError.invalidResponse
        }
        guard response.status == "ok" else {
            throw SubsonicError.api(code: response.errorCode ?? 0, message: response.errorMessage)
        }
        return response
    }

    func payload<Payload: Decodable>(
        _ endpoint: String,
        _ params: [(String, String)] = [],
        key: String
    ) async throws -> Payload {
        guard let payload = try await get(endpoint, params, payload: key, as: Payload.self).payload else {
            throw SubsonicError.invalidResponse
        }
        return payload
    }

    /// A list payload; a missing payload key reads as an empty list.
    func list<List: ListPayload>(
        _ endpoint: String,
        _ params: [(String, String)] = [],
        key: String,
        as type: List.Type
    ) async throws -> [List.Item] {
        try await get(endpoint, params, payload: key, as: List.self).payload?.items ?? []
    }

    /// Runs `first`; if it throws (other than cancellation), runs `fallback`.
    func withFallback<T>(
        _ first: () async throws -> T,
        _ fallback: () async throws -> T
    ) async throws -> T {
        do {
            return try await first()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await fallback()
        }
    }
}

// MARK: - URLs

extension SubsonicClient {
    /// The cover-art image URL, at `size` pixels (0 = original). A full `http(s)` URL is passed
    /// through; nil or empty gives nil. Uses the stable salt.
    public func coverArtURL(_ coverArt: String?, size: Int = 600) -> URL? {
        guard let coverArt, !coverArt.isEmpty else { return nil }
        if coverArt.hasPrefix("http://") || coverArt.hasPrefix("https://") {
            return URL(string: coverArt)
        }
        var params = [("id", coverArt)]
        if size > 0 {
            params.append(("size", String(size)))
        }
        return url("getCoverArt", params, salt: coverArtSalt)
    }

    /// The `stream` URL. `maxBitRate` (kbps) applies when above 0, `format` unless empty.
    public func streamURL(songID: String, maxBitRate: Int? = nil, format: String? = nil) -> URL {
        var params = [("id", songID)]
        if let maxBitRate, maxBitRate > 0 {
            params.append(("maxBitRate", String(maxBitRate)))
        }
        // `raw` asks for the untouched file (C11's "Original"), whatever the server would do otherwise.
        if let format, !format.isEmpty {
            params.append(("format", format))
        }
        return url("stream", params)
    }

    /// The `download` URL (the original file).
    public func downloadURL(songID: String) -> URL {
        url("download", [("id", songID)])
    }
}

// MARK: - System

extension SubsonicClient {
    /// Checks the address and login. Throws `SubsonicError.api(code: 40, …)` for a wrong login.
    public func ping() async throws -> ServerInfo {
        let response = try await get("ping", payload: nil, as: NoPayload.self)
        var type = response.type
        if type == nil, response.isOpenSubsonic {
            type = "OpenSubsonic"
        }
        return ServerInfo(
            type: type,
            serverVersion: response.serverVersion,
            isOpenSubsonic: response.isOpenSubsonic,
            apiVersion: response.apiVersion
        )
    }

    public func musicFolders() async throws -> [MusicFolder] {
        try await list("getMusicFolders", key: "musicFolders", as: MusicFolderList.self)
    }
}

// MARK: - Browsing

extension SubsonicClient {
    /// Every artist, the way the Flutter Library shows them: an entry crediting several artists
    /// (in `artists`, or a combined name like "A & B") becomes one artist per name; then
    /// duplicates by case-insensitive name merge (keeping an ID and cover where one is missing,
    /// and adding album counts); sorted by name, ignoring case.
    public func artists() async throws -> [Artist] {
        let index: ArtistIndex? = try await get("getArtists", payload: "artists").payload
        var raw: [Artist] = []
        for artist in index?.artists ?? [] {
            if let participants = artist.artists, participants.count > 1 {
                for participant in participants {
                    raw.append(Artist(
                        id: participant.id.isEmpty ? artist.id : participant.id,
                        name: participant.name,
                        coverArt: participant.coverToShow ?? artist.coverArt,
                        albumCount: artist.albumCount,
                        artistImageURL: artist.artistImageURL
                    ))
                }
                continue
            }
            let names = ArtistCredit.parseArtistCredits(artist.name)
            if names.count > 1 {
                for name in names {
                    raw.append(Artist(
                        id: artist.id,
                        name: name,
                        coverArt: artist.coverArt,
                        albumCount: artist.albumCount,
                        artistImageURL: artist.artistImageURL
                    ))
                }
            } else {
                raw.append(artist)
            }
        }

        var order: [String] = []
        var unique: [String: Artist] = [:]
        for artist in raw {
            let key = artist.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if key.isEmpty { continue }
            guard let existing = unique[key] else {
                unique[key] = artist
                order.append(key)
                continue
            }
            if (existing.id.isEmpty && !artist.id.isEmpty) || (existing.coverArt == nil && artist.coverArt != nil) {
                unique[key] = Artist(
                    id: artist.id.isEmpty ? existing.id : artist.id,
                    name: existing.name,
                    coverArt: artist.coverArt ?? existing.coverArt,
                    albumCount: (existing.albumCount ?? 0) + (artist.albumCount ?? 0),
                    artistImageURL: artist.artistImageURL ?? existing.artistImageURL
                )
            }
        }
        return order
            .compactMap { unique[$0] }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// One artist, with `albums` filled.
    public func artist(id: String) async throws -> Artist {
        try await payload("getArtist", [("id", id)], key: "artist")
    }

    /// The artist's albums (`getArtist`).
    public func artistAlbums(artistID: String) async throws -> [Album] {
        try await artist(id: artistID).albums
    }

    /// Biography, images and similar artists: `getArtistInfo2`, falling back to `getArtistInfo`. The
    /// fallback's similar artists are left out: its IDs are folders, which `getArtist` can't open.
    public func artistInfo(id: String) async throws -> ArtistInfo {
        try await withFallback {
            try await payload("getArtistInfo2", [("id", id)], key: "artistInfo2")
        } _: {
            var info: ArtistInfo = try await payload("getArtistInfo", [("id", id)], key: "artistInfo")
            info.similarArtists = []
            return info
        }
    }

    /// The artist's top songs (`getTopSongs` by the artist's name). If that fails, the songs of
    /// the artist's first three albums, up to `count` (Flutter `getArtistTopSongs`).
    public func topSongs(artistID: String, count: Int = 50) async throws -> [Song] {
        try await withFallback {
            let artist = try await artist(id: artistID)
            return try await list(
                "getTopSongs",
                [("artist", artist.name), ("count", String(count))],
                key: "topSongs",
                as: SongList.self
            )
        } _: {
            var songs: [Song] = []
            for album in try await artistAlbums(artistID: artistID).prefix(3) {
                songs += try await albumSongs(albumID: album.id)
                if songs.count >= count { break }
            }
            return Array(songs.prefix(count))
        }
    }

    /// One album, with `songs` filled.
    public func album(id: String) async throws -> Album {
        try await payload("getAlbum", [("id", id)], key: "album")
    }

    /// One song, as the server has it now (`getSong`): play counts in saved lists go stale.
    public func song(id: String) async throws -> Song {
        try await payload("getSong", [("id", id)], key: "song")
    }

    public func albumSongs(albumID: String) async throws -> [Song] {
        try await album(id: albumID).songs
    }

    /// A page of `getAlbumList2`.
    public func albumList(_ type: AlbumListType, size: Int = 20, offset: Int = 0) async throws -> [Album] {
        try await list(
            "getAlbumList2",
            [("type", type.rawValue), ("size", String(size)), ("offset", String(offset))],
            key: "albumList2",
            as: AlbumList.self
        )
    }

    public func randomSongs(size: Int = 20, genre: String? = nil) async throws -> [Song] {
        var params = [("size", String(size))]
        if let genre {
            params.append(("genre", genre))
        }
        return try await list("getRandomSongs", params, key: "randomSongs", as: SongList.self)
    }

    /// Songs like this one (for radio): `getSimilarSongs2`, falling back to `getSimilarSongs`.
    public func similarSongs(id: String, count: Int = 50) async throws -> [Song] {
        let params = [("id", id), ("count", String(count))]
        return try await withFallback {
            try await list("getSimilarSongs2", params, key: "similarSongs2", as: SongList.self)
        } _: {
            try await list("getSimilarSongs", params, key: "similarSongs", as: SongList.self)
        }
    }

    /// The user's starred artists, albums and songs (`getStarred2`).
    public func starred() async throws -> SearchResult {
        try await get("getStarred2", payload: "starred2", as: SearchResult.self).payload ?? SearchResult()
    }

    /// `search3`. An empty query lists everything on Navidrome, `songOffset` pages through it (C23).
    public func search(
        _ query: String,
        artistCount: Int = 20,
        albumCount: Int = 20,
        songCount: Int = 20,
        songOffset: Int = 0
    ) async throws -> SearchResult {
        var parameters = [
            ("query", query),
            ("artistCount", String(artistCount)),
            ("albumCount", String(albumCount)),
            ("songCount", String(songCount)),
        ]
        if songOffset > 0 { parameters.append(("songOffset", String(songOffset))) }
        return try await get(
            "search3",
            parameters,
            payload: "searchResult3",
            as: SearchResult.self
        ).payload ?? SearchResult()
    }
}

// MARK: - Playlists and lyrics

extension SubsonicClient {
    /// The user's playlists, without songs.
    public func playlists() async throws -> [Playlist] {
        try await list("getPlaylists", key: "playlists", as: PlaylistList.self)
    }

    /// One playlist, with `songs` filled.
    public func playlist(id: String) async throws -> Playlist {
        var playlist: Playlist = try await payload("getPlaylist", [("id", id)], key: "playlist")
        if playlist.songs == nil {
            playlist.songs = []
        }
        return playlist
    }

    /// Adds songs to the end of a playlist.
    public func addToPlaylist(id: String, songIDs: [String]) async throws {
        try await updatePlaylist(id: id, songIDsToAdd: songIDs)
    }

    /// A new playlist (`createPlaylist`).
    public func createPlaylist(name: String) async throws {
        _ = try await get("createPlaylist", [("name", name)], payload: nil, as: NoPayload.self)
    }

    /// `updatePlaylist`: a new name, songs added at the end, songs removed by their place. The places
    /// are all from before the call. Navidrome's measured behaviour, so they can come in any order.
    public func updatePlaylist(
        id: String,
        name: String? = nil,
        songIDsToAdd: [String] = [],
        songIndexesToRemove: [Int] = []
    ) async throws {
        var params = [("playlistId", id)]
        if let name { params.append(("name", name)) }
        params += songIDsToAdd.map { ("songIdToAdd", $0) }
        params += songIndexesToRemove.map { ("songIndexToRemove", String($0)) }
        _ = try await get("updatePlaylist", params, payload: nil, as: NoPayload.self)
    }

    /// Replaces a playlist's songs with this list, in this order, keeping its name (`createPlaylist`
    /// with the playlist's ID). `updatePlaylist` can only add at the end, so it can't move a song.
    public func setPlaylistSongs(id: String, songIDs: [String]) async throws {
        let songs = songIDs.map { ("songId", $0) }
        _ = try await get("createPlaylist", [("playlistId", id)] + songs, payload: nil, as: NoPayload.self)
    }

    public func deletePlaylist(id: String) async throws {
        _ = try await get("deletePlaylist", [("id", id)], payload: nil, as: NoPayload.self)
    }

    /// OpenSubsonic structured lyrics (synced where the server has them); empty when none.
    public func lyricsBySongID(_ id: String) async throws -> [StructuredLyrics] {
        try await list("getLyricsBySongId", [("id", id)], key: "lyricsList", as: StructuredLyricsList.self)
    }

    /// Plain lyrics by artist and title (`getLyrics`); nil when the server sends none.
    public func lyrics(artist: String?, title: String?) async throws -> Lyrics? {
        var params: [(String, String)] = []
        if let artist { params.append(("artist", artist)) }
        if let title { params.append(("title", title)) }
        return try await get("getLyrics", params, payload: "lyrics", as: Lyrics.self).payload
    }
}

// MARK: - Favourites, ratings and play counts

extension SubsonicClient {
    /// Adds a song, album or artist to the favourites (`star`).
    public func star(id: String? = nil, albumID: String? = nil, artistID: String? = nil) async throws {
        _ = try await get("star", Self.starParams(id, albumID, artistID), payload: nil, as: NoPayload.self)
    }

    /// Removes a song, album or artist from the favourites (`unstar`).
    public func unstar(id: String? = nil, albumID: String? = nil, artistID: String? = nil) async throws {
        _ = try await get("unstar", Self.starParams(id, albumID, artistID), payload: nil, as: NoPayload.self)
    }

    /// Rates a song from 0 (no rating) to 5 (`setRating`). Other values are a programming error.
    public func setRating(id: String, rating: Int) async throws {
        precondition((0...5).contains(rating), "Rating must be between 0 and 5")
        _ = try await get("setRating", [("id", id), ("rating", String(rating))], payload: nil, as: NoPayload.self)
    }

    /// Tells the server a song is playing (`submission: false`) or has been played (`true`).
    /// `time` is when it was played, for a play sent later (Subsonic's `time`, in milliseconds).
    public func scrobble(id: String, submission: Bool = true, time: Date? = nil) async throws {
        var params = [("id", id), ("submission", String(submission))]
        if let time { params.append(("time", String(Int64((time.timeIntervalSince1970 * 1000).rounded())))) }
        _ = try await get("scrobble", params, payload: nil, as: NoPayload.self)
    }

    private static func starParams(_ id: String?, _ albumID: String?, _ artistID: String?) -> [(String, String)] {
        var params: [(String, String)] = []
        if let id { params.append(("id", id)) }
        if let albumID { params.append(("albumId", albumID)) }
        if let artistID { params.append(("artistId", artistID)) }
        return params
    }
}

// MARK: - The saved play queue (C36)

extension SubsonicClient {
    /// The queue the server keeps for this account (`getPlayQueue`); nil when none is saved.
    /// Navidrome answers a `playQueue` even then (with no `entry` and a zero `changed`), so a
    /// queue with no songs reads as none.
    public func playQueue() async throws -> ServerPlayQueue? {
        let queue = try await get("getPlayQueue", payload: "playQueue", as: ServerPlayQueue.self).payload
        guard let queue, !queue.songs.isEmpty else { return nil }
        return queue
    }

    /// Replaces the queue the server keeps for this account (`savePlayQueue`): the songs in the
    /// order they play, the current one, and the place in it in milliseconds. Navidrome resumes at
    /// the first copy of `current`. **An empty list deletes the saved queue there**, so it sends nothing.
    /// A long queue goes as a POST (`get`).
    public func savePlayQueue(songIDs: [String], current: String?, positionMs: Int) async throws {
        guard !songIDs.isEmpty else { return }
        var params = songIDs.map { ("id", $0) }
        if let current { params.append(("current", current)) }
        params.append(("position", String(max(positionMs, 0))))
        _ = try await get("savePlayQueue", params, payload: nil, as: NoPayload.self)
    }
}

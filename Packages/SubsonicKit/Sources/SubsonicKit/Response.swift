import Foundation

/// The `subsonic-response` envelope, with the one payload key an endpoint answers under.
struct Response<Payload: Decodable>: Decodable {
    static var payloadKeyInfo: CodingUserInfoKey { CodingUserInfoKey(rawValue: "subsonicPayloadKey")! }

    var status: String?
    var apiVersion: String?
    var type: String?
    var serverVersion: String?
    var isOpenSubsonic: Bool
    var errorCode: Int?
    var errorMessage: String?
    var payload: Payload?

    init(from decoder: any Decoder) throws {
        let outer = try decoder.lenient()
        let c = try outer.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("subsonic-response"))
        status = c.string("status")
        apiVersion = c.string("version")
        type = c.string("type")
        serverVersion = c.string("serverVersion")
        isOpenSubsonic = c.bool("openSubsonic") ?? false
        if let error = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("error")) {
            errorCode = error.int("code")
            errorMessage = error.string("message")
        }
        if let key = decoder.userInfo[Self.payloadKeyInfo] as? String, c.has(key) {
            payload = try c.decode(Payload.self, forKey: AnyKey(key))
        }
    }

    static func decode(_ data: Data, payloadKey: String?) throws -> Response {
        let decoder = JSONDecoder()
        if let payloadKey {
            decoder.userInfo[payloadKeyInfo] = payloadKey
        }
        return try decoder.decode(Response.self, from: data)
    }
}

/// For endpoints with no payload (`ping`).
struct NoPayload: Decodable {}

/// A payload that is just one list under `key` (`{"song": [...]}`), lenient about a missing list
/// or a single object.
protocol ListPayload: Decodable {
    associatedtype Item: Decodable
    static var key: String { get }
    var items: [Item] { get }
    init(items: [Item])
}

extension ListPayload {
    init(from decoder: any Decoder) throws {
        self.init(items: try decoder.lenient().list(Self.key) ?? [])
    }
}

struct SongList: ListPayload {
    static var key: String { "song" }
    var items: [Song]
}

struct AlbumList: ListPayload {
    static var key: String { "album" }
    var items: [Album]
}

struct MusicFolderList: ListPayload {
    static var key: String { "musicFolder" }
    var items: [MusicFolder]
}

struct PlaylistList: ListPayload {
    static var key: String { "playlist" }
    var items: [Playlist]
}

struct StructuredLyricsList: ListPayload {
    static var key: String { "structuredLyrics" }
    var items: [StructuredLyrics]
}

/// `getArtists`: `{"index": [{"name": "C", "artist": [...]}, ...]}`, flattened.
struct ArtistIndex: Decodable {
    struct Entry: ListPayload {
        static var key: String { "artist" }
        var items: [Artist]
    }

    var artists: [Artist]

    init(from decoder: any Decoder) throws {
        let entries: [Entry] = try decoder.lenient().list("index") ?? []
        artists = entries.flatMap(\.items)
    }
}

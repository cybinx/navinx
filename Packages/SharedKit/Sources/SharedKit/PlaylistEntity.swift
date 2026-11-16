import AppIntents
import CoreSpotlight
import Foundation

/// A playlist as Siri, Shortcuts, Spotlight (C39) and the Playlist widget (C40) see it. No address:
/// a cover is the cached picture's bytes, or nothing.
public struct PlaylistEntity: IndexedEntity {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Playlist"
    public static let defaultQuery = PlaylistQuery()

    public let id: String
    public let name: String
    /// A small cover for Spotlight, only when indexing.
    public var artwork: Data?

    public init(id: String, name: String, artwork: Data? = nil) {
        self.id = id
        self.name = name
        self.artwork = artwork
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: artwork.map { DisplayRepresentation.Image(data: $0) })
    }

    public var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.title = name
        set.displayName = name
        set.thumbnailData = artwork
        return set
    }
}

/// In the app: the saved library's playlists, then the server's (C39). In the widgets extension
/// (choosing the Playlist widget's playlist): the ones the app last shared in the snapshot.
public struct PlaylistQuery: EntityStringQuery {
    public init() {}

    @MainActor
    public func entities(for identifiers: [String]) async throws -> [PlaylistEntity] {
        if let actions = IntentHost.actions { return await actions.playlists(withIDs: identifiers) }
        let byID = Dictionary(Self.shared().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { byID[$0] }
    }

    @MainActor
    public func entities(matching string: String) async throws -> [PlaylistEntity] {
        if let actions = IntentHost.actions { return await actions.playlists(matching: string) }
        let wanted = string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return [] }
        return Self.shared().filter {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(wanted)
        }
    }

    /// Every playlist: they are what "Play <playlist> in Navinx" listens for, and the widget's list.
    @MainActor
    public func suggestedEntities() async throws -> [PlaylistEntity] {
        if let actions = IntentHost.actions { return await actions.suggestedPlaylists() }
        return Self.shared()
    }

    private static func shared() -> [PlaylistEntity] {
        (WidgetStore.shared?.read()?.playlists ?? []).map { PlaylistEntity(id: $0.id, name: $0.name) }
    }
}

import AppIntents
import Foundation
import SharedKit

// The app's actions for Siri, Shortcuts, Spotlight and the Action button (C39, D156). The playing ones
// run in the background with no window (the system starts the app for them); the opening ones bring
// the app forward. None of them touches the server's tab.

/// Runs a request's work; signed out, it offers to open the app (Siri says why). `SharedKit`'s.
@MainActor
private func answer(_ intent: some AppIntent, _ work: () async throws(IntentServices.Answer) -> Void) async throws {
    try await answering(intent, work)
}

/// Opens a page; signed out, the app stays on its sign-in screen with no error (`SharedKit`'s `opening`).
@MainActor
private func openPage(_ destination: AppDestination, with services: IntentServices) async throws {
    try await opening { () async throws(IntentServices.Answer) in try await services.open(destination) }
}

/// `SharedKit`'s intents and playlist entity, in the app's own App Intents metadata (C40).
nonisolated struct NavinxIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [SharedKitIntents.self] }
}

// MARK: Playing

struct PlayAlbumIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Album"
    static let description: IntentDescription? = IntentDescription("Plays an album from your library in Navinx.")
    /// In the background, coming forward only to sign in.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Album", requestValueDialog: "Which album?")
    var album: AlbumEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$album)") { \.$shuffle }
    }

    @Dependency private var services: IntentServices

    init() {}

    init(album: AlbumEntity, shuffle: Bool = false) {
        self.album = album
        self.shuffle = shuffle
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let request = IntentServices.Request.album(id: album.id, shuffle: shuffle)
        try await answer(self) { () async throws(IntentServices.Answer) in try await services.play(request) }
        return .result()
    }
}

struct PlayArtistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Artist"
    static let description: IntentDescription? = IntentDescription("Plays an artist's top songs in Navinx.")
    /// In the background, coming forward only to sign in.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Artist", requestValueDialog: "Which artist?")
    var artist: ArtistEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$artist)") { \.$shuffle }
    }

    @Dependency private var services: IntentServices

    init() {}

    init(artist: ArtistEntity, shuffle: Bool = false) {
        self.artist = artist
        self.shuffle = shuffle
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let request = IntentServices.Request.artist(id: artist.artistID, shuffle: shuffle)
        try await answer(self) { () async throws(IntentServices.Answer) in try await services.play(request) }
        return .result()
    }
}

// Play Playlist, Play Favorites, Shuffle Library, Resume, Pause and Next Song are in `SharedKit`
// (C40): the widgets and controls carry them, so the extension compiles them too.

struct PreviousSongIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Song"
    static let description: IntentDescription? = IntentDescription("Goes back to the previous song in Navinx.")
    static let supportedModes: IntentModes = .background

    @Dependency private var services: IntentServices

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        services.previous()
        return .result()
    }
}

// MARK: Opening (Spotlight's taps, Shortcuts, Siri's search)

struct OpenAlbumIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Album"
    static let description: IntentDescription? = IntentDescription("Opens an album in Navinx.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Album")
    var target: AlbumEntity

    @Dependency private var services: IntentServices

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        try await openPage(.album(id: target.id), with: services)
        return .result()
    }
}

struct OpenArtistIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Artist"
    static let description: IntentDescription? = IntentDescription("Opens an artist in Navinx.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Artist")
    var target: ArtistEntity

    @Dependency private var services: IntentServices

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        try await openPage(.artist(id: target.artistID), with: services)
        return .result()
    }
}

struct OpenPlaylistIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Playlist"
    static let description: IntentDescription? = IntentDescription("Opens a playlist in Navinx.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Playlist")
    var target: PlaylistEntity

    @Dependency private var services: IntentServices

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        try await openPage(.playlist(id: target.id), with: services)
        return .result()
    }
}

struct SearchIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Search"
    static let description: IntentDescription? = IntentDescription("Searches your music in Navinx.")
    static let supportedModes: IntentModes = .foreground
    static let searchScopes: [StringSearchScope] = [.general]

    @Parameter(title: "Search", requestValueDialog: "What do you want to search for?")
    var criteria: StringSearchCriteria

    @Dependency private var services: IntentServices

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        let text = criteria.term.trimmingCharacters(in: .whitespacesAndNewlines)
        try await openPage(.search(text.isEmpty ? nil : text), with: services)
        return .result()
    }
}

// MARK: What Siri and Spotlight offer with no set-up

nonisolated struct NavinxShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .red

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayFavoritesIntent(),
            phrases: ["Play my favorites in \(.applicationName)"],
            shortTitle: "Play Favorites",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: ShuffleLibraryIntent(),
            phrases: ["Shuffle \(.applicationName)", "Shuffle my library in \(.applicationName)"],
            shortTitle: "Shuffle Library",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: ["Play \(\.$playlist) in \(.applicationName)"],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: PlayAlbumIntent(),
            phrases: ["Play an album in \(.applicationName)"],
            shortTitle: "Play Album",
            systemImageName: "square.stack"
        )
        AppShortcut(
            intent: PlayArtistIntent(),
            phrases: ["Play an artist in \(.applicationName)"],
            shortTitle: "Play Artist",
            systemImageName: "music.mic"
        )
        AppShortcut(
            intent: ResumeIntent(),
            phrases: ["Resume \(.applicationName)"],
            shortTitle: "Resume",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: SearchIntent(),
            phrases: ["Search \(.applicationName)"],
            shortTitle: "Search",
            systemImageName: "magnifyingglass"
        )
    }
}

import AppIntents
import Foundation

// The intents both the app and the widgets extension compile (C39's, moved here in C40), because a
// widget's or a control's button carries its intent. They run in the app's process only
// (`allowedExecutionTargets = [.main]`): the extension never signs in and never plays.

/// Lets the app and the extension take this package's intents and entity into their own metadata.
public struct SharedKitIntents: AppIntentsPackage {}

public struct PlayPlaylistIntent: AudioPlaybackIntent {
    public static let title: LocalizedStringResource = "Play Playlist"
    public static let description: IntentDescription? = IntentDescription("Plays one of your playlists in Navinx.")
    /// In the background, coming forward only to sign in.
    public static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    public static let allowedExecutionTargets: IntentExecutionTargets = [.main]

    @Parameter(title: "Playlist", requestValueDialog: "Which playlist?")
    public var playlist: PlaylistEntity

    @Parameter(title: "Shuffle", default: false)
    public var shuffle: Bool

    public static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist)") { \.$shuffle }
    }

    public init() {}

    public init(playlist: PlaylistEntity, shuffle: Bool = false) {
        self.playlist = playlist
        self.shuffle = shuffle
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        let request = PlayRequest.playlist(id: playlist.id, shuffle: shuffle)
        try await answering(self) { () async throws(IntentAnswer) in try await hostActions().play(request) }
        return .result()
    }
}

public struct PlayFavoritesIntent: AudioPlaybackIntent {
    public static let title: LocalizedStringResource = "Play Favorites"
    public static let description: IntentDescription? = IntentDescription("Plays your favorite songs in Navinx.")
    /// In the background, coming forward only to sign in.
    public static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    public static let allowedExecutionTargets: IntentExecutionTargets = [.main]

    @Parameter(title: "Shuffle", default: false)
    public var shuffle: Bool

    public static var parameterSummary: some ParameterSummary {
        Summary("Play favorites") { \.$shuffle }
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        let request = PlayRequest.favorites(shuffle: shuffle)
        try await answering(self) { () async throws(IntentAnswer) in try await hostActions().play(request) }
        return .result()
    }
}

public struct ShuffleLibraryIntent: AudioPlaybackIntent {
    public static let title: LocalizedStringResource = "Shuffle Library"
    public static let description: IntentDescription? = IntentDescription("Shuffles every song in your library in Navinx.")
    /// In the background, coming forward only to sign in.
    public static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    public static let allowedExecutionTargets: IntentExecutionTargets = [.main]

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        try await answering(self) { () async throws(IntentAnswer) in try await hostActions().play(.library) }
        return .result()
    }
}

public struct ResumeIntent: AudioPlaybackIntent {
    public static let title: LocalizedStringResource = "Resume"
    public static let description: IntentDescription? = IntentDescription("Plays the song in Navinx's player from where it stopped.")
    /// In the background, coming forward only to sign in.
    public static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    public static let allowedExecutionTargets: IntentExecutionTargets = [.main]

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        try await answering(self) { () async throws(IntentAnswer) in try await hostActions().play(.resume) }
        await IntentHost.actions?.refreshWidgets()
        return .result()
    }
}

public struct PauseIntent: AudioPlaybackIntent {
    public static let title: LocalizedStringResource = "Pause"
    public static let description: IntentDescription? = IntentDescription("Pauses Navinx.")
    public static let supportedModes: IntentModes = .background
    public static let allowedExecutionTargets: IntentExecutionTargets = [.main]

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        IntentHost.actions?.pause()
        await IntentHost.actions?.refreshWidgets()
        return .result()
    }
}

public struct NextSongIntent: AudioPlaybackIntent {
    public static let title: LocalizedStringResource = "Next Song"
    public static let description: IntentDescription? = IntentDescription("Skips to the next song in Navinx.")
    public static let supportedModes: IntentModes = .background
    public static let allowedExecutionTargets: IntentExecutionTargets = [.main]

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        await IntentHost.actions?.next()
        await IntentHost.actions?.refreshWidgets()
        return .result()
    }
}

/// The Search control's: opens the Search tab with nothing typed (Siri's search, which asks for the
/// text, stays the app's `SearchIntent`). Not offered in Shortcuts, where Search already is.
public struct OpenSearchIntent: AppIntent {
    public static let title: LocalizedStringResource = "Search Navinx"
    public static let description: IntentDescription? = IntentDescription("Opens Search in Navinx.")
    public static let supportedModes: IntentModes = .foreground
    public static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    public static let isDiscoverable = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        try await opening { () async throws(IntentAnswer) in try await hostActions().open(.search(nil)) }
        return .result()
    }
}

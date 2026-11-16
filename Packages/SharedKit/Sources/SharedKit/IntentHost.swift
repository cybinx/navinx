import AppIntents
import Foundation

/// What a playing request asks for (C39; shared since C40 so the widgets' intents can carry it).
public enum PlayRequest: Equatable, Sendable {
    case album(id: String, shuffle: Bool)
    case artist(id: String, shuffle: Bool)
    case playlist(id: String, shuffle: Bool)
    case favorites(shuffle: Bool)
    /// Every song, shuffled (as Library → Songs → Shuffle).
    case library
    /// What's in the player, from where it is (the kept song too, D81).
    case resume
}

/// What a request answers when it can't play; Siri says it, and a quick action shows it.
public enum IntentAnswer: Error, Equatable, Sendable, CustomLocalizedStringResourceConvertible {
    case signIn, locked, unreachable, notDownloaded, needsServer, nothingToPlay, failed

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signIn: "Sign in to Navinx first."
        case .locked: "Unlock your iPhone first."
        case .unreachable: "Navinx can't reach your server."
        case .notDownloaded: "That isn't downloaded."
        case .needsServer: "Favorites need your server."
        case .nothingToPlay: "There's nothing to play yet."
        case .failed: "Navinx couldn't load those songs."
        }
    }

    public var message: String { String(localized: localizedStringResource) }
}

/// The app's side of the shared intents: only the app has the login and the player, so these
/// intents run in the app's process (`allowedExecutionTargets = [.main]`) and reach it through this.
@MainActor
public protocol IntentActions: AnyObject {
    func play(_ request: PlayRequest) async throws(IntentAnswer)
    func pause()
    /// Async: with the app only just started by the widget's button, the queue is loaded first.
    func next() async
    func open(_ destination: AppDestination) async throws(IntentAnswer)
    /// The widgets' snapshot brought up to date now (after a widget's button), before the system
    /// redraws them.
    func refreshWidgets() async
    /// The playlists for `PlaylistQuery` when it runs in the app: the saved library's, else the server's.
    func playlists(withIDs ids: [String]) async -> [PlaylistEntity]
    func playlists(matching text: String) async -> [PlaylistEntity]
    func suggestedPlaylists() async -> [PlaylistEntity]
}

/// Where the shared intents find the app. Set by the app at launch; never in the widgets extension.
@MainActor
public enum IntentHost {
    public static var actions: (any IntentActions)?
}

/// Runs a request's work; signed out, it offers to open the app (Siri says why).
@MainActor
public func answering(_ intent: some AppIntent, _ work: () async throws(IntentAnswer) -> Void) async throws {
    do {
        try await work()
    } catch .signIn where intent.systemContext.currentMode.canContinueInForeground {
        try await intent.continueInForeground(IntentDialog(IntentAnswer.signIn.localizedStringResource))
    }
}

/// Runs an opening request's work (the intent has already brought the app forward). Signed out, the
/// app is left on its sign-in screen, which says what's needed: no error on top of it.
@MainActor
public func opening(_ work: () async throws(IntentAnswer) -> Void) async throws(IntentAnswer) {
    do {
        try await work()
    } catch .signIn {
        return
    }
}

/// The app's actions, or the answer that the app isn't there to do them (never expected: these
/// intents only run in the app).
@MainActor
func hostActions() throws(IntentAnswer) -> any IntentActions {
    guard let actions = IntentHost.actions else { throw .failed }
    return actions
}

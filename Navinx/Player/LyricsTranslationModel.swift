import Foundation
import Lyrics
import Observation
import Translation

/// Whether a pair of languages can be translated on this phone (Translation's `LanguageAvailability`).
nonisolated enum TranslationAvailability: Sendable, Equatable {
    case installed
    /// Supported, but the system must download a language first (its own sheet asks).
    case needsDownload
    case unsupported
}

/// What translates the lyrics: Apple's on the phone, or a stand-in for tests and pictures.
nonisolated protocol LyricsTranslator: Sendable {
    func availability(from source: Locale.Language, to target: Locale.Language) async -> TranslationAvailability
    /// The answers in the order of `texts`.
    func translate(_ texts: [String], from source: Locale.Language, to target: Locale.Language) async throws -> [String]
}

/// Apple's Translation framework, for languages already on the phone. A session made this way belongs to
/// no view (a `translationTask` session must not outlive its view) and never asks for a download; the
/// download is `LyricsPage`'s `translationTask`, on the user's tap.
nonisolated struct SystemLyricsTranslator: LyricsTranslator {
    func availability(from source: Locale.Language, to target: Locale.Language) async -> TranslationAvailability {
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: .installed
        case .supported: .needsDownload
        case .unsupported: .unsupported
        @unknown default: .unsupported
        }
    }

    func translate(_ texts: [String], from source: Locale.Language, to target: Locale.Language) async throws -> [String] {
        let session = TranslationSession(installedSource: source, target: target)
        // The answers come back in the order the requests went (`translations(from:)`).
        let responses = try await session.translations(from: texts.map { TranslationSession.Request(sourceText: $0) })
        return responses.map(\.targetText)
    }
}

#if DEBUG
/// `-UITestFakeTranslation`: every pair is installed, and each line comes back marked, after a moment.
nonisolated struct FakeLyricsTranslator: LyricsTranslator {
    func availability(from source: Locale.Language, to target: Locale.Language) async -> TranslationAvailability {
        .installed
    }

    func translate(_ texts: [String], from source: Locale.Language, to target: Locale.Language) async throws -> [String] {
        try await Task.sleep(for: .milliseconds(400))
        return texts.map { "(\(target.minimalIdentifier)) \($0)" }
    }
}
#endif

/// Now playing's lyrics translation (C38): whether the Translate button shows, whether it's on, and each
/// line's translation. One for the app, so translations outlive now playing's page (kept in memory per
/// song and target language for the app's session, never on disk).
@Observable
final class LyricsTranslationModel {
    static let shared = LyricsTranslationModel()

    /// The language to translate into: the phone's first language (the app itself is English only, so
    /// `Locale.current` would say English).
    let target: Locale.Language
    private let translator: any LyricsTranslator

    /// The user's choice, kept across songs and launches.
    private(set) var isOn: Bool {
        didSet { UserDefaults.standard.set(isOn, forKey: LyricsSettings.translate) }
    }
    /// The current lyric's language and how it can be translated; nil when there's nothing to do.
    private(set) var source: Locale.Language?
    private(set) var availability: TranslationAvailability?
    /// The current lyric's translations, by line.
    private(set) var translations: [Int: String] = [:]
    private(set) var isTranslating = false
    /// Set to ask for the system's language download; `LyricsPage`'s `translationTask` answers it.
    var downloadRequest: TranslationSession.Configuration?

    private var songID: String?
    private var lines: [LyricLine] = []
    private var cache: [String: [Int: String]] = [:]
    private var work: Task<Void, Never>?
    /// Raises the toast when a translation the user asked for fails.
    var onFailure: (() -> Void)?

    /// The button shows when the lyric can be translated here at all.
    var showsButton: Bool { source != nil && availability != nil && availability != .unsupported }
    /// Lit while translating or translated.
    var isLit: Bool { isOn && availability == .installed }

    private init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-UITestFakeTranslation") {
            translator = FakeLyricsTranslator()
            // English test lyrics, so a target other than English; on from the start for the picture.
            target = Locale.Language(identifier: "fr")
            isOn = true
            return
        }
        #endif
        translator = SystemLyricsTranslator()
        target = Locale.preferredLanguages.first.map(Locale.Language.init(identifier:)) ?? Locale.current.language
        isOn = UserDefaults.standard.bool(forKey: LyricsSettings.translate)
    }

    private var cacheKey: String? {
        songID.map { "\($0)|\(target.maximalIdentifier)" }
    }

    /// New lyrics, or none (nil while loading). Whatever was under way for the last song stops.
    func show(songID: String?, lines: [LyricLine]?) {
        work?.cancel()
        isTranslating = false
        translations = [:]
        source = nil
        availability = nil
        self.songID = songID
        self.lines = lines ?? []
        guard let lines, !lines.isEmpty else { return }
        guard let source = LyricsTranslation.source(for: LyricsTranslation.detect(lines), target: target) else { return }
        self.source = source
        work = Task {
            let availability = await translator.availability(from: source, to: target)
            guard !Task.isCancelled else { return }
            self.availability = availability
            if isOn, availability == .installed { await translate(askedByUser: false) }
        }
    }

    /// The Translate button.
    func toggle() {
        if isLit {
            work?.cancel()
            isTranslating = false
            isOn = false
            return
        }
        switch availability {
        case .installed:
            isOn = true
            work?.cancel()
            work = Task { await translate(askedByUser: true) }
        case .needsDownload:
            guard let source else { return }
            downloadRequest = TranslationSession.Configuration(source: source, target: target)
        case .unsupported, nil:
            break
        }
    }

    /// The system's download sheet is done: the languages are in, or the user said no (the button stays off).
    func downloadFinished(succeeded: Bool) {
        downloadRequest = nil
        guard succeeded else { return }
        availability = .installed
        isOn = true
        work?.cancel()
        work = Task { await translate(askedByUser: true) }
    }

    private func translate(askedByUser: Bool) async {
        guard let source, let key = cacheKey else { return }
        if let cached = cache[key] {
            translations = cached
            return
        }
        let lines = lines
        let texts = LyricsTranslation.texts(for: lines)
        guard !texts.isEmpty else { return }
        isTranslating = true
        defer { if !Task.isCancelled { isTranslating = false } }
        do {
            let answers = try await translator.translate(texts, from: source, to: target)
            guard !Task.isCancelled, cacheKey == key else { return }
            let paired = LyricsTranslation.pair(lines: lines, texts: texts, translations: answers)
            cache[key] = paired
            translations = paired
        } catch {
            guard !Task.isCancelled else { return }
            if askedByUser {
                isOn = false
                onFailure?()
            }
        }
    }
}

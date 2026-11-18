import Foundation
import Lyrics
import Testing
@testable import Navinx

/// The lyrics lookup's answer (D179): off until the user says yes, asked once on the lyrics page.
@Suite struct LyricsLookupTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "LyricsLookupTests-\(UUID().uuidString)"))
    }

    @Test func neverAnsweredMeansNoLookup() throws {
        let defaults = try defaults()
        #expect(LyricsSettings.usesLRCLib(in: defaults) == false)
    }

    @Test func aSavedAnswerIsKept() throws {
        let defaults = try defaults()
        defaults.set(true, forKey: LyricsSettings.lrclibFallback)
        #expect(LyricsSettings.usesLRCLib(in: defaults))
        defaults.set(false, forKey: LyricsSettings.lrclibFallback)
        #expect(LyricsSettings.usesLRCLib(in: defaults) == false)
    }

    @Test func theKeyIsTheSavedOne() {
        #expect(LyricsSettings.lrclibFallback == "lrclib_fallback")
    }

    private static let line = LyricLine(text: "a line", start: 0)

    private func asks(
        answer: Bool? = nil,
        page: Bool = true,
        lines: [LyricLine]? = [],
        current: Bool = true,
        online: Bool = true
    ) -> Bool {
        LyricsLookupPermission.asks(
            answer: answer,
            isLyricsPageShowing: page,
            lines: lines,
            linesAreForCurrentSong: current,
            isOnline: online
        )
    }

    @Test func asksOnlyWhenEverythingHolds() {
        #expect(asks())
    }

    @Test func noQuestionOtherwise() {
        #expect(!asks(answer: true), "already allowed")
        #expect(!asks(answer: false), "already declined")
        #expect(!asks(page: false), "not on the lyrics page")
        #expect(!asks(lines: nil), "still loading")
        #expect(!asks(lines: [Self.line]), "the server had lyrics")
        #expect(!asks(current: false), "loaded for another song or before a reload")
        #expect(!asks(online: false), "offline")
    }
}

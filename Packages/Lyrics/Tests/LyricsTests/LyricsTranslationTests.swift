import Foundation
import Testing
@testable import Lyrics

@Suite struct LyricsTranslationTests {
    private let english = Locale.Language(identifier: "en-US")

    @Test func aForeignLyricIsTranslatedFromItsLanguage() {
        let detection = LyricsTranslation.Detection(language: "es", confidence: 0.9, letters: 120)
        #expect(LyricsTranslation.source(for: detection, target: english)?.languageCode == .spanish)
    }

    @Test func nothingToDoInThePhonesLanguage() {
        let detection = LyricsTranslation.Detection(language: "en", confidence: 0.95, letters: 300)
        #expect(LyricsTranslation.source(for: detection, target: english) == nil)
    }

    @Test func nothingToDoWhenTooShortOrUnsure() {
        let short = LyricsTranslation.Detection(language: "fr", confidence: 0.9, letters: 12)
        let unsure = LyricsTranslation.Detection(language: "fr", confidence: 0.3, letters: 200)
        #expect(LyricsTranslation.source(for: short, target: english) == nil)
        #expect(LyricsTranslation.source(for: unsure, target: english) == nil)
        #expect(LyricsTranslation.source(for: nil, target: english) == nil)
    }

    @Test func chineseScriptsAreDifferentLanguages() {
        let simplified = Locale.Language(identifier: "zh-Hans")
        #expect(!LyricsTranslation.isSameLanguage(simplified, Locale.Language(identifier: "zh-Hant-TW")))
        #expect(LyricsTranslation.isSameLanguage(simplified, Locale.Language(identifier: "zh-CN")))
        #expect(LyricsTranslation.isSameLanguage(Locale.Language(identifier: "en-GB"), english))
    }

    @Test func aChorusIsSentOnceAndPairedEverywhere() {
        let lines = ["Hola", "Te quiero", "Hola", " Adiós "].map { LyricLine(text: $0, start: 0) }
        let texts = LyricsTranslation.texts(for: lines)
        #expect(texts == ["Hola", "Te quiero", "Adiós"])
        let paired = LyricsTranslation.pair(lines: lines, texts: texts, translations: ["Hello", "I love you", "Goodbye"])
        #expect(paired == [0: "Hello", 1: "I love you", 2: "Hello", 3: "Goodbye"])
    }

    /// C47 (the check's F1): a line with no letter is never sent, and keeps no translation.
    @Test func linesWithNoLettersAreNotSent() {
        let lines = ["♪", "Hola", "...", "—", "1, 2, 3", "¡Vamos!", "♪ ♪"].map { LyricLine(text: $0, start: 0) }
        let texts = LyricsTranslation.texts(for: lines)
        #expect(texts == ["Hola", "¡Vamos!"])
        let paired = LyricsTranslation.pair(lines: lines, texts: texts, translations: ["Hello", "Let's go!"])
        #expect(paired == [1: "Hello", 5: "Let's go!"])
    }

    @Test func aTranslationThatRepeatsTheLineIsLeftOut() {
        let lines = ["La la la!", "Mañana", "Corazón"].map { LyricLine(text: $0, start: 0) }
        let texts = LyricsTranslation.texts(for: lines)
        let paired = LyricsTranslation.pair(lines: lines, texts: texts, translations: ["la, la, la", "Tomorrow", "  "])
        #expect(paired == [1: "Tomorrow"])
    }

    @Test func recognisesALyricsLanguage() throws {
        let lines = [
            "Cuando te veo, mi corazón se llena de alegría",
            "y no quiero que esta noche se termine nunca",
        ].map { LyricLine(text: $0, start: 0) }
        let detection = try #require(LyricsTranslation.detect(lines))
        #expect(detection.language == "es")
        #expect(LyricsTranslation.source(for: detection, target: english) != nil)
    }
}

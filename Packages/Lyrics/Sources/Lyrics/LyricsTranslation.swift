import Foundation
import NaturalLanguage

/// The pure half of lyrics translation (C38): whether there is anything to translate, what to send,
/// and which line each answer belongs to. The translating itself is the app's (Apple's Translation
/// framework, on the phone).
public enum LyricsTranslation {
    /// Fewer letters than this and the language can't be told reliably.
    public static let minimumLetters = 20
    /// The recogniser's confidence below which the lyric's language is taken as unknown.
    public static let minimumConfidence = 0.5

    /// What the recogniser made of a lyric.
    public struct Detection: Sendable, Equatable {
        /// A BCP 47 code, as `NLLanguage`'s raw value ("es", "zh-Hans").
        public var language: String
        public var confidence: Double
        /// How many letters the lyric has.
        public var letters: Int

        public init(language: String, confidence: Double, letters: Int) {
            self.language = language
            self.confidence = confidence
            self.letters = letters
        }
    }

    /// The whole lyric's language, from all its lines together; nil when the recogniser has no guess.
    public static func detect(_ lines: [LyricLine]) -> Detection? {
        let text = lines.map(\.text).joined(separator: "\n")
        let letters = text.unicodeScalars.filter(CharacterSet.letters.contains).count
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0
        return Detection(language: language.rawValue, confidence: confidence, letters: letters)
    }

    /// The language to translate from, or nil when there's nothing to do: no guess, too little text to
    /// tell, too unsure, or already in the target language.
    public static func source(for detection: Detection?, target: Locale.Language) -> Locale.Language? {
        guard let detection, detection.letters >= minimumLetters, detection.confidence >= minimumConfidence else {
            return nil
        }
        let source = Locale.Language(identifier: detection.language)
        return isSameLanguage(source, target) ? nil : source
    }

    /// The same language for a reader: the same code ("en-GB" is "en"), and for Chinese the same script
    /// (simplified and traditional are translated between).
    public static func isSameLanguage(_ first: Locale.Language, _ second: Locale.Language) -> Bool {
        guard let code = first.languageCode, code == second.languageCode else { return false }
        guard code == .chinese else { return true }
        return Locale.Language(identifier: first.maximalIdentifier).script
            == Locale.Language(identifier: second.maximalIdentifier).script
    }

    /// The texts to send, each once (a chorus is translated once), in the order they first come.
    /// A line with no letter in it ("♪", "...", "—") isn't sent: there's nothing to translate, and
    /// one such text may fail the whole request (C47, the check's F1).
    public static func texts(for lines: [LyricLine]) -> [String] {
        var seen = Set<String>()
        return lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.contains(where: \.isLetter) && seen.insert($0).inserted }
    }

    /// Each line's translation by its place in the lyric, from `texts`' answers in their order. A
    /// translation that only repeats the line (a name, a "la la la") is left out, so nothing shows twice.
    public static func pair(lines: [LyricLine], texts: [String], translations: [String]) -> [Int: String] {
        var byText: [String: String] = [:]
        for (text, translation) in zip(texts, translations) {
            let translation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
            if !translation.isEmpty, simplified(translation) != simplified(text) { byText[text] = translation }
        }
        var paired: [Int: String] = [:]
        for (index, line) in lines.enumerated() {
            if let translation = byText[line.text.trimmingCharacters(in: .whitespacesAndNewlines)] {
                paired[index] = translation
            }
        }
        return paired
    }

    /// Letters and digits only, without case or accents, for telling a translation from its line.
    private static func simplified(_ text: String) -> String {
        String(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }
}

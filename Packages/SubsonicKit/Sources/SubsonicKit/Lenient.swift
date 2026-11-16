import Foundation

/// Lenient reading of Subsonic JSON, for servers that differ in small ways: IDs as numbers or
/// strings, numbers as strings, a single object where a list is expected, missing lists
/// (Navidrome sends `"playlists": {}` when there are none). A field of the wrong type reads as nil
/// rather than failing the whole response.
struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where Key == AnyKey {
    /// True when the key is present and not `null`.
    func has(_ key: String) -> Bool {
        let key = AnyKey(key)
        return contains(key) && ((try? decodeNil(forKey: key)) == false)
    }

    func string(_ key: String) -> String? {
        let key = AnyKey(key)
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        if let value = try? decode(Bool.self, forKey: key) { return String(value) }
        return nil
    }

    func int(_ key: String) -> Int? {
        let key = AnyKey(key)
        if let value = try? decode(Int.self, forKey: key) { return value }
        // `Int(_:)` would trap on a number too big for an Int (1e19): that reads as nil instead.
        if let value = try? decode(Double.self, forKey: key) { return Int(exactly: value.rounded(.towardZero)) }
        if let value = try? decode(String.self, forKey: key) { return Int(value.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// A number, or a string like `"-6.5 dB"` or `"95%"` (the Flutter app's `parseGain`).
    func double(_ key: String) -> Double? {
        let key = AnyKey(key)
        if let value = try? decode(Double.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) {
            let cleaned = value
                .replacingOccurrences(of: "dB", with: "")
                .replacingOccurrences(of: "db", with: "")
                .replacingOccurrences(of: "%", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Double(cleaned)
        }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        let key = AnyKey(key)
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) {
            switch value.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        }
        return nil
    }

    func date(_ key: String) -> Date? {
        string(key).flatMap(SubsonicDate.parse)
    }

    func object<T: Decodable>(_ key: String, as type: T.Type = T.self) -> T? {
        try? decode(T.self, forKey: AnyKey(key))
    }

    /// A list, or a single object read as a one-element list; nil when the key is absent.
    func list<T: Decodable>(_ key: String, of type: T.Type = T.self) -> [T]? {
        let key = AnyKey(key)
        guard has(key.stringValue) else { return nil }
        if let values = try? decode([T].self, forKey: key) { return values }
        if let value = try? decode(T.self, forKey: key) { return [value] }
        return nil
    }
}

extension Decoder {
    func lenient() throws -> KeyedDecodingContainer<AnyKey> {
        try container(keyedBy: AnyKey.self)
    }
}

/// Subsonic dates: ISO 8601, with or without fractional seconds. Navidrome sends nanoseconds
/// (`2026-11-03T19:44:38.428117505Z`), more digits than Foundation's parser takes, so the
/// fraction is cut to milliseconds first.
enum SubsonicDate {
    static func parse(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if let date = try? Date(trimmed, strategy: Date.ISO8601FormatStyle()) { return date }
        let millis = trimmingFraction(trimmed)
        if let date = try? Date(millis, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return nil
    }

    /// `…:38.428117505Z` → `…:38.428Z` (pads short fractions to three digits).
    private static func trimmingFraction(_ string: String) -> String {
        guard let dot = string.firstIndex(of: ".") else { return string }
        let afterDot = string.index(after: dot)
        let digitsEnd = string[afterDot...].firstIndex { !$0.isNumber } ?? string.endIndex
        var digits = String(string[afterDot..<digitsEnd].prefix(3))
        while digits.count < 3 { digits.append("0") }
        return String(string[..<afterDot]) + digits + String(string[digitsEnd...])
    }
}

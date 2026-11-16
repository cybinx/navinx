import Foundation

// The screens the server sends to the hub tab (schema v1, `docs/log/C27.md`). Decoding is
// lenient on purpose, so the server can grow without breaking older builds: unknown fields are
// ignored, a part of an unknown type (or one that can't be read) is skipped, and an unknown enum
// value takes its default. Only a screen whose `v` isn't 1 is refused.

/// A whole screen: the tab's root, a pushed page, a sheet or Search's section.
public struct HubScreen: Sendable, Equatable, Decodable {
    /// The only version this build understands.
    public static let version = 1

    public var id: String
    /// The navigation title; empty for none.
    public var title: String
    /// The tab's title and symbol (the root screen only).
    public var tab: HubTab?
    /// Seconds between refreshes while the screen is visible; nil for never.
    public var refresh: Int?
    /// The sheet's first detent, when shown as a sheet.
    public var sheetHeight: Double?
    public var sections: [HubSection]

    public init(
        id: String, title: String = "", tab: HubTab? = nil, refresh: Int? = nil, sheetHeight: Double? = nil,
        sections: [HubSection] = []
    ) {
        self.id = id
        self.title = title
        self.tab = tab
        self.refresh = refresh
        self.sheetHeight = sheetHeight
        self.sections = sections
    }

    private enum CodingKeys: String, CodingKey { case v, id, title, tab, refresh, sheetHeight, sections }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .v)
        guard version == Self.version else {
            throw DecodingError.dataCorruptedError(forKey: .v, in: c, debugDescription: "")
        }
        id = try c.decode(String.self, forKey: .id)
        // A title that isn't text is no title, not a screen that can't be read.
        title = c.text(.title) ?? ""
        tab = try? c.decodeIfPresent(HubTab.self, forKey: .tab)
        // Every number that feeds layout or a conversion is kept in a sane range (a day at most; a
        // sheet no taller than a screen could be).
        refresh = (try? c.decodeIfPresent(Int.self, forKey: .refresh)).flatMap { $0 > 0 ? min($0, 86_400) : nil }
        sheetHeight = c.size(.sheetHeight, max: 3000).flatMap { $0 > 0 ? $0 : nil }
        // The first `maxSections` sections, with no more than `maxParts` parts among them; a section after
        // the parts have run out goes too. What lies beyond isn't decoded at all.
        var kept: [HubSection] = []
        var left = Self.maxParts
        if var list = try c.list(forKey: .sections) {
            while kept.count < Self.maxSections, left > 0, !list.isAtEnd {
                guard var section = try list.decode(Lenient<HubSection>.self).value else { continue }
                section.parts = Array(section.parts.prefix(left))
                left -= section.parts.count
                kept.append(section)
            }
        }
        // A section id is SwiftUI's identity for it: a repeated one gets a suffix.
        var seen: Set<String> = []
        for index in kept.indices {
            let base = kept[index].id
            var id = base
            var n = 1
            while !seen.insert(id).inserted {
                n += 1
                id = "\(base)-\(n)"
            }
            kept[index].id = id
        }
        sections = Self.limitingPictures(kept)
    }

    /// The most sections and parts a screen draws: far more than a screen needs, so a server can't
    /// make the phone lay out an endless one. What comes after is left out.
    public static let maxSections = 100
    public static let maxParts = 500
    /// The most pictures one screen loads (row covers and image parts together, top to bottom): the ones
    /// after it show the placeholder.
    public static let maxPictures = 200
    /// The longest text drawn, in Unicode scalars (a title, a text, a label, a value, a toast): a longer
    /// one is cut there. Ids, symbols and addresses are kept as sent.
    public static let maxTextLength = 10_000

    /// The sections with every picture after the first `maxPictures` left out.
    static func limitingPictures(_ sections: [HubSection]) -> [HubSection] {
        var left = maxPictures
        return sections.map { section in
            var section = section
            section.parts = section.parts.map { part in
                switch part {
                case .row(var row) where row.image != nil:
                    if left > 0 { left -= 1 } else { row.image = nil }
                    return .row(row)
                case .image(var image) where image.url != nil:
                    if left > 0 { left -= 1 } else { image.url = nil }
                    return .image(image)
                default:
                    return part
                }
            }
            return section
        }
    }

    /// Every field part on the screen, in order.
    public var fields: [HubField] {
        sections.flatMap(\.parts).compactMap { if case .field(let field) = $0 { field } else { nil } }
    }

    /// Every choice part on the screen, in order.
    public var choices: [HubChoice] {
        sections.flatMap(\.parts).compactMap { if case .choice(let choice) = $0 { choice } else { nil } }
    }
}

public struct HubTab: Sendable, Equatable, Decodable {
    public var title: String
    /// An SF Symbol's name.
    public var symbol: String

    public init(title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    private enum CodingKeys: String, CodingKey { case title, symbol }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = clipped(try c.decode(String.self, forKey: .title))
        symbol = try c.decode(String.self, forKey: .symbol)
    }
}

public struct HubSection: Sendable, Equatable, Decodable, Identifiable {
    public enum Card: String, Sendable, Equatable, LenientEnum {
        case glass, plain, none
        public static let fallback = Card.glass
    }

    /// The most a server's gap may be, in points.
    static let maxGap: Double = 200

    public var id: String
    public var title: String?
    /// An icon-only button at the end of the title's line.
    public var button: HubButton?
    /// Points above the section; nil for the default.
    public var gap: Double?
    public var card: Card
    public var parts: [HubPart]

    public init(
        id: String, title: String? = nil, button: HubButton? = nil, gap: Double? = nil, card: Card = .glass,
        parts: [HubPart] = []
    ) {
        self.id = id
        self.title = title
        self.button = button
        self.gap = gap
        self.card = card
        self.parts = parts
    }

    private enum CodingKeys: String, CodingKey { case id, title, button, gap, card, parts }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = c.text(.title)
        button = try? c.decodeIfPresent(HubButton.self, forKey: .button)
        gap = c.size(.gap, max: Self.maxGap)
        card = try c.decodeIfPresent(Card.self, forKey: .card) ?? .glass
        // No section draws more than a screen's parts: the rest isn't decoded.
        var parts: [HubPart] = []
        if var list = try c.list(forKey: .parts) {
            while parts.count < HubScreen.maxParts, !list.isAtEnd {
                if let part = try list.decode(Lenient<HubPart>.self).value { parts.append(part) }
            }
        }
        self.parts = parts
    }
}

// MARK: - Parts

public enum HubPart: Sendable, Equatable, Decodable {
    case text(HubText)
    case field(HubField)
    case choice(HubChoice)
    case button(HubButton)
    case row(HubRow)
    case progress(HubProgress)
    case image(HubImage)

    private enum CodingKeys: String, CodingKey { case type, gap }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let gap = c.size(.gap, max: HubSection.maxGap)
        switch try c.decode(String.self, forKey: .type) {
        case "text": self = .text(try HubText(from: decoder))
        case "field": self = .field(try HubField(from: decoder))
        case "choice": self = .choice(try HubChoice(from: decoder))
        case "button":
            var button = try HubButton(from: decoder)
            button.gap = gap
            self = .button(button)
        case "row": self = .row(try HubRow(from: decoder))
        case "progress": self = .progress(try HubProgress(from: decoder))
        case "image": self = .image(try HubImage(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "")
        }
    }

    /// The server's id, if any.
    public var id: String? {
        switch self {
        case .text(let part): part.id
        case .field(let part): part.id
        case .choice(let part): part.id
        case .button(let part): part.id
        case .row(let part): part.id
        case .progress(let part): part.id
        case .image(let part): part.id
        }
    }

    /// Points above the part inside its section; nil for the default.
    public var gap: Double? {
        switch self {
        case .text(let part): part.gap
        case .field(let part): part.gap
        case .choice(let part): part.gap
        case .button(let part): part.gap
        case .row(let part): part.gap
        case .progress(let part): part.gap
        case .image(let part): part.gap
        }
    }
}

public enum HubTint: String, Sendable, Equatable {
    case accent, secondary, red, orange, green
}

public struct HubText: Sendable, Equatable, Decodable {
    public enum Style: String, Sendable, Equatable, LenientEnum {
        case headline, body, subhead, strong, secondary, caption
        public static let fallback = Style.subhead
    }

    public enum Align: String, Sendable, Equatable, LenientEnum {
        case leading, center
        public static let fallback = Align.leading
    }

    public var id: String?
    public var gap: Double?
    public var text: String
    public var style: Style
    public var tint: HubTint?
    public var symbol: String?
    public var align: Align
    public var lines: Int?
    public var label: String?
    public var labelWidth: Double?
    public var button: HubButton?

    public init(
        id: String? = nil, gap: Double? = nil, text: String, style: Style = .subhead, tint: HubTint? = nil,
        symbol: String? = nil, align: Align = .leading, lines: Int? = nil, label: String? = nil,
        labelWidth: Double? = nil, button: HubButton? = nil
    ) {
        self.id = id
        self.gap = gap
        self.text = text
        self.style = style
        self.tint = tint
        self.symbol = symbol
        self.align = align
        self.lines = lines
        self.label = label
        self.labelWidth = labelWidth
        self.button = button
    }

    private enum CodingKeys: String, CodingKey { case id, gap, text, style, tint, symbol, align, lines, label, labelWidth, button }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        gap = c.size(.gap, max: HubSection.maxGap)
        text = clipped(try c.decode(String.self, forKey: .text))
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? .subhead
        tint = c.tint(.tint)
        symbol = try? c.decodeIfPresent(String.self, forKey: .symbol)
        align = try c.decodeIfPresent(Align.self, forKey: .align) ?? .leading
        lines = c.lineCount(.lines)
        label = c.text(.label)
        labelWidth = c.size(.labelWidth, max: 400)
        button = try? c.decodeIfPresent(HubButton.self, forKey: .button)
    }
}

public struct HubField: Sendable, Equatable, Decodable {
    public enum Keyboard: String, Sendable, Equatable, LenientEnum {
        case url, text
        public static let fallback = Keyboard.text
    }

    public enum ReturnKey: String, Sendable, Equatable, LenientEnum {
        case go, search
        public static let fallback = ReturnKey.go
    }

    public var id: String
    public var gap: Double?
    public var placeholder: String
    /// The accessibility label.
    public var label: String?
    public var value: String
    /// A line under the field with the system's Paste button.
    public var paste: Bool
    public var keyboard: Keyboard
    public var returnKey: ReturnKey
    /// Posted on return, when the text isn't blank.
    public var submit: HubAction?
    /// Posted after the clear button empties the field.
    public var clear: HubAction?
    public var button: HubButton?

    public init(
        id: String, gap: Double? = nil, placeholder: String = "", label: String? = nil, value: String = "",
        paste: Bool = false, keyboard: Keyboard = .text, returnKey: ReturnKey = .go, submit: HubAction? = nil,
        clear: HubAction? = nil, button: HubButton? = nil
    ) {
        self.id = id
        self.gap = gap
        self.placeholder = placeholder
        self.label = label
        self.value = value
        self.paste = paste
        self.keyboard = keyboard
        self.returnKey = returnKey
        self.submit = submit
        self.clear = clear
        self.button = button
    }

    private enum CodingKeys: String, CodingKey {
        case id, gap, placeholder, label, value, paste, keyboard, returnKey, submit, clear, button
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        gap = c.size(.gap, max: HubSection.maxGap)
        placeholder = c.text(.placeholder) ?? ""
        label = c.text(.label)
        value = c.text(.value) ?? ""
        paste = (try? c.decodeIfPresent(Bool.self, forKey: .paste)) ?? false
        keyboard = try c.decodeIfPresent(Keyboard.self, forKey: .keyboard) ?? .text
        returnKey = try c.decodeIfPresent(ReturnKey.self, forKey: .returnKey) ?? .go
        submit = try? c.decodeIfPresent(HubAction.self, forKey: .submit)
        clear = try? c.decodeIfPresent(HubAction.self, forKey: .clear)
        button = try? c.decodeIfPresent(HubButton.self, forKey: .button)
    }
}

public struct HubChoice: Sendable, Equatable, Decodable {
    public struct Option: Sendable, Equatable, Decodable, Identifiable {
        public var id: String
        public var label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }

        private enum CodingKeys: String, CodingKey { case id, label }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            label = clipped(try c.decode(String.self, forKey: .label))
        }
    }

    /// The most options a choice shows (a segmented control with more can't be read on a phone): the
    /// ones after it are left out.
    public static let maxOptions = 20

    public var id: String
    public var gap: Double?
    public var options: [Option]
    public var value: String
    public var action: HubAction
    public var large: Bool
    public var button: HubButton?

    public init(
        id: String, gap: Double? = nil, options: [Option], value: String, action: HubAction, large: Bool = false,
        button: HubButton? = nil
    ) {
        self.id = id
        self.gap = gap
        self.options = options
        self.value = value
        self.action = action
        self.large = large
        self.button = button
    }

    private enum CodingKeys: String, CodingKey { case id, gap, options, value, action, large, button }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        gap = c.size(.gap, max: HubSection.maxGap)
        // An option's id is what's posted back and SwiftUI's identity for it: a repeated one is dropped.
        // Options are required; those after the first `maxOptions` aren't decoded.
        var seen: Set<String> = []
        var options: [Option] = []
        var list = try c.nestedUnkeyedContainer(forKey: .options)
        while options.count < Self.maxOptions, !list.isAtEnd {
            if let option = try list.decode(Lenient<Option>.self).value, seen.insert(option.id).inserted {
                options.append(option)
            }
        }
        self.options = options
        value = (try? c.decodeIfPresent(String.self, forKey: .value)) ?? ""
        action = try c.decode(HubAction.self, forKey: .action)
        large = (try? c.decodeIfPresent(Bool.self, forKey: .large)) ?? false
        button = try? c.decodeIfPresent(HubButton.self, forKey: .button)
    }
}

public struct HubButton: Sendable, Equatable, Decodable {
    public enum Style: String, Sendable, Equatable, LenientEnum {
        case prominent, bordered, plain, pill
        public static let fallback = Style.bordered
    }

    public var id: String?
    /// Set when the button stands as a part of its own.
    public var gap: Double?
    public var label: String
    public var symbol: String?
    public var style: Style
    public var action: HubAction
    /// Field ids: disabled while any of them is blank.
    public var needs: [String]
    public var enabled: Bool
    /// The server is working on it: a spinner, disabled.
    public var busy: Bool

    public init(
        id: String? = nil, gap: Double? = nil, label: String, symbol: String? = nil, style: Style = .bordered,
        action: HubAction, needs: [String] = [], enabled: Bool = true, busy: Bool = false
    ) {
        self.id = id
        self.gap = gap
        self.label = label
        self.symbol = symbol
        self.style = style
        self.action = action
        self.needs = needs
        self.enabled = enabled
        self.busy = busy
    }

    private enum CodingKeys: String, CodingKey { case id, label, symbol, style, action, needs, enabled, busy }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        label = clipped(try c.decode(String.self, forKey: .label))
        symbol = try? c.decodeIfPresent(String.self, forKey: .symbol)
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? .bordered
        action = try c.decode(HubAction.self, forKey: .action)
        needs = (try? c.decodeIfPresent([String].self, forKey: .needs)) ?? []
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        busy = (try? c.decodeIfPresent(Bool.self, forKey: .busy)) ?? false
    }
}

public struct HubRow: Sendable, Equatable, Decodable {
    public enum NoteStyle: String, Sendable, Equatable, LenientEnum {
        case secondary, error
        public static let fallback = NoteStyle.secondary
    }

    public var id: String?
    public var gap: Double?
    public var title: String
    public var subtitle: String?
    public var lines: Int?
    /// An absolute image address.
    public var image: String?
    /// The cover's size; nil for a row with no cover.
    public var imageSize: Double?
    public var symbol: String?
    public var tint: HubTint?
    public var busy: Bool
    /// 0…1.
    public var progress: Double?
    public var note: String?
    public var noteStyle: NoteStyle
    public var noteSymbol: String?
    public var noteTint: HubTint?
    public var button: HubButton?
    public var action: HubAction?

    public init(
        id: String? = nil, gap: Double? = nil, title: String, subtitle: String? = nil, lines: Int? = nil,
        image: String? = nil, imageSize: Double? = nil, symbol: String? = nil, tint: HubTint? = nil, busy: Bool = false,
        progress: Double? = nil, note: String? = nil, noteStyle: NoteStyle = .secondary, noteSymbol: String? = nil,
        noteTint: HubTint? = nil, button: HubButton? = nil, action: HubAction? = nil
    ) {
        self.id = id
        self.gap = gap
        self.title = title
        self.subtitle = subtitle
        self.lines = lines
        self.image = image
        self.imageSize = imageSize
        self.symbol = symbol
        self.tint = tint
        self.busy = busy
        self.progress = progress
        self.note = note
        self.noteStyle = noteStyle
        self.noteSymbol = noteSymbol
        self.noteTint = noteTint
        self.button = button
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case id, gap, title, subtitle, lines, image, imageSize, symbol, tint, busy, progress, note, noteStyle
        case noteSymbol, noteTint, button, action
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        gap = c.size(.gap, max: HubSection.maxGap)
        title = clipped(try c.decode(String.self, forKey: .title))
        subtitle = c.text(.subtitle)
        lines = c.lineCount(.lines)
        image = webAddress(try? c.decodeIfPresent(String.self, forKey: .image))
        imageSize = c.size(.imageSize, max: 400).flatMap { $0 > 0 ? $0 : nil }
        symbol = try? c.decodeIfPresent(String.self, forKey: .symbol)
        tint = c.tint(.tint)
        busy = (try? c.decodeIfPresent(Bool.self, forKey: .busy)) ?? false
        progress = c.fraction(.progress)
        note = c.text(.note)
        noteStyle = try c.decodeIfPresent(NoteStyle.self, forKey: .noteStyle) ?? .secondary
        noteSymbol = try? c.decodeIfPresent(String.self, forKey: .noteSymbol)
        noteTint = c.tint(.noteTint)
        button = try? c.decodeIfPresent(HubButton.self, forKey: .button)
        action = try? c.decodeIfPresent(HubAction.self, forKey: .action)
    }
}

public struct HubProgress: Sendable, Equatable, Decodable {
    public var id: String?
    public var gap: Double?
    /// With a label, a bar; without one, a large spinner.
    public var label: String?
    /// 0…1; nil for the moving bar.
    public var value: Double?

    public init(id: String? = nil, gap: Double? = nil, label: String? = nil, value: Double? = nil) {
        self.id = id
        self.gap = gap
        self.label = label
        self.value = value
    }

    private enum CodingKeys: String, CodingKey { case id, gap, label, value }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        gap = c.size(.gap, max: HubSection.maxGap)
        label = c.text(.label)
        value = c.fraction(.value)
    }
}

public struct HubImage: Sendable, Equatable, Decodable {
    public var id: String?
    public var gap: Double?
    public var url: String?
    /// Width ÷ height.
    public var aspect: Double
    public var button: HubButton?

    public init(id: String? = nil, gap: Double? = nil, url: String? = nil, aspect: Double = 16 / 9, button: HubButton? = nil) {
        self.id = id
        self.gap = gap
        self.url = url
        self.aspect = aspect
        self.button = button
    }

    private enum CodingKeys: String, CodingKey { case id, gap, url, aspect, button }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        gap = c.size(.gap, max: HubSection.maxGap)
        url = webAddress(try? c.decodeIfPresent(String.self, forKey: .url))
        let aspect = (try? c.decodeIfPresent(Double.self, forKey: .aspect)) ?? 16 / 9
        self.aspect = aspect.isFinite && aspect > 0 ? min(max(aspect, 0.1), 10) : 16 / 9
        button = try? c.decodeIfPresent(HubButton.self, forKey: .button)
    }
}

// MARK: - Actions and replies

public struct HubAction: Sendable, Equatable, Decodable {
    public var id: String
    /// The fields and choices whose values go with it.
    public var sends: [String]

    public init(id: String, sends: [String] = []) {
        self.id = id
        self.sends = sends
    }

    private enum CodingKeys: String, CodingKey { case id, sends }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sends = (try? c.decodeIfPresent([String].self, forKey: .sends)) ?? []
    }
}

/// What a posted action sends: `{"screen", "action", "values"}`.
public struct HubRequest: Sendable, Equatable, Encodable {
    public var screen: String
    public var action: String
    public var values: [String: String]

    public init(screen: String, action: String, values: [String: String] = [:]) {
        self.screen = screen
        self.action = action
        self.values = values
    }
}

public struct HubReply: Sendable, Equatable, Decodable {
    public enum Present: String, Sendable, Equatable, LenientEnum {
        case replace, push, sheet, dismiss, none
        public static let fallback = Present.none
    }

    public var present: Present
    public var screen: HubScreen?
    public var toast: String?

    public init(present: Present, screen: HubScreen? = nil, toast: String? = nil) {
        self.present = present
        self.screen = screen
        self.toast = toast
    }

    private enum CodingKeys: String, CodingKey { case present, screen, toast }

    /// A screen that can't be read (another version) fails the whole reply.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        present = try c.decodeIfPresent(Present.self, forKey: .present) ?? .none
        screen = try c.decodeIfPresent(HubScreen.self, forKey: .screen)
        toast = c.text(.toast)
    }
}

// MARK: - Leniency

/// A string enum whose unknown values decode as `fallback`.
public protocol LenientEnum: RawRepresentable<String>, Decodable {
    static var fallback: Self { get }
}

extension LenientEnum {
    public init(from decoder: any Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(Self.init(rawValue:)) ?? Self.fallback
    }
}

/// An array element that decodes as nil instead of failing the array.
private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// An image address the app will load: http or https only (not `file:` or anything else).
private func webAddress(_ string: String?) -> String? {
    guard let string, let scheme = URL(string: string)?.scheme?.lowercased(), scheme == "http" || scheme == "https"
    else { return nil }
    return string
}

/// A text cut to `HubScreen.maxTextLength` Unicode scalars (not characters: one character can hold any
/// number of combining marks).
func clipped(_ text: String) -> String {
    let scalars = text.unicodeScalars
    guard let end = scalars.index(scalars.startIndex, offsetBy: HubScreen.maxTextLength, limitedBy: scalars.endIndex),
          end != scalars.endIndex else { return text }
    return String(scalars[..<end])
}

extension KeyedDecodingContainer {
    /// A text to draw, cut to `HubScreen.maxTextLength`; nil when absent or not text.
    fileprivate func text(_ key: Key) -> String? {
        (try? decodeIfPresent(String.self, forKey: key)).flatMap { $0 }.map(clipped)
    }

    /// The list at `key`, to read one element at a time; nil when absent or null.
    fileprivate func list(forKey key: Key) throws -> UnkeyedDecodingContainer? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try nestedUnkeyedContainer(forKey: key)
    }

    /// A fraction: a finite number brought into 0…1; nil when absent or not a number.
    fileprivate func fraction(_ key: Key) -> Double? {
        guard let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }

    /// A size, gap or width: a finite number within 0…`max`, nil when absent or not a number.
    fileprivate func size(_ key: Key, max upper: Double) -> Double? {
        guard let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite else { return nil }
        return min(max(value, 0), upper)
    }

    /// A line limit: 1…100, nil when absent or not positive.
    fileprivate func lineCount(_ key: Key) -> Int? {
        guard let value = try? decodeIfPresent(Int.self, forKey: key), value > 0 else { return nil }
        return min(value, 100)
    }

    /// A tint, or nil when absent or unknown.
    fileprivate func tint(_ key: Key) -> HubTint? {
        (try? decodeIfPresent(String.self, forKey: key)).flatMap { $0 }.flatMap(HubTint.init(rawValue:))
    }
}

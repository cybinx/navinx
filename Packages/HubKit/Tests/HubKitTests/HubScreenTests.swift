import Foundation
import Testing
@testable import HubKit

/// The schema v1's decoding, on the server's own samples (`Server/panel/tests/fixtures/screens/`,
/// neutral texts), copied here as they are.
struct HubScreenTests {
    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static let screens = [
        "main-find-albums", "main-find-artists", "main-find-empty", "main-find-error", "main-find-loading",
        "main-find-noroot", "main-find-nothing", "main-find-requesting", "main-find-rescanned", "main-find-searching",
        "main-paste-done", "main-paste-exists", "main-paste-failed", "main-paste-idle", "main-paste-job",
        "main-paste-preview", "main-paste-starting", "search-empty", "search-nothing", "search-rescan", "search-results",
    ]

    static let replies = ["reply-checking", "reply-dismiss", "reply-search-loading", "reply-search-rescanned", "reply-sheet"]

    /// Every part in the sample, as the raw JSON has it, so a part the decoder dropped shows up.
    private func rawPartCount(_ data: Data) throws -> Int {
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let screen = (json["screen"] as? [String: Any]) ?? json
        let sections = screen["sections"] as? [[String: Any]] ?? []
        return sections.reduce(0) { $0 + (($1["parts"] as? [Any])?.count ?? 0) }
    }

    @Test(arguments: screens)
    func everyScreenDecodesWhole(_ name: String) throws {
        let data = try Self.fixture(name)
        let screen = try JSONDecoder().decode(HubScreen.self, from: data)
        #expect(!screen.id.isEmpty)
        #expect(screen.sections.flatMap(\.parts).count == (try rawPartCount(data)), "a known part was dropped")
        if name.hasPrefix("main") {
            #expect(screen.tab != nil, "the root screen carries the tab")
        } else {
            #expect(screen.tab == nil)
        }
    }

    @Test(arguments: replies)
    func everyReplyDecodes(_ name: String) throws {
        let data = try Self.fixture(name)
        let reply = try JSONDecoder().decode(HubReply.self, from: data)
        let screen = try #require(reply.screen)
        #expect(screen.sections.flatMap(\.parts).count == (try rawPartCount(data)))
    }

    @Test func thePreviewReadsAsSent() throws {
        let screen = try JSONDecoder().decode(HubScreen.self, from: try Self.fixture("main-paste-preview"))
        #expect(screen.id == "main")
        #expect(screen.tab == HubTab(title: "Add", symbol: "dot.radiowaves.left.and.right"))
        #expect(screen.refresh == nil)
        #expect(screen.sections.map(\.id) == ["mode", "link", "thumbnail", "preview", "rescan"])
        #expect(screen.sections.map(\.card) == [.none, .glass, .none, .glass, .glass])
        #expect(screen.sections[3].gap == 10)

        guard case .choice(let mode) = screen.sections[0].parts[0] else { Issue.record("no choice"); return }
        #expect(mode.large && mode.value == "paste" && mode.options.map(\.id) == ["paste", "find"])
        #expect(mode.action == HubAction(id: "mode", sends: ["mode"]))

        guard case .field(let link) = screen.sections[1].parts[0] else { Issue.record("no field"); return }
        #expect(link.paste && link.keyboard == .url && link.returnKey == .go)
        #expect(link.value == "https://example.com/watch?v=one")
        #expect(link.button?.needs == ["link"] && link.button?.style == .prominent)

        guard case .image(let image) = screen.sections[2].parts[0] else { Issue.record("no image"); return }
        #expect(abs(image.aspect - 16.0 / 9.0) < 0.0001)
        #expect(image.button?.style == .pill && image.button?.id == "add")

        let preview = screen.sections[3].parts
        guard case .text(let title) = preview[0], case .text(let artist) = preview[2], case .button(let cancel) = preview[5]
        else { Issue.record("preview parts"); return }
        #expect(title.style == .headline && title.lines == 2)
        #expect(artist.label == "Artist" && artist.style == .strong && artist.gap == 14)
        #expect(cancel.style == .plain && cancel.gap == 14, "a button part keeps its gap")
    }

    @Test func requestsAndTheSheet() throws {
        let screen = try JSONDecoder().decode(HubScreen.self, from: try Self.fixture("main-find-albums"))
        let requests = try #require(screen.sections.first { $0.id == "requests" })
        #expect(requests.title == "Requests" && requests.button?.symbol == "arrow.clockwise" && requests.gap == 28)
        let rows = requests.parts.compactMap { if case .row(let row) = $0 { row } else { nil } }
        let downloading = try #require(rows.first { $0.progress != nil })
        #expect(downloading.progress == 0.5 && downloading.tint == .accent && downloading.imageSize == 52)
        #expect(downloading.action?.id.hasPrefix("open:") == true)

        let reply = try JSONDecoder().decode(HubReply.self, from: try Self.fixture("reply-sheet"))
        #expect(reply.present == .sheet)
        let sheet = try #require(reply.screen)
        #expect(sheet.sheetHeight == 300 && sheet.title.isEmpty)
        guard case .row(let header) = sheet.sections[0].parts[0] else { Issue.record("no header"); return }
        #expect(header.imageSize == 72 && header.noteSymbol == "xmark.circle.fill" && header.noteTint == .red)
        guard case .text(let line) = sheet.sections[0].parts[1] else { Issue.record("no line"); return }
        #expect(line.labelWidth == 112)
    }

    /// The demo server's tab (D182): device management on sample devices, and Approve's reply.
    @Test func theDemoServersTabDecodesWhole() throws {
        let data = try Self.fixture("main-demo-devices")
        let screen = try JSONDecoder().decode(HubScreen.self, from: data)
        #expect(screen.tab == HubTab(title: "Devices", symbol: "iphone") && screen.refresh == 10)
        #expect(screen.sections.flatMap(\.parts).count == (try rawPartCount(data)), "a known part was dropped")
        #expect(screen.sections.first?.id == "demo" && screen.sections.last?.id == "reset")
        guard case .text(let note) = screen.sections[0].parts[0] else { Issue.record("no note"); return }
        #expect(note.text.hasPrefix("Sample devices."))

        let replyData = try Self.fixture("reply-demo-approve")
        let reply = try JSONDecoder().decode(HubReply.self, from: replyData)
        #expect(reply.present == .replace && reply.toast == "Approved Alex's iPhone.")
        let after = try #require(reply.screen)
        #expect(after.tab == screen.tab, "a reply for the tab's root keeps the tab")
        #expect(after.sections.flatMap(\.parts).count == (try rawPartCount(replyData)))
    }

    @Test func unknownPartsAndValuesAreSkippedOrDefaulted() throws {
        let screen = try JSONDecoder().decode(HubScreen.self, from: try Self.fixture("unknown-part"))
        #expect(screen.tab?.symbol == "no.such.symbol", "the app falls back when drawing it")
        #expect(screen.sections.count == 2)
        let parts = screen.sections[0].parts
        #expect(parts.map(\.id) == ["kept", "go", "r"], "the chart is skipped")
        guard case .text(let text) = parts[0], case .button(let button) = parts[1] else { Issue.record("parts"); return }
        #expect(text.tint == nil, "an unknown tint is none")
        #expect(button.style == .bordered, "an unknown style is bordered")
        #expect(screen.sections[1].card == .glass, "an unknown card is glass")
    }

    @Test func numbersImagesAndIdsAreMadeSafeWhenDecoded() throws {
        let json = #"""
        {"v": 1, "id": "main", "refresh": 99999999999, "sheetHeight": 1e300, "sections": [
          {"id": "a", "gap": 1e300, "parts": [
            {"type": "row", "title": "R", "image": "file:///private/secret.png", "imageSize": 1e300, "lines": -3, "gap": -5},
            {"type": "row", "title": "S", "image": "https://images.example/x.png", "imageSize": 52},
            {"type": "image", "url": "file:///etc/hosts", "aspect": 1e300},
            {"type": "image", "url": "HTTP://images.example/y.png", "aspect": 0},
            {"type": "text", "text": "T", "labelWidth": 1e300, "lines": 1000}
          ]},
          {"id": "a", "parts": [
            {"type": "choice", "id": "c", "value": "x", "action": {"id": "go"},
             "options": [{"id": "x", "label": "X"}, {"id": "x", "label": "Again"}, {"id": "y", "label": "Y"}]}
          ]},
          {"id": "a", "parts": []}
        ]}
        """#
        let screen = try JSONDecoder().decode(HubScreen.self, from: Data(json.utf8))
        #expect(screen.refresh == 86_400 && screen.sheetHeight == 3000)
        #expect(screen.sections.map(\.id) == ["a", "a-2", "a-3"], "a repeated section id gets a suffix")
        #expect(screen.sections[0].gap == 200)
        let parts = screen.sections[0].parts
        guard case .row(let first) = parts[0], case .row(let second) = parts[1],
              case .image(let file) = parts[2], case .image(let web) = parts[3], case .text(let text) = parts[4]
        else { Issue.record("parts"); return }
        #expect(first.image == nil && first.imageSize == 400 && first.lines == nil && first.gap == 0)
        #expect(second.image == "https://images.example/x.png" && second.imageSize == 52)
        #expect(file.url == nil && file.aspect == 10)
        #expect(web.url == "HTTP://images.example/y.png" && abs(web.aspect - 16.0 / 9.0) < 0.0001)
        #expect(text.labelWidth == 400 && text.lines == 100)
        guard case .choice(let choice) = screen.sections[1].parts[0] else { Issue.record("no choice"); return }
        #expect(choice.options.map(\.id) == ["x", "y"], "a repeated option is dropped; the ids posted stay as sent")
    }

    @Test func aTitleThatIsntTextIsNoTitle() throws {
        let screen = try JSONDecoder().decode(HubScreen.self, from: Data(#"{"v": 1, "id": "main", "title": 7, "sections": []}"#.utf8))
        #expect(screen.id == "main" && screen.title.isEmpty)
    }

    @Test func aScreenDrawsNoMoreThanItsCap() throws {
        let row = #"{"type": "row", "title": "R"}"#
        let full = "[" + Array(repeating: row, count: 300).joined(separator: ",") + "]"
        let sections = (0..<150).map { #"{"id": "s\#($0)", "parts": \#($0 < 2 ? full : "[]")}"# }
        let json = #"{"v": 1, "id": "main", "sections": [\#(sections.joined(separator: ","))]}"#
        let screen = try JSONDecoder().decode(HubScreen.self, from: Data(json.utf8))
        #expect(screen.sections.flatMap(\.parts).count == HubScreen.maxParts)
        #expect(screen.sections.map(\.parts.count) == [300, 200], "the sections after the last part go too")
        let empty = (0..<150).map { #"{"id": "e\#($0)", "title": "T"}"# }
        let titles = try JSONDecoder().decode(
            HubScreen.self, from: Data(#"{"v": 1, "id": "main", "sections": [\#(empty.joined(separator: ","))]}"#.utf8)
        )
        #expect(titles.sections.count == HubScreen.maxSections)
    }

    // MARK: The audit's bounds (T1, T11)

    @Test func longTextsAreCut() throws {
        let long = String(repeating: "a", count: HubScreen.maxTextLength + 5)
        // One character carrying thousands of marks is cut by its scalars.
        let marks = "e" + String(repeating: "\u{301}", count: 20_000)
        let id = String(repeating: "i", count: HubScreen.maxTextLength + 5)
        let json = #"""
        {"v": 1, "id": "\#(id)", "title": "\#(long)", "tab": {"title": "\#(long)", "symbol": "star"}, "sections": [
          {"id": "s", "title": "\#(marks)", "parts": [
            {"type": "text", "text": "\#(long)", "label": "\#(long)"},
            {"type": "field", "id": "f", "value": "\#(long)", "placeholder": "\#(long)"},
            {"type": "choice", "id": "c", "value": "x", "action": {"id": "go"}, "options": [{"id": "x", "label": "\#(long)"}]},
            {"type": "button", "label": "\#(long)", "action": {"id": "go"}},
            {"type": "row", "title": "\#(long)", "subtitle": "\#(long)", "note": "\#(long)"},
            {"type": "progress", "label": "\#(long)"}
          ]}
        ]}
        """#
        let screen = try JSONDecoder().decode(HubScreen.self, from: Data(json.utf8))
        let max = HubScreen.maxTextLength
        #expect(screen.id == id, "ids are posted back as sent")
        #expect(screen.title.count == max && screen.tab?.title.count == max)
        #expect(screen.sections[0].title?.unicodeScalars.count == max)
        let parts = screen.sections[0].parts
        guard case .text(let text) = parts[0], case .field(let field) = parts[1], case .choice(let choice) = parts[2],
              case .button(let button) = parts[3], case .row(let row) = parts[4], case .progress(let progress) = parts[5]
        else { Issue.record("parts"); return }
        let texts = [text.text, text.label, field.value, field.placeholder, choice.options.first?.label, button.label,
                     row.title, row.subtitle, row.note, progress.label]
        #expect(texts.allSatisfy { $0?.count == max })
        let reply = try JSONDecoder().decode(HubReply.self, from: Data(#"{"present": "none", "toast": "\#(long)"}"#.utf8))
        #expect(reply.toast?.count == max)
    }

    @Test func aChoiceShowsAtMostItsOptions() throws {
        let options = (0..<60).map { #"{"id": "o\#($0 / 2)", "label": "O"}"# }.joined(separator: ",")
        let json = #"{"type": "choice", "id": "c", "value": "o0", "action": {"id": "go"}, "options": [\#(options)]}"#
        let choice = try JSONDecoder().decode(HubChoice.self, from: Data(json.utf8))
        #expect(choice.options.map(\.id) == (0..<HubChoice.maxOptions).map { "o\($0)" }, "repeats don't count")
    }

    @Test func aScreenLoadsAtMostItsPictures() throws {
        let row = #"{"type": "row", "title": "R", "image": "https://images.example/r.png", "imageSize": 52}"#
        let image = #"{"type": "image", "url": "https://images.example/i.png"}"#
        let parts = Array(repeating: row, count: 150) + Array(repeating: image, count: 100)
        let json = #"{"v": 1, "id": "main", "sections": [{"id": "a", "parts": [\#(parts.joined(separator: ","))]}]}"#
        let screen = try JSONDecoder().decode(HubScreen.self, from: Data(json.utf8))
        let loaded = screen.sections[0].parts.filter {
            switch $0 {
            case .row(let row): row.image != nil
            case .image(let image): image.url != nil
            default: false
            }
        }
        #expect(screen.sections[0].parts.count == 250, "the parts stay, with the placeholder")
        #expect(loaded.count == HubScreen.maxPictures)
        guard case .image(let last) = screen.sections[0].parts[249], case .row(let first) = screen.sections[0].parts[0]
        else { Issue.record("parts"); return }
        #expect(last.url == nil && first.image != nil)
    }

    @Test func numbersThatArentFiniteAreNone() throws {
        let json = #"""
        {"v": 1, "id": "main", "sheetHeight": 1e400, "sections": [{"id": "a", "gap": -1e400, "parts": [
          {"type": "progress", "label": "L", "value": 1e400},
          {"type": "row", "title": "R", "progress": -1e400, "imageSize": 1e400},
          {"type": "image", "url": "https://images.example/i.png", "aspect": 1e400}
        ]}]}
        """#
        let screen = try JSONDecoder().decode(HubScreen.self, from: Data(json.utf8))
        #expect(screen.sheetHeight == nil && screen.sections[0].gap == nil)
        guard case .progress(let progress) = screen.sections[0].parts[0], case .row(let row) = screen.sections[0].parts[1],
              case .image(let image) = screen.sections[0].parts[2]
        else { Issue.record("parts"); return }
        #expect(progress.value == nil && row.progress == nil && row.imageSize == nil)
        #expect(image.aspect.isFinite)
    }

    @Test func anotherVersionIsRefused() throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(HubScreen.self, from: try Self.fixture("v2"))
        }
        let reply = Data(#"{"present": "replace", "screen": {"v": 2, "id": "main", "title": "", "sections": []}}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(HubReply.self, from: reply) }
    }

    @Test func anUnknownPresentationIsNone() throws {
        let reply = try JSONDecoder().decode(HubReply.self, from: Data(#"{"present": "fly", "toast": "Hi"}"#.utf8))
        #expect(reply.present == .none && reply.toast == "Hi" && reply.screen == nil)
    }

    @Test func theRequestEncodesAsTheServerReadsIt() throws {
        let data = try JSONEncoder().encode(HubRequest(screen: "main", action: "check", values: ["link": "x"]))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["screen"] as? String == "main")
        #expect(json["action"] as? String == "check")
        #expect(json["values"] as? [String: String] == ["link": "x"])
    }
}

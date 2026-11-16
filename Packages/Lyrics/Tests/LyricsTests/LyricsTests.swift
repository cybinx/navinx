import Foundation
import Synchronization
import SubsonicKit
import Testing
@testable import Lyrics

@Suite struct TimedLyricsReaderTests {
    @Test func readsEveryFractionLength() {
        let lines = TimedLyricsReader.parse("[00:01]a\n[00:02.5]b\n[00:03.25]c\n[01:04.125]d\n[00:05:50]e")
        #expect(lines.map(\.text) == ["a", "b", "c", "e", "d"])
        #expect(lines.map(\.start) == [1, 2.5, 3.25, 5.5, 64.125])
    }

    @Test func aLineWithSeveralTagsComesOnceForEach() {
        let lines = TimedLyricsReader.parse("[00:10.00][00:20.00]chorus\n[00:15.00]verse")
        #expect(lines.map(\.text) == ["chorus", "verse", "chorus"])
        #expect(lines.map(\.start) == [10, 15, 20])
    }

    @Test func eachLineEndsAMillisecondBeforeTheNext() throws {
        let lines = TimedLyricsReader.parse("[00:01.00]a\n[00:03.00]b")
        #expect(try #require(lines[0].end).isApproximately(2.999))
        #expect(lines[1].end == nil)
    }

    @Test func plainLyricsKeepNoTagsAndNoByteOrderMark() {
        let lines = TimedLyricsReader.parse("\u{FEFF}[ar:Someone]\n[ti:Song]\n[offset:+200]\nfirst\n[Chorus]\nsecond")
        #expect(lines.map(\.text) == ["first", "[Chorus]", "second"])
        #expect(TimedLyricsReader.parse("\u{FEFF}[00:01.00]a").map(\.text) == ["a"])
    }

    @Test func readsHoursAndLongFractions() {
        let lines = TimedLyricsReader.parse("[1:02:03.50]b\n[00:01.2500]a\n[00:05:50]c")
        #expect(lines.map(\.text) == ["a", "c", "b"])
        #expect(lines.map(\.start) == [1.25, 5.5, 3723.5])
    }

    @Test func anOffsetKeepsTheOrderAndSpacingOfEarlyLines() {
        // Taking 5 s off would put three lines before 0; the shift stops at the first one instead.
        let lines = TimedLyricsReader.parse("[offset:5000]\n[00:01.00]a\n[00:02.00]b\n[00:04.00]c\n[00:30.00]d")
        #expect(lines.map(\.start) == [0, 1, 3, 29])
    }

    @Test func skipsMetadataAndEmptyTimedLines() {
        let lines = TimedLyricsReader.parse("[ar:Someone]\n[ti:Song]\n[00:01.00]\n[00:02.00]sung\nnot timed")
        #expect(lines.map(\.text) == ["sung"])
    }

    @Test func textWithNoTimingsIsPlainLyrics() {
        let lines = TimedLyricsReader.parse("first\n\n  second  \n")
        #expect(lines == [LyricLine(text: "first", start: 0), LyricLine(text: "second", start: 0)])
    }

    @Test func nothingFromNothing() {
        #expect(TimedLyricsReader.parse("  \n").isEmpty)
    }

    @Test func aPositiveOffsetShowsTheLyricsSooner() {
        let lines = TimedLyricsReader.parse("[offset:+500]\n[00:01.00]a\n[00:03.00]b")
        #expect(lines.map(\.text) == ["a", "b"])
        #expect(lines.map(\.start) == [0.5, 2.5])
        let later = TimedLyricsReader.parse("[Offset: -1000]\n[00:01.00]a")
        #expect(later.map(\.start) == [2])
    }

    @Test func anOffsetNeverGoesBeforeTheStart() {
        #expect(TimedLyricsReader.parse("[offset:5000]\n[00:01.00]a").map(\.start) == [0])
    }

    @Test func wordTimesAreTakenOutOfTheText() {
        let lines = TimedLyricsReader.parse("[00:01.00]<00:01.00>Hello <00:01.50>world\n[00:03.00]<00:03.00>")
        #expect(lines.map(\.text) == ["Hello world"])
    }

    @Test func readsWindowsLineEndings() {
        #expect(TimedLyricsReader.parse("[00:01.00]a\r\n[00:02.00]b\r\n").map(\.text) == ["a", "b"])
    }
}

@Suite struct StructuredLyricsTests {
    @Test func sortsDropsBlanksAndChains() throws {
        let lines = LyricLine.lines(from: StructuredLyrics(synced: true, lines: [
            .init(start: 4000, value: "b"),
            .init(start: 1000, value: "a"),
            .init(start: 2000, value: "   "),
        ]))
        #expect(lines.map(\.text) == ["a", "b"])
        #expect(lines[0].start == 1)
        #expect(try #require(lines[0].end).isApproximately(3.999))
    }

    @Test func theServersOffsetIsAdded() {
        let lines = LyricLine.lines(from: StructuredLyrics(offset: 500, synced: true, lines: [
            .init(start: 1000, value: "a"), .init(start: 2000, value: "b"),
        ]))
        #expect(lines.map(\.start) == [1.5, 2.5])
        let earlier = LyricLine.lines(from: StructuredLyrics(offset: -3000, synced: true, lines: [
            .init(start: 1000, value: "a"), .init(start: 4000, value: "b"),
        ]))
        #expect(earlier.map(\.start) == [0, 3], "never before 0, and the spacing stays")
    }

    @Test func unsyncedKeepsItsOrder() {
        let values = (0..<50).map { "line \($0)" }
        let lines = LyricLine.lines(from: StructuredLyrics(synced: false, lines: values.map { .init(start: nil, value: $0) }))
        #expect(lines.map(\.text) == values)
        #expect(lines.allSatisfy { $0.start == 0 })
    }
}

@Suite struct LyricsTimelineTests {
    private func kinds(_ timeline: LyricsTimeline) -> [String] {
        timeline.items.map {
            if case .line(let line, _) = $0.kind { line.text } else { "…" }
        }
    }

    @Test func dotsBeforeALateFirstLineOnly() {
        #expect(kinds(LyricsTimeline(lines: [LyricLine(text: "a", start: 10.5)])) == ["…", "a"])
        #expect(kinds(LyricsTimeline(lines: [LyricLine(text: "a", start: 10)])) == ["a"])
    }

    @Test func aLineWithNoEndLastsFiveSecondsAtMost() {
        let timeline = LyricsTimeline(lines: [LyricLine(text: "a", start: 0), LyricLine(text: "b", start: 3), LyricLine(text: "c", start: 30)])
        #expect(timeline.items[0].end == 3)
        #expect(timeline.items[1].end == 8)
    }

    @Test func dotsInALongGapEvenWithChainedEnds() {
        let unchained = LyricsTimeline(lines: [LyricLine(text: "a", start: 1), LyricLine(text: "b", start: 30)])
        #expect(kinds(unchained) == ["a", "…", "b"])
        let chained = LyricsTimeline(lines: TimedLyricsReader.parse("[00:01.00]a\n[00:30.00]b"))
        #expect(kinds(chained) == ["a", "…", "b"], "a line lasts 5 s, then the dots wait for the next")
        #expect(chained.items[1].start == 6 && chained.items[1].end == 30)
        // 5 s of the line and 10 of dots is the least that shows them.
        #expect(kinds(LyricsTimeline(lines: TimedLyricsReader.parse("[00:01.00]a\n[00:16.00]b"))) == ["a", "b"])
        #expect(kinds(LyricsTimeline(lines: TimedLyricsReader.parse("[00:01.00]a\n[00:17.00]b"))) == ["a", "…", "b"])
    }

    @Test func aLineStaysCurrentThroughTheGapToTheNext() {
        let timeline = LyricsTimeline(lines: TimedLyricsReader.parse("[00:01.00]a\n[00:03.00]b\n[00:12.00]c"))
        #expect(timeline.moment(at: 2.9995).line == 0, "the millisecond between a line and the next isn't a gap")
        #expect(timeline.moment(at: 3).line == 1)
        #expect(timeline.moment(at: 9).line == 1, "past its 5 s, with no dots yet")
        let dots = LyricsTimeline(lines: TimedLyricsReader.parse("[00:01.00]a\n[00:30.00]b"))
        #expect(dots.moment(at: 10) == .init(item: 1, line: nil), "the dots are current in a long gap")
        #expect(dots.moment(at: 29.9995).line == nil)
        #expect(dots.moment(at: 30).line == 1)
    }

    @Test func followsTheSong() {
        let timeline = LyricsTimeline(lines: TimedLyricsReader.parse("[00:20.00]a\n[00:25.00]b"))
        #expect(timeline.moment(at: 5) == .init(item: 0, line: nil))
        #expect(timeline.moment(at: 20) == .init(item: 1, line: 0))
        #expect(timeline.moment(at: 25) == .init(item: 2, line: 1))
        #expect(timeline.moment(at: 500) == .init(item: 2, line: 1))
    }

    @Test func aLaterFirstLineWaitsOnIt() {
        let timeline = LyricsTimeline(lines: TimedLyricsReader.parse("[00:05.00]a\n[00:08.00]b"))
        #expect(timeline.moment(at: 1) == .init(item: 0, line: 0))
    }

    @Test func unsyncedHasNoCurrentLine() {
        let timeline = LyricsTimeline(lines: TimedLyricsReader.parse("a\nb\nc"))
        #expect(timeline.isUnsynced)
        #expect(timeline.moment(at: 3) == .init(item: nil, line: nil))
    }

    @Test func oneLineWithNoTimeIsUnsynced() {
        let timeline = LyricsTimeline(lines: TimedLyricsReader.parse("only"))
        #expect(timeline.isUnsynced)
        #expect(timeline.moment(at: 3) == .init(item: nil, line: nil))
        #expect(!LyricsTimeline(lines: TimedLyricsReader.parse("[00:04.00]only")).isUnsynced)
    }

    @Test func statesAroundTheCurrentLine() {
        let timeline = LyricsTimeline(lines: TimedLyricsReader.parse("[00:01.00]a\n[00:02.00]b\n[00:03.00]c"))
        let moment = timeline.moment(at: 2.5)
        #expect(timeline.state(ofLine: 0, item: timeline.items[0], at: moment, time: 2.5) == .past)
        #expect(timeline.state(ofLine: 1, item: timeline.items[1], at: moment, time: 2.5) == .current)
        #expect(timeline.state(ofLine: 2, item: timeline.items[2], at: moment, time: 2.5) == .future)
        #expect(timeline.distance(ofLine: 2, at: moment) == 1)
    }

    @Test func unsyncedLinesAreNeverDimmedAsPast() {
        let timeline = LyricsTimeline(lines: TimedLyricsReader.parse("a\nb"))
        for time in [1.0, 6.0, 200.0] {
            let moment = timeline.moment(at: time)
            #expect(timeline.state(ofLine: 0, item: timeline.items[0], at: moment, time: time) != .past)
            #expect(timeline.state(ofLine: 1, item: timeline.items[1], at: moment, time: time) != .past)
        }
    }

    @Test func theLivePillHasNothingForUnsyncedLyrics() {
        #expect(LyricsTimeline.activeLine(in: TimedLyricsReader.parse("a\nb\nc"), at: 30) == nil)
        let synced = TimedLyricsReader.parse("[00:01.00]a\n[00:05.00]b")
        #expect(LyricsTimeline.activeLine(in: synced, at: 0.5) == nil)
        #expect(LyricsTimeline.activeLine(in: synced, at: 2)?.text == "a")
        #expect(LyricsTimeline.activeLine(in: synced, at: 99)?.text == "b")
    }

    @Test func dotsGoOneASecond() {
        #expect(LyricsTimeline.visibleDots(timeLeft: 3.5) == 3)
        #expect(LyricsTimeline.visibleDots(timeLeft: 2.5) == 2)
        #expect(LyricsTimeline.visibleDots(timeLeft: 1.5) == 1)
        #expect(LyricsTimeline.visibleDots(timeLeft: 0.5) == 0)
        #expect(LyricsTimeline.visibleDots(timeLeft: -4) == 0)
    }
}

/// Answers from a table of path → JSON, recording what was asked.
private final class FakeTransport: HTTPTransport {
    private let answers: [String: String]
    private let log = Mutex<[URL]>([])

    init(_ answers: [String: String]) { self.answers = answers }

    var requests: [URL] { log.withLock { $0 } }

    func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        log.withLock { $0.append(url) }
        let key = answers.keys.first { url.absoluteString.contains($0) }
        let response = HTTPURLResponse(url: url, statusCode: key == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        return (Data((key.flatMap { answers[$0] } ?? "{}").utf8), response)
    }
}

@Suite struct LyricsLoaderTests {
    private func wrap(_ payload: String) -> String {
        #"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(payload)}}"#
    }

    private func loader(_ answers: [String: String]) throws -> (LyricsLoader, FakeTransport) {
        let transport = FakeTransport(answers)
        let config = ServerConfig(serverURL: "http://server.invalid:4533", username: "u", password: "p")
        let client = try SubsonicClient(config: config, coverArtSalt: "salt", transport: transport)
        return (LyricsLoader(client: client), transport)
    }

    @Test func serverStructuredLyricsFirst() async throws {
        let (loader, transport) = try loader([
            "getLyricsBySongId": wrap(#""lyricsList":{"structuredLyrics":[{"synced":true,"line":[{"start":1000,"value":"sung"}]}]}"#),
        ])
        let lines = await loader.lines(songID: "1", artist: "A", title: "B")
        #expect(lines.map(\.text) == ["sung"])
        #expect(transport.requests.count == 1)
    }

    @Test func navidromesEmptyAnswerMovesOn() async throws {
        let (loader, _) = try loader([
            "getLyricsBySongId": wrap(#""lyricsList":{}"#),
            "getLyrics?": wrap(#""lyrics":{"artist":"A","title":"B","value":"[00:01.00]plain"}"#),
        ])
        let lines = await loader.lines(songID: "1", artist: "A", title: "B")
        #expect(lines == [LyricLine(text: "plain", start: 1)])
    }

    @Test func theFirstSyncedEntryWins() async throws {
        let (timedFirst, _) = try loader([
            "getLyricsBySongId": wrap(#""lyricsList":{"structuredLyrics":[{"synced":false,"line":[{"value":"plain"}]},{"synced":true,"line":[]},{"synced":true,"line":[{"start":1000,"value":"timed"}]}]}"#),
        ])
        #expect(await timedFirst.lines(songID: "1", artist: "A", title: "B").map(\.text) == ["timed"])
        let (plainOnly, _) = try loader([
            "getLyricsBySongId": wrap(#""lyricsList":{"structuredLyrics":[{"synced":true,"line":[]},{"synced":false,"line":[{"value":"plain"}]}]}"#),
        ])
        #expect(await plainOnly.lines(songID: "1", artist: "A", title: "B").map(\.text) == ["plain"])
    }

    @Test func onlyTheServerIsAsked() async throws {
        // D199: when the server has none, nothing is looked up anywhere else.
        let (loader, transport) = try loader([
            "getLyricsBySongId": wrap(#""lyricsList":{}"#),
            "getLyrics?": wrap(#""lyrics":{"value":""}"#),
        ])
        #expect(await loader.lines(songID: "1", artist: "A", title: "B").isEmpty)
        #expect(transport.requests.count == 2)
        #expect(transport.requests.allSatisfy { $0.host() == "server.invalid" })
    }

    @Test func nothingAnywhereIsNoLines() async throws {
        let (loader, _) = try loader([:])
        #expect(await loader.lines(songID: "1", artist: "A", title: "B").isEmpty)
    }

    // MARK: A downloaded song's saved lyrics (C10)

    private let structured = [
        "getLyricsBySongId": #"{"subsonic-response":{"status":"ok","version":"1.16.1","lyricsList":{"structuredLyrics":[{"synced":true,"line":[{"start":1000,"value":"from the server"}]}]}}}"#,
    ]

    private func client(_ transport: FakeTransport) throws -> SubsonicClient {
        try SubsonicClient(
            config: ServerConfig(serverURL: "http://server.invalid:4533", username: "u", password: "p"),
            coverArtSalt: "salt",
            transport: transport
        )
    }

    @Test func savedLyricsComeFirstAndAskNobody() async throws {
        let transport = FakeTransport(structured)
        let loader = LyricsLoader(client: try client(transport), saved: { id in
            id == "1" ? [LyricLine(text: "saved", start: 3)] : nil
        })
        #expect(await loader.lines(songID: "1", artist: "A", title: "B") == [LyricLine(text: "saved", start: 3)])
        #expect(transport.requests.isEmpty)
    }

    @Test func emptySavedLyricsGoOnToTheServerOnline() async throws {
        let transport = FakeTransport(structured)
        let loader = LyricsLoader(client: try client(transport), saved: { _ in [] })
        #expect(await loader.lines(songID: "1", artist: "A", title: "B").map(\.text) == ["from the server"])
    }

    @Test func offlineOnlyTheSavedLyrics() async throws {
        let transport = FakeTransport(structured)
        let saved = LyricsLoader(client: nil, saved: { _ in [LyricLine(text: "saved", start: 0)] })
        #expect(await saved.lines(songID: "1", artist: "A", title: "B").map(\.text) == ["saved"])
        let none = LyricsLoader(client: nil, saved: { _ in nil })
        #expect(await none.lines(songID: "1", artist: "A", title: "B").isEmpty)
        #expect(transport.requests.isEmpty)
    }

    @Test func savedLinesSurviveJSON() throws {
        let lines = [LyricLine(text: "one", start: 1, end: 1.999), LyricLine(text: "two", start: 2)]
        let data = try JSONEncoder().encode(lines)
        #expect(try JSONDecoder().decode([LyricLine].self, from: data) == lines)
    }
}

private extension TimeInterval {
    func isApproximately(_ other: TimeInterval) -> Bool { abs(self - other) < 0.000_001 }
}

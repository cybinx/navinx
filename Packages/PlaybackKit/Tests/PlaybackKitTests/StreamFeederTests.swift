import Foundation
import Testing
@testable import PlaybackKit

/// C49: the feeder's answers from the server are read strictly, and a stream held whole is capped.
@Suite struct StreamFeederTests {
    @Test func aPartMustStartWhereItWasAskedAndGiveTheTotal() {
        #expect(StreamFeeder.total(contentRange: "bytes 0-1/5000", offset: 0) == 5000)
        #expect(StreamFeeder.total(contentRange: "bytes 1000-4999/5000", offset: 1000) == 5000)
        #expect(StreamFeeder.total(contentRange: " Bytes 10-20/21 ", offset: 10) == 21)
        // A part from somewhere else, or no total: an error, never "the whole song".
        #expect(StreamFeeder.total(contentRange: "bytes 0-999/5000", offset: 1000) == nil)
        #expect(StreamFeeder.total(contentRange: "bytes 1000-1999/*", offset: 1000) == nil)
        #expect(StreamFeeder.total(contentRange: "bytes 1000-1999", offset: 1000) == nil)
        #expect(StreamFeeder.total(contentRange: nil, offset: 0) == nil)
        #expect(StreamFeeder.total(contentRange: "", offset: 0) == nil)
        #expect(StreamFeeder.total(contentRange: "bytes */5000", offset: 0) == nil)
        #expect(StreamFeeder.total(contentRange: "bytes 5-4/5000", offset: 5) == nil)
        #expect(StreamFeeder.total(contentRange: "bytes 0-5000/5000", offset: 0) == nil)
        #expect(StreamFeeder.total(contentRange: "bytes -1-10/5000", offset: -1) == nil)
        #expect(StreamFeeder.total(contentRange: "items 0-1/5000", offset: 0) == nil)
    }

    @Test func aWholeStreamPastItsLimitFails() {
        let stream = WholeStream(task: nil, mimeType: "audio/mpeg", limit: 10)
        #expect(stream.append(Data(count: 6)))
        #expect(stream.append(Data(count: 4)))
        #expect(stream.count == 10 && !stream.failed)
        #expect(!stream.append(Data(count: 1)))
        #expect(stream.failed)
        #expect(stream.count == 0)
        // Nothing more is taken once it has failed, and the end of the download changes nothing.
        #expect(!stream.append(Data(count: 1)))
        stream.finished(nil)
        #expect(stream.failed)
    }

    @Test func theLimitFitsAnyRealSong() {
        // Three and a half hours at 320 kbps.
        #expect(WholeStream.limit >= 320_000 / 8 * 3 * 3600 + 320_000 / 8 * 1800)
    }
}

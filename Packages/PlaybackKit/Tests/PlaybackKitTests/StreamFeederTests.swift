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

private let stream = URL(string: "https://music.example.com/rest/stream?id=a")!

/// C68 (D225): a ranged load whose connection drops tries again from the byte it had reached.
@Suite struct FeedRetryTests {
    let queue = DispatchQueue(label: "test.feed")

    private func makeLoad(
        _ target: FakeTarget, _ connections: FakeConnections, waits: [TimeInterval] = [0.01], window: TimeInterval = 5
    ) -> FeedLoad {
        FeedLoad(
            request: target, source: stream, connections: connections,
            retry: FeedRetry(waits: waits, window: window, timeout: 30), feeder: nil, queue: queue
        )
    }

    @Test func aDroppedConnectionCarriesOnFromTheByteReached() async {
        let connections = FakeConnections(queue: queue)
        let target = FakeTarget(start: 1000, end: 2000)
        let load = makeLoad(target, connections)
        queue.sync {
            load.start()
            #expect(connections.requests[0].value(forHTTPHeaderField: "Range") == "bytes=1000-1999")
            _ = connections.handlers[0].received(partial("bytes 1000-1999/5000"))
            connections.handlers[0].received(Data(repeating: 1, count: 300))
            connections.handlers[0].finished(URLError(.networkConnectionLost))
            // The player hears nothing of it.
            #expect(!target.isFinished)
        }
        #expect(await until(queue) { connections.requests.count == 2 })
        queue.sync {
            #expect(connections.requests[1].value(forHTTPHeaderField: "Range") == "bytes=1300-1999")
            // On a new session, not the one the connection dropped on.
            #expect(connections.renewals == 1)
            _ = connections.handlers[1].received(partial("bytes 1300-1999/5000"))
            connections.handlers[1].received(Data(repeating: 2, count: 700))
            connections.handlers[1].finished(nil)
            #expect(target.isFinished && target.error == nil)
            #expect(target.received.count == 1000 && target.received.prefix(300).allSatisfy { $0 == 1 })
            #expect(target.informed == 1 && target.length == 5000)
        }
    }

    @Test func aNetworkChangeTriesAgainAtOnce() async {
        let connections = FakeConnections(queue: queue)
        let target = FakeTarget(start: 0, end: nil)
        let load = makeLoad(target, connections, waits: [60], window: 120)
        queue.sync {
            load.start()
            _ = connections.handlers[0].received(partial("bytes 0-4999/5000"))
            connections.handlers[0].received(Data(count: 10))
            connections.handlers[0].finished(URLError(.notConnectedToInternet))
            connections.networkChanged()
        }
        #expect(await until(queue) { connections.requests.count == 2 })
        queue.sync {
            #expect(connections.requests[1].value(forHTTPHeaderField: "Range") == "bytes=10-")
            // The new session came from outside: none made for the try.
            #expect(connections.renewals == 1)
        }
    }

    @Test func itGivesUpAfterTheWindow() async throws {
        let connections = FakeConnections(queue: queue)
        connections.failure = URLError(.notConnectedToInternet)
        let target = FakeTarget(start: 0, end: 100)
        let load = makeLoad(target, connections, waits: [0.02], window: 0.3)
        let began = Date()
        queue.sync { load.start() }
        #expect(await until(queue) { target.isFinished })
        #expect(Date().timeIntervalSince(began) >= 0.3)
        let tries = queue.sync { connections.requests.count }
        #expect(tries > 2)
        queue.sync { #expect((target.error as? URLError)?.code == .notConnectedToInternet) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(queue.sync { connections.requests.count } == tries)
    }

    @Test func noTryAgainAfterAnHTTPErrorOrACancel() async throws {
        let connections = FakeConnections(queue: queue)
        let refused = FakeTarget(start: 0, end: 100)
        let cancelled = FakeTarget(start: 0, end: 100)
        let first = makeLoad(refused, connections)
        let second = makeLoad(cancelled, connections)
        queue.sync {
            first.start()
            #expect(connections.handlers[0].received(response(503)) == .cancel)
            connections.handlers[0].finished(URLError(.cancelled))
            #expect(refused.isFinished && refused.error != nil)
            second.start()
            second.cancel()
            connections.handlers[1].finished(URLError(.networkConnectionLost))
        }
        try await Task.sleep(for: .milliseconds(100))
        queue.sync {
            #expect(connections.requests.count == 2)
            #expect(!cancelled.isFinished)
        }
    }

    @Test func aTryAnsweredForAnotherLengthFails() async {
        let connections = FakeConnections(queue: queue)
        let target = FakeTarget(start: 0, end: nil)
        let load = makeLoad(target, connections)
        queue.sync {
            load.start()
            _ = connections.handlers[0].received(partial("bytes 0-4999/5000"))
            connections.handlers[0].received(Data(count: 10))
            connections.handlers[0].finished(URLError(.timedOut))
        }
        #expect(await until(queue) { connections.requests.count == 2 })
        queue.sync {
            #expect(connections.handlers[1].received(partial("bytes 10-5999/6000")) == .cancel)
            #expect(target.isFinished && target.error != nil)
        }
    }

    @Test func networkTroubleIsTheNetworksOnly() {
        #expect(NetworkTrouble.isNetwork(URLError(.networkConnectionLost)))
        #expect(NetworkTrouble.isNetwork(URLError(.notConnectedToInternet)))
        #expect(NetworkTrouble.isNetwork(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))))
        // Wrapped, as the player wraps the loader's.
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: URLError.networkConnectionLost.rawValue),
        ])
        #expect(NetworkTrouble.isNetwork(wrapped))
        #expect(!NetworkTrouble.isNetwork(URLError(.cancelled)))
        #expect(!NetworkTrouble.isNetwork(URLError(.badServerResponse)))
        #expect(!NetworkTrouble.isNetwork(URLError(.clientCertificateRejected)))
        #expect(!NetworkTrouble.isNetwork(NSError(domain: "AVFoundationErrorDomain", code: -11800)))
    }

    private func partial(_ range: String) -> HTTPURLResponse {
        response(206, headers: ["Content-Range": range])
    }

    private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: stream, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: headers.merging(["Content-Type": "audio/mpeg"]) { old, _ in old }
        )!
    }
}

/// Polls `condition` on `queue` until it holds.
private func until(_ queue: DispatchQueue, timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if queue.sync(execute: condition) { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return queue.sync(execute: condition)
}

/// One of the player's loading requests, as the feeder sees it.
private final class FakeTarget: FeedTarget, @unchecked Sendable {
    let feedRange: (start: Int64, end: Int64?)?
    private(set) var received = Data()
    private(set) var length: Int64?
    private(set) var informed = 0
    private(set) var isFinished = false
    private(set) var error: (any Error)?

    init(start: Int64, end: Int64?) {
        feedRange = (start, end)
    }

    var feedReached: Int64 { (feedRange?.start ?? 0) + Int64(received.count) }
    var feedWantsInformation: Bool { true }

    func feedInform(contentType: String, length: Int64, ranges: Bool) {
        self.length = length
        informed += 1
    }

    func feedSend(_ data: Data) { received.append(data) }

    func feedFinish(_ error: (any Error)?) {
        isFinished = true
        self.error = error
    }
}

private final class FakeTask: FeedTask {
    func cancel() {}
}

/// Records the requests; the tests answer them through their handlers.
private final class FakeConnections: FeedConnections, @unchecked Sendable {
    let queue: DispatchQueue
    private(set) var generation = 0
    private(set) var requests: [URLRequest] = []
    private(set) var handlers: [any FeedTaskHandler] = []
    private(set) var renewals = 0
    /// Every request fails at once with this (no network).
    var failure: URLError?
    private var waiters: [@Sendable () -> Void] = []

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start(_ request: URLRequest, handler: any FeedTaskHandler) -> any FeedTask {
        requests.append(request)
        handlers.append(handler)
        if let failure { queue.async { handler.finished(failure) } }
        return FakeTask()
    }

    func renew(ifStill generation: Int) {
        if generation == self.generation { networkChanged() }
    }

    func whenRenewed(_ action: @escaping @Sendable () -> Void) {
        waiters.append(action)
    }

    /// A new session, as a network change brings.
    func networkChanged() {
        generation += 1
        renewals += 1
        let all = waiters
        waiters.removeAll()
        for waiter in all { waiter() }
    }
}

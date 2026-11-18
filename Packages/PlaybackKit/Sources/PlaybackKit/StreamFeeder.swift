import AVFoundation
import DeviceIdentity
import Foundation
import ObjectiveC
import Synchronization
import UniformTypeIdentifiers

/// The player's way to a server that asks for the device's certificate (C45). The system's media loader
/// never presents a client certificate and never asks the resource loader for one (proved on the
/// simulator, iOS 27.2), so for such a server the app loads the stream itself, over a session that
/// answers from `DeviceCertificates`, and feeds the bytes to the player through
/// `AVAssetResourceLoader`. The player still gets one `AVURLAsset` per song and asks for byte ranges as
/// it would over HTTP, so gapless changes, crossfade (two players) and seeking work as before. Any other
/// address (a server without a certificate here, the home-network address, a downloaded file) plays
/// as it always did: `asset(for:options:)` returns nil.
final class StreamFeeder: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    /// The address the player is given instead of the stream's, so the loader is asked for every byte.
    static let scheme = "navinx-feed"
    /// Everything here runs on this queue: the loader's calls and the session's.
    static let queue = DispatchQueue(label: "navinx.stream-feeder")
    nonisolated(unsafe) private static var holder: UInt8 = 0

    private let source: URL
    private let session: any FeedConnections
    private let retry: FeedRetry
    private var loads: [ObjectIdentifier: FeedLoad] = [:]
    /// The whole stream, when the server sends it with no length and no ranges (a transcoded stream).
    private var whole: WholeStream?
    /// Set when a load gave up on the network, or the whole stream broke off (C68): the player's failure
    /// is then a network one, whatever error the system wraps it in. Read on the main actor.
    private let networkTrouble = Mutex(false)

    init(source: URL, session: any FeedConnections = FeedSession.shared, retry: FeedRetry = .standard) {
        self.source = source
        self.session = session
        self.retry = retry
    }

    deinit {
        for load in loads.values { load.cancel() }
        whole?.task?.cancel()
    }

    /// An asset fed by the app for `url`, or nil when a connection there presents no certificate.
    static func asset(for url: URL, options: [String: Any], certificates: DeviceCertificates = .shared) -> AVURLAsset? {
        guard certificates.presents(to: url),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = scheme
        guard let fed = components.url else { return nil }
        let asset = AVURLAsset(url: fed, options: options)
        let feeder = StreamFeeder(source: url)
        asset.resourceLoader.setDelegate(feeder, queue: queue)
        // The loader holds its delegate weakly: the asset keeps it.
        objc_setAssociatedObject(asset, &holder, feeder, .OBJC_ASSOCIATION_RETAIN)
        return asset
    }

    /// Whether `asset`'s feed failed for a network reason (its loads gave up, C68). False for an asset
    /// the app doesn't feed.
    static func failedOnNetwork(_ asset: AVAsset) -> Bool {
        (objc_getAssociatedObject(asset, &holder) as? StreamFeeder)?.networkTrouble.withLock { $0 } ?? false
    }

    fileprivate func noteNetworkTrouble() {
        networkTrouble.withLock { $0 = true }
    }

    // MARK: The loader

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let whole {
            whole.add(loadingRequest)
            return true
        }
        let load = FeedLoad(request: loadingRequest, source: source, connections: session, retry: retry, feeder: self)
        loads[ObjectIdentifier(loadingRequest)] = load
        load.start()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        if let load = loads.removeValue(forKey: ObjectIdentifier(loadingRequest)) {
            // A load that turned into the whole stream keeps going for the requests still to come.
            load.cancel(keepingTask: whole?.task === load.task)
        }
        whole?.remove(loadingRequest)
    }

    fileprivate func finished(_ load: FeedLoad) {
        loads[ObjectIdentifier(load.request)] = nil
    }

    /// The server sent the whole stream with no length: it's kept as it arrives, and every request is
    /// answered from it once it's all here.
    fileprivate func becomeWhole(from load: FeedLoad) -> WholeStream {
        let stream = WholeStream(task: load.task, mimeType: load.mimeType)
        whole = stream
        loads[ObjectIdentifier(load.request)] = nil
        if !load.cancelled { stream.add(load.request) }
        // Requests already on their way elsewhere are answered from it too.
        for other in loads.values {
            other.cancel()
            stream.add(other.request)
        }
        loads.removeAll()
        return stream
    }

/// The whole length a 206's `Content-Range` gives (`bytes <start>-<end>/<total>`), or nil unless it
    /// starts at `offset`, ends after it and inside the total, and the total is a number (not `*`).
    static func total(contentRange: String?, offset: Int64) -> Int64? {
        guard let text = contentRange?.trimmingCharacters(in: .whitespaces),
              text.lowercased().hasPrefix("bytes ") else { return nil }
        let rest = text.dropFirst("bytes ".count).trimmingCharacters(in: .whitespaces)
        let halves = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let bounds = halves[0].split(separator: "-", omittingEmptySubsequences: false)
        func number(_ part: Substring) -> Int64? {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber) else { return nil }
            return Int64(part)
        }
        guard bounds.count == 2, let start = number(bounds[0]), let end = number(bounds[1]),
              let total = number(halves[1]), start == offset, end >= start, end < total else { return nil }
        return total
    }

    static func contentType(_ mimeType: String?) -> String {
        mimeType.flatMap { UTType(mimeType: $0) }?.identifier ?? UTType.mp3.identifier
    }
}

/// How a ranged load whose connection drops tries again (C68, D225): from the byte it had reached, on a
/// fresh session, after a short wait that grows, for `window` seconds from the drop. Only then does it fail
/// as before. Bytes arriving again start a new window, so a later drop in the same song gets its own.
struct FeedRetry: Sendable {
    /// The waits before each new try, the last one repeated.
    var waits: [TimeInterval]
    /// How long after the drop a load keeps trying. The gateway drops a refused device's request the
    /// same way the network does, so this is what ends it.
    var window: TimeInterval
    /// The first request's timeout, and the longest a new try's may be.
    var timeout: TimeInterval

    static let standard = FeedRetry(waits: [0.5, 1, 2, 3], window: 30, timeout: 30)

    func wait(before attempt: Int) -> TimeInterval {
        guard let last = waits.last else { return 0 }
        return attempt < waits.count ? waits[attempt] : last
    }
}

/// What a fed load answers: one of the player's loading requests (tests stand in their own).
protocol FeedTarget: AnyObject {
    /// The bytes asked for: the first, and the one after the last (nil: to the end). Nil when only the
    /// content's information is asked.
    var feedRange: (start: Int64, end: Int64?)? { get }
    /// How far the answer has got: the next byte it sends.
    var feedReached: Int64 { get }
    var feedWantsInformation: Bool { get }
    func feedInform(contentType: String, length: Int64, ranges: Bool)
    func feedSend(_ data: Data)
    func feedFinish(_ error: (any Error)?)
}

extension AVAssetResourceLoadingRequest: FeedTarget {
    var feedRange: (start: Int64, end: Int64?)? {
        guard let data = dataRequest else { return nil }
        let end = data.requestsAllDataToEndOfResource ? nil : data.requestedOffset + Int64(max(data.requestedLength, 1))
        return (data.requestedOffset, end)
    }

    var feedReached: Int64 { dataRequest?.currentOffset ?? 0 }

    var feedWantsInformation: Bool { contentInformationRequest != nil }

    func feedInform(contentType: String, length: Int64, ranges: Bool) {
        guard let info = contentInformationRequest else { return }
        info.contentType = contentType
        info.contentLength = length
        info.isByteRangeAccessSupported = ranges
    }

    func feedSend(_ data: Data) { dataRequest?.respond(with: data) }

    func feedFinish(_ error: (any Error)?) {
        if let error { finishLoading(with: error) } else { finishLoading() }
    }
}

/// A request to the server under way; a `URLSessionDataTask` (tests stand in their own).
protocol FeedTask: AnyObject {
    func cancel()
}

extension URLSessionDataTask: FeedTask {}

/// Where fed loads send their requests: `FeedSession` (tests stand in their own). On `StreamFeeder.queue`.
protocol FeedConnections: AnyObject, Sendable {
    /// Counts the sessions made: a request remembers the one it went on.
    var generation: Int { get }
    func start(_ request: URLRequest, handler: any FeedTaskHandler) -> any FeedTask
    /// A new session for the next requests, unless one was made since `generation`'s.
    func renew(ifStill generation: Int)
    /// `action` runs once, at the next new session (a network change brings one, C68).
    func whenRenewed(_ action: @escaping @Sendable () -> Void)
}

/// One loading request, answered by one ranged request to the server, or by more where the connection
/// drops (C68): each new one from the byte reached.
final class FeedLoad: FeedTaskHandler, @unchecked Sendable {
    let request: any FeedTarget
    weak var feeder: StreamFeeder?
    var task: (any FeedTask)?
    private(set) var cancelled = false
    var mimeType: String?
    private let source: URL
    private let connections: any FeedConnections
    private let retry: FeedRetry
    private let queue: DispatchQueue
    private let now: @Sendable () -> Date
    /// The byte after the last one asked for; nil: to the end.
    private let end: Int64?
    /// The next byte to send: where a new request starts.
    private var reached: Int64
    /// The song's whole length, once an answer has given it: a later answer must give the same.
    private var total: Int64?
    /// Bytes to drop from the front: the server ignored the range and sent from the start.
    private var skip: Int64 = 0
    private var whole: WholeStream?
    private var done = false
    /// The session the request under way went on.
    private var generation = 0
    /// When the connection first dropped, in this run of tries; nil while bytes are coming.
    private var droppedAt: Date?
    private var attempts = 0
    private var pendingTry: DispatchWorkItem?

    init(
        request: any FeedTarget, source: URL, connections: any FeedConnections, retry: FeedRetry = .standard,
        feeder: StreamFeeder?, queue: DispatchQueue = StreamFeeder.queue, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.request = request
        self.source = source
        self.connections = connections
        self.retry = retry
        self.feeder = feeder
        self.queue = queue
        self.now = now
        let range = request.feedRange
        end = range?.end
        reached = range?.start ?? 0
    }

    /// Sends the request, from the byte reached.
    func start() {
        var timeout = retry.timeout
        if let droppedAt {
            // A new try lasts no longer than what's left of the window (but long enough for a handshake).
            timeout = min(retry.timeout, max(5, retry.window - now().timeIntervalSince(droppedAt)))
        }
        var urlRequest = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        if request.feedRange != nil {
            if let end {
                urlRequest.setValue("bytes=\(reached)-\(end - 1)", forHTTPHeaderField: "Range")
            } else {
                urlRequest.setValue("bytes=\(reached)-", forHTTPHeaderField: "Range")
            }
        } else {
            urlRequest.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        }
        generation = connections.generation
        task = connections.start(urlRequest, handler: self)
    }

    /// The player no longer wants it: nothing more is sent or tried. `keepingTask`: the request under way
    /// goes on (it's become the whole stream's).
    func cancel(keepingTask: Bool = false) {
        cancelled = true
        pendingTry?.cancel()
        pendingTry = nil
        if !keepingTask { task?.cancel() }
    }

    func received(_ response: URLResponse) -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206 else {
            finish(URLError(.badServerResponse))
            return .cancel
        }
        mimeType = http.mimeType
        var length: Int64?
        if http.statusCode == 206 {
            // A part must say where it starts (the byte asked for) and the whole length (C49); one that
            // doesn't is an error, never taken for the whole song.
            guard let known = StreamFeeder.total(contentRange: http.value(forHTTPHeaderField: "Content-Range"), offset: reached) else {
                finish(URLError(.badServerResponse))
                return .cancel
            }
            length = known
            skip = 0
        } else if http.expectedContentLength > 0 {
            length = http.expectedContentLength
            skip = reached
        }
        guard let length else {
            // No length and no ranges: the whole stream, kept until it's all here. Not once part of the
            // song has gone to the player: it can't be picked up from there.
            guard total == nil, reached == request.feedRange?.start ?? 0 else {
                finish(URLError(.badServerResponse))
                return .cancel
            }
            whole = feeder?.becomeWhole(from: self)
            return whole == nil ? .cancel : .allow
        }
        if let total {
            // A new try must be for the same song: another length would play as another song.
            guard length == total else {
                finish(URLError(.badServerResponse))
                return .cancel
            }
        } else {
            total = length
            if request.feedWantsInformation {
                request.feedInform(
                    contentType: StreamFeeder.contentType(http.mimeType), length: length, ranges: http.statusCode == 206
                )
            }
        }
        return .allow
    }

    func received(_ data: Data) {
        if let whole {
            whole.append(data)
            return
        }
        guard !done, !cancelled, request.feedRange != nil else { return }
        var data = data
        if skip > 0 {
            let cut = Int(min(Int64(data.count), skip))
            skip -= Int64(cut)
            data = data.subdata(in: cut..<data.count)
            if data.isEmpty { return }
        }
        request.feedSend(data)
        reached += Int64(data.count)
        // Coming again: a later drop gets a window of its own.
        droppedAt = nil
        attempts = 0
    }

    func finished(_ error: (any Error)?) {
        if let whole {
            if let error, NetworkTrouble.isNetwork(error) { feeder?.noteNetworkTrouble() }
            whole.finished(error)
            return
        }
        guard !done else { return }
        guard let error, !cancelled else {
            finish(error)
            return
        }
        // Everything asked for has been sent (the connection went just after): done.
        if isComplete {
            finish(nil)
            return
        }
        guard NetworkTrouble.isNetwork(error) else {
            finish(error)
            return
        }
        tryAgain(after: error)
    }

    private var isComplete: Bool {
        guard request.feedRange != nil else { return total != nil }
        if let end { return reached >= end }
        if let total { return reached >= total }
        return false
    }

    /// The connection dropped: a new request after a short wait, or at once when a new session comes
    /// (the network changed), until the window is over.
    private func tryAgain(after error: any Error) {
        let moment = now()
        let since = droppedAt ?? moment
        droppedAt = since
        let elapsed = moment.timeIntervalSince(since)
        guard elapsed < retry.window else {
            feeder?.noteNetworkTrouble()
            finish(error)
            return
        }
        task = nil
        let wait = min(retry.wait(before: attempts), retry.window - elapsed)
        attempts += 1
        let item = DispatchWorkItem { [weak self] in self?.tryNow() }
        pendingTry = item
        queue.asyncAfter(deadline: .now() + wait, execute: item)
        connections.whenRenewed { [weak self] in
            guard let self else { return }
            self.queue.async { self.tryNow() }
        }
    }

    private func tryNow() {
        guard let item = pendingTry, !done, !cancelled else { return }
        item.cancel()
        pendingTry = nil
        // Not on the session the connection dropped on: its other connections may be as dead.
        connections.renew(ifStill: generation)
        start()
    }

    private func finish(_ error: (any Error)?) {
        guard !done else { return }
        done = true
        pendingTry?.cancel()
        pendingTry = nil
        feeder?.finished(self)
        guard !cancelled else { return }
        request.feedFinish(error)
    }
}

/// Which failures are the network's (C68, D225): the connection lost, timed out or never made, no network,
/// the name not found. Not an HTTP status, not a cancel, not a refused certificate.
enum NetworkTrouble {
    static let urlCodes: Set<Int> = [
        URLError.networkConnectionLost.rawValue, URLError.timedOut.rawValue, URLError.notConnectedToInternet.rawValue,
        URLError.cannotConnectToHost.rawValue, URLError.cannotFindHost.rawValue, URLError.dnsLookupFailed.rawValue,
        URLError.internationalRoamingOff.rawValue, URLError.callIsActive.rawValue, URLError.dataNotAllowed.rawValue,
        URLError.secureConnectionFailed.rawValue, URLError.cannotLoadFromNetwork.rawValue,
    ]
    static let posixCodes: Set<Int> = [
        Int(ECONNRESET), Int(ECONNABORTED), Int(ENETDOWN), Int(ENETUNREACH), Int(ENETRESET), Int(EHOSTUNREACH),
        Int(EHOSTDOWN), Int(ETIMEDOUT), Int(ENOTCONN), Int(EPIPE),
    ]

    /// `error`, or one it wraps (the player wraps the loader's), is one of the network's.
    static func isNetwork(_ error: any Error) -> Bool {
        var next: NSError? = error as NSError
        var depth = 0
        while let current = next, depth < 8 {
            if current.domain == NSURLErrorDomain, urlCodes.contains(current.code) { return true }
            if current.domain == NSPOSIXErrorDomain, posixCodes.contains(current.code) { return true }
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }
}

/// A stream the server sends whole, with no length: requests wait until it's all here, then are
/// answered from memory, with ranges. At most `limit` bytes are held (C49): past it the download stops
/// and the song fails as a broken stream does, so an endless or huge answer can't fill the phone's memory.
/// It can't be picked up again where a dropped connection left it: the player's own fallback loads the
/// song again (C68).
final class WholeStream: @unchecked Sendable {
    /// 512 MiB: about 3 h 45 min at 320 kbps, the highest bitrate a transcoded stream has, so any real
    /// song (and nearly any mix) fits; a typical song is under 15 MB.
    static let limit = 512 * 1024 * 1024

    weak var task: (any FeedTask)?
    private let mimeType: String?
    private let limit: Int
    private var data = Data()
    private var complete = false
    private var failure: (any Error)?
    private var waiting: [any FeedTarget] = []

    init(task: (any FeedTask)?, mimeType: String?, limit: Int = WholeStream.limit) {
        self.task = task
        self.mimeType = mimeType
        self.limit = limit
    }

    /// The bytes held, and whether the stream ended in an error (tests).
    var count: Int { data.count }
    var failed: Bool { failure != nil }

    func add(_ request: any FeedTarget) {
        if complete { answer(request) } else { waiting.append(request) }
    }

    func remove(_ request: any FeedTarget) {
        waiting.removeAll { $0 === request }
    }

    /// False when the stream has ended, or this chunk takes it past `limit`: then the download is
    /// cancelled, what was held goes, and every request fails.
    @discardableResult
    func append(_ chunk: Data) -> Bool {
        guard !complete else { return false }
        guard chunk.count <= limit - data.count else {
            data = Data()
            task?.cancel()
            finished(URLError(.dataLengthExceedsMaximum))
            return false
        }
        data.append(chunk)
        return true
    }

    func finished(_ error: (any Error)?) {
        guard !complete else { return }
        complete = true
        failure = error
        let all = waiting
        waiting.removeAll()
        all.forEach(answer)
    }

    private func answer(_ request: any FeedTarget) {
        // Part of a song would play as a shorter song: a broken download is an error.
        if let failure {
            request.feedFinish(failure)
            return
        }
        if request.feedWantsInformation {
            request.feedInform(contentType: StreamFeeder.contentType(mimeType), length: Int64(data.count), ranges: true)
        }
        if let range = request.feedRange {
            let start = Int(min(Int64(data.count), request.feedReached))
            let end = range.end.map { Int(min(Int64(data.count), $0)) } ?? data.count
            if start < end { request.feedSend(data.subdata(in: start..<end)) }
        }
        request.feedFinish(nil)
    }
}

protocol FeedTaskHandler: AnyObject, Sendable {
    func received(_ response: URLResponse) -> URLSession.ResponseDisposition
    func received(_ data: Data)
    func finished(_ error: (any Error)?)
}

/// One session for every fed stream, on the feeder's queue, answering the server's request for a
/// certificate from `DeviceCertificates`. Nothing is cached (the address carries the login).
final class FeedSession: NSObject, URLSessionDataDelegate, FeedConnections, @unchecked Sendable {
    static let shared = FeedSession()

    /// By task, not its identifier: a renewed session numbers its tasks from 1 again.
    private var handlers: [ObjectIdentifier: any FeedTaskHandler] = [:]
    private let certificates: DeviceCertificates
    private lazy var session: URLSession = makeSession()
    private(set) var generation = 0
    /// What runs at the next new session: loads waiting to try again (C68).
    private var renewalWaiters: [@Sendable () -> Void] = []

    init(certificates: DeviceCertificates = .shared) {
        self.certificates = certificates
        super.init()
        // A certificate stored, renewed or removed, or the network changed (C68): new streams go on a new
        // session (a new handshake, where the server asks for it, on a connection that works); the old one
        // finishes the streams it's feeding.
        certificates.addConnectionReset { [weak self] in
            guard let self else { return }
            StreamFeeder.queue.async { self.renewSession() }
        }
    }

    private func makeSession() -> URLSession {
        let queue = OperationQueue()
        queue.underlyingQueue = StreamFeeder.queue
        queue.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    /// On `StreamFeeder.queue`.
    private func renewSession() {
        let old = session
        session = makeSession()
        generation += 1
        old.finishTasksAndInvalidate()
        let waiters = renewalWaiters
        renewalWaiters.removeAll()
        for waiter in waiters { waiter() }
    }

    /// On `StreamFeeder.queue`.
    func renew(ifStill generation: Int) {
        if generation == self.generation { renewSession() }
    }

    /// On `StreamFeeder.queue`.
    func whenRenewed(_ action: @escaping @Sendable () -> Void) {
        renewalWaiters.append(action)
    }

    /// On `StreamFeeder.queue`.
    func start(_ request: URLRequest, handler: any FeedTaskHandler) -> any FeedTask {
        let task = session.dataTask(with: request)
        handlers[ObjectIdentifier(task)] = handler
        task.resume()
        return task
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let (disposition, credential) = certificates.answer(challenge)
        completionHandler(disposition, credential)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(handlers[ObjectIdentifier(dataTask)]?.received(response) ?? .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handlers[ObjectIdentifier(dataTask)]?.received(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        handlers.removeValue(forKey: ObjectIdentifier(task))?.finished(error)
    }
}

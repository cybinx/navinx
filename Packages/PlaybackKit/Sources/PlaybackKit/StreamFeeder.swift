import AVFoundation
import DeviceIdentity
import Foundation
import ObjectiveC
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
    private let session: FeedSession
    private var loads: [ObjectIdentifier: FeedLoad] = [:]
    /// The whole stream, when the server sends it with no length and no ranges (a transcoded stream).
    private var whole: WholeStream?

    init(source: URL, session: FeedSession = .shared) {
        self.source = source
        self.session = session
    }

    deinit {
        for load in loads.values { load.task?.cancel() }
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

    // MARK: The loader

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let whole {
            whole.add(loadingRequest)
            return true
        }
        var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        var offset: Int64 = 0
        if let data = loadingRequest.dataRequest {
            offset = data.requestedOffset
            if data.requestsAllDataToEndOfResource {
                request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            } else {
                request.setValue("bytes=\(offset)-\(offset + Int64(max(data.requestedLength, 1)) - 1)", forHTTPHeaderField: "Range")
            }
        } else {
            request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        }
        let load = FeedLoad(request: loadingRequest, offset: offset, feeder: self)
        loads[ObjectIdentifier(loadingRequest)] = load
        load.task = session.start(request, handler: load)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        if let load = loads.removeValue(forKey: ObjectIdentifier(loadingRequest)) {
            load.cancelled = true
            // A load that turned into the whole stream keeps going for the requests still to come.
            if whole?.task !== load.task { load.task?.cancel() }
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
            other.cancelled = true
            other.task?.cancel()
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

/// One loading request, answered by one ranged request to the server.
final class FeedLoad: FeedTaskHandler, @unchecked Sendable {
    let request: AVAssetResourceLoadingRequest
    let offset: Int64
    weak var feeder: StreamFeeder?
    var task: URLSessionDataTask?
    var cancelled = false
    var mimeType: String?
    /// Bytes to drop from the front: the server ignored the range and sent from the start.
    private var skip: Int64 = 0
    private var whole: WholeStream?
    private var done = false

    init(request: AVAssetResourceLoadingRequest, offset: Int64, feeder: StreamFeeder) {
        self.request = request
        self.offset = offset
        self.feeder = feeder
    }

    func received(_ response: URLResponse) -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206 else {
            finish(URLError(.badServerResponse))
            return .cancel
        }
        mimeType = http.mimeType
        var total: Int64?
        if http.statusCode == 206 {
            // A part must say where it starts (the offset asked for) and the whole length (C49); one that
            // doesn't is an error, never taken for the whole song.
            guard let known = StreamFeeder.total(contentRange: http.value(forHTTPHeaderField: "Content-Range"), offset: offset) else {
                finish(URLError(.badServerResponse))
                return .cancel
            }
            total = known
        } else if http.expectedContentLength > 0 {
            total = http.expectedContentLength
            skip = offset
        }
        guard let total else {
            // No length and no ranges: the whole stream, kept until it's all here.
            whole = feeder?.becomeWhole(from: self)
            return whole == nil ? .cancel : .allow
        }
        if let info = request.contentInformationRequest {
            info.contentType = StreamFeeder.contentType(http.mimeType)
            info.contentLength = total
            info.isByteRangeAccessSupported = http.statusCode == 206
        }
        return .allow
    }

    func received(_ data: Data) {
        if let whole {
            whole.append(data)
            return
        }
        guard !done, !cancelled, let dataRequest = request.dataRequest else { return }
        var data = data
        if skip > 0 {
            let cut = Int(min(Int64(data.count), skip))
            skip -= Int64(cut)
            data = data.subdata(in: cut..<data.count)
            if data.isEmpty { return }
        }
        dataRequest.respond(with: data)
    }

    func finished(_ error: (any Error)?) {
        if let whole {
            whole.finished(error)
            return
        }
        finish(error)
    }

    private func finish(_ error: (any Error)?) {
        guard !done else { return }
        done = true
        feeder?.finished(self)
        guard !cancelled else { return }
        if let error { request.finishLoading(with: error) } else { request.finishLoading() }
    }
}

/// A stream the server sends whole, with no length: requests wait until it's all here, then are
/// answered from memory, with ranges. At most `limit` bytes are held (C49): past it the download stops
/// and the song fails as a broken stream does, so an endless or huge answer can't fill the phone's memory.
final class WholeStream: @unchecked Sendable {
    /// 512 MiB: about 3 h 45 min at 320 kbps, the highest bitrate a transcoded stream has, so any real
    /// song (and nearly any mix) fits; a typical song is under 15 MB.
    static let limit = 512 * 1024 * 1024

    weak var task: URLSessionDataTask?
    private let mimeType: String?
    private let limit: Int
    private var data = Data()
    private var complete = false
    private var failure: (any Error)?
    private var waiting: [AVAssetResourceLoadingRequest] = []

    init(task: URLSessionDataTask?, mimeType: String?, limit: Int = WholeStream.limit) {
        self.task = task
        self.mimeType = mimeType
        self.limit = limit
    }

    /// The bytes held, and whether the stream ended in an error (tests).
    var count: Int { data.count }
    var failed: Bool { failure != nil }

    func add(_ request: AVAssetResourceLoadingRequest) {
        if complete { answer(request) } else { waiting.append(request) }
    }

    func remove(_ request: AVAssetResourceLoadingRequest) {
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

    private func answer(_ request: AVAssetResourceLoadingRequest) {
        // Part of a song would play as a shorter song: a broken download is an error.
        if let failure {
            request.finishLoading(with: failure)
            return
        }
        if let info = request.contentInformationRequest {
            info.contentType = StreamFeeder.contentType(mimeType)
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }
        if let dataRequest = request.dataRequest {
            let start = Int(min(Int64(data.count), dataRequest.currentOffset))
            let end = dataRequest.requestsAllDataToEndOfResource
                ? data.count
                : Int(min(Int64(data.count), dataRequest.requestedOffset + Int64(dataRequest.requestedLength)))
            if start < end { dataRequest.respond(with: data.subdata(in: start..<end)) }
        }
        request.finishLoading()
    }
}

protocol FeedTaskHandler: AnyObject, Sendable {
    func received(_ response: URLResponse) -> URLSession.ResponseDisposition
    func received(_ data: Data)
    func finished(_ error: (any Error)?)
}

/// One session for every fed stream, on the feeder's queue, answering the server's request for a
/// certificate from `DeviceCertificates`. Nothing is cached (the address carries the login).
final class FeedSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = FeedSession()

    /// By task, not its identifier: a renewed session numbers its tasks from 1 again.
    private var handlers: [ObjectIdentifier: any FeedTaskHandler] = [:]
    private let certificates: DeviceCertificates
    private lazy var session: URLSession = makeSession()

    init(certificates: DeviceCertificates = .shared) {
        self.certificates = certificates
        super.init()
        // A certificate stored, renewed or removed: new streams go on a new session (a new handshake, where
        // the server asks for it); the old one finishes the streams it's feeding.
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
        old.finishTasksAndInvalidate()
    }

    /// On `StreamFeeder.queue`.
    func start(_ request: URLRequest, handler: any FeedTaskHandler) -> URLSessionDataTask {
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

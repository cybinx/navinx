import DeviceIdentity
import Foundation
import UIKit

/// Fetches one file to disk. Behind a protocol so tests can run the queue without a network, as a
/// background session's requests can't be stubbed.
nonisolated protocol DownloadTransport: Sendable {
    /// Writes `url`'s body to `destination`, replacing anything there. Throws on a network error,
    /// a non-2xx answer, or cancellation (leaving nothing of its own at `destination`).
    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws
    /// The same, kept off mobile data, Low Data Mode and personal hotspots when `wifiOnly` (Smart
    /// Downloads, C37), even while the app is in the background: such a task waits for Wi-Fi.
    func download(
        from url: URL, to destination: URL, wifiOnly: Bool, progress: @escaping @Sendable (Double) -> Void
    ) async throws
    /// Stops every task whose file goes under `folder` (a server's downloads deleted), those left from
    /// an earlier run of the app included, so none brings a file back.
    func cancelTasks(under folder: URL)
    /// Stops the tasks left from an earlier run that nothing has asked for since: their files would
    /// land with no record.
    func cancelUnclaimedLeftovers()
}

extension DownloadTransport {
    func download(
        from url: URL, to destination: URL, wifiOnly: Bool, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await download(from: url, to: destination, progress: progress)
    }
}

nonisolated enum DownloadError: Error, Equatable {
    case badStatus(Int)
    case tooSmall
    case noServer
}

/// The system's background downloads (Flutter downloaded in the app, and kept the screen on for it).
/// The downloads carry on while the app is in the background, and iOS relaunches the app to hand
/// over the ones that finished after it was closed. Each task's description is its destination, so
/// a finished file lands in the right place even then, and the next launch finds it there. The
/// destination is written under the downloads folder (`<server>/songs/<file>`), as the app's own
/// folder can move between launches (an update, a restore).
nonisolated final class BackgroundDownloader: NSObject, DownloadTransport, URLSessionDownloadDelegate, @unchecked Sendable {
    static let identifier = "com.cybinx.navinx.app.downloads"
    static let shared = BackgroundDownloader()

    private struct Waiter {
        var continuation: CheckedContinuation<Void, any Error>?
        var progress: (@Sendable (Double) -> Void)?
        /// What `didFinishDownloadingTo` found, for `didCompleteWithError` to report.
        var failure: (any Error)?
        /// Whether this task moved its file to the destination: only then is what's there its own
        /// to delete on a failure (another fetch's file may be there).
        var placed = false
    }

    private let lock = NSLock()
    private var waiters: [Int: Waiter] = [:]
    /// Tasks left from an earlier run, by destination (`key(for:)`), to join instead of starting again.
    private var leftovers: [String: URLSessionDownloadTask] = [:]
    private var leftoversRead = false
    private var leftoverReaders: [CheckedContinuation<Void, Never>] = []
    /// iOS's completion handler from a relaunch for finished downloads. Main-thread only, where
    /// UIKit hands it over and wants it called.
    @MainActor private var eventsDone: (() -> Void)?
    /// The session finished its events before UIKit handed over the handler (the session is made
    /// at launch, which can come first): the handler is called as soon as it arrives.
    @MainActor private var eventsFinishedEarly = false
    private var storedSession: URLSession?

    /// Made on first use: a background session with this identifier must exist only once.
    private var session: URLSession {
        lock.withLock {
            if let storedSession { return storedSession }
            let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
            configuration.isDiscretionary = false
            configuration.sessionSendsLaunchEvents = true
            configuration.allowsCellularAccess = true
            configuration.httpMaximumConnectionsPerHost = 6
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            storedSession = session
            return session
        }
    }

    /// The folder destinations are written under.
    private let root: URL
    /// Called when a reset (`resetConnections()`, on a certificate change) has finished: tests wait on it.
    private let didReset: @Sendable () -> Void

    /// `session`: only for tests, which can't make a background session (the app makes its own on first use).
    init(
        certificates: DeviceCertificates = .shared, session: URLSession? = nil,
        didReset: @escaping @Sendable () -> Void = {}
    ) {
        root = DownloadStore.rootDirectory
        storedSession = session
        self.didReset = didReset
        super.init()
        // A certificate stored, renewed or removed: this session can't be swapped for a new one (one per
        // identifier, run by the system), so it's reset in place instead. Only then: not on a change of
        // account (every launch, sign-in, sign-out) nor the revocation's re-check, which reset the others.
        certificates.addCertificateChange { [weak self] in self?.resetConnections() }
    }

    /// The session's own reset (`URLSession.reset`): its credential stores emptied (the `.forSession`
    /// credential included, so the next handshake asks again) and its future requests on new sockets, where
    /// the server asks for the certificate. Its tasks, their waiters and the delegate stay as they are. A
    /// session not made yet has nothing to reset, and none is made for it.
    func resetConnections() {
        guard let session = lock.withLock({ storedSession }) else { return }
        session.reset { [didReset] in didReset() }
    }

    // MARK: Destinations

    /// A destination as a task keeps it: under the downloads folder, as `<server>/songs/<file>`.
    private func key(for destination: URL) -> String {
        let path = destination.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// A task's description as `key(for:)`'s form. Earlier builds wrote the whole path, whose app
    /// folder may have changed since: the part under the downloads folder's name is kept.
    private func key(description: String) -> String {
        guard description.hasPrefix("/") else { return description }
        let mine = key(for: URL(filePath: description))
        if !mine.hasPrefix("/") { return mine }
        let marker = "/" + root.standardizedFileURL.lastPathComponent + "/"
        guard let range = description.range(of: marker, options: .backwards) else { return description }
        return String(description[range.upperBound...])
    }

    /// Where a task's file goes, from its description.
    private func destination(description: String) -> URL {
        let key = self.key(description: description)
        return key.hasPrefix("/") ? URL(filePath: key) : root.appending(path: key)
    }

    /// Reconnects to the session, which delivers anything that finished while the app was away.
    func start() {
        session.getAllTasks { [self] tasks in
            lock.withLock {
                for case let task as URLSessionDownloadTask in tasks where task.state == .running || task.state == .suspended {
                    if let description = task.taskDescription { leftovers[key(description: description)] = task }
                }
                leftoversRead = true
            }
            let readers = lock.withLock {
                defer { leftoverReaders = [] }
                return leftoverReaders
            }
            readers.forEach { $0.resume() }
        }
    }

    /// From the app delegate, when iOS relaunches the app for this session.
    @MainActor
    func handleEvents(completion: @escaping () -> Void) {
        _ = session
        if eventsFinishedEarly {
            eventsFinishedEarly = false
            completion()
        } else {
            eventsDone = completion
        }
    }

    @MainActor
    private func eventsFinished() {
        if let done = eventsDone {
            eventsDone = nil
            done()
        } else {
            eventsFinishedEarly = true
        }
    }

    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await download(from: url, to: destination, wifiOnly: false, progress: progress)
    }

    func download(
        from url: URL, to destination: URL, wifiOnly: Bool, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        await leftoversReady()
        let session = session
        let key = self.key(for: destination)
        var request = URLRequest(url: url)
        if wifiOnly {
            request.allowsCellularAccess = false
            request.allowsExpensiveNetworkAccess = false
            request.allowsConstrainedNetworkAccess = false
        }
        var stale: URLSessionDownloadTask?
        let task: URLSessionDownloadTask = lock.withLock {
            if let leftover = leftovers.removeValue(forKey: key) {
                if Self.canJoin(leftover.originalRequest, as: request) { return leftover }
                stale = leftover
            }
            // The user's own as before C37; only Smart Downloads' carry the request's limits.
            let task = wifiOnly ? session.downloadTask(with: request) : session.downloadTask(with: url)
            task.taskDescription = key
            return task
        }
        // Started on another address (home, away) or under other network limits: it could wait for
        // ever, so it goes and this one starts afresh. It has no waiter, so its end reports nothing.
        stale?.cancel()
        let id = task.taskIdentifier
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.withLock {
                    waiters[id, default: Waiter()].continuation = continuation
                    waiters[id]?.progress = progress
                }
                if Task.isCancelled {
                    task.cancel()
                } else if task.state == .suspended {
                    task.resume()
                }
                // A leftover, or a cancelled one, that finished before anyone was waiting: whoever
                // takes the waiter out answers it, so it's answered once.
                if task.state == .completed, let waiter = lock.withLock({ waiters.removeValue(forKey: id) }) {
                    if waiter.failure == nil, !Task.isCancelled, FileManager.default.fileExists(atPath: destination.path) {
                        waiter.continuation?.resume()
                    } else {
                        waiter.continuation?.resume(throwing: waiter.failure ?? CancellationError())
                    }
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Whether a task left from an earlier run, started with `leftover`, fetches as `wanted` would:
    /// the same server address (scheme, host, port) and the same mobile-data rule. A task started at
    /// home, or as Wi-Fi only, would otherwise be joined away from home or on mobile data, and wait.
    nonisolated static func canJoin(_ leftover: URLRequest?, as wanted: URLRequest) -> Bool {
        guard let leftover, let old = leftover.url, let new = wanted.url else { return false }
        return old.scheme?.lowercased() == new.scheme?.lowercased()
            && old.host()?.lowercased() == new.host()?.lowercased()
            && old.port == new.port
            && leftover.allowsCellularAccess == wanted.allowsCellularAccess
    }

    func cancelTasks(under folder: URL) {
        let prefix = key(for: folder) + "/"
        let gone = lock.withLock {
            let gone = leftovers.filter { $0.key.hasPrefix(prefix) }
            gone.keys.forEach { leftovers[$0] = nil }
            return Array(gone.values)
        }
        gone.forEach { $0.cancel() }
        // The ones under way this run too, and any left from before that aren't read yet.
        session.getAllTasks { [self] tasks in
            for task in tasks where task.taskDescription.map({ key(description: $0).hasPrefix(prefix) }) == true {
                task.cancel()
            }
        }
    }

    func cancelUnclaimedLeftovers() {
        Task {
            await leftoversReady()
            let unclaimed = lock.withLock {
                defer { leftovers = [:] }
                return Array(leftovers.values)
            }
            unclaimed.forEach { $0.cancel() }
        }
    }

    private func leftoversReady() async {
        let isRead = lock.withLock { leftoversRead }
        if isRead { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if leftoversRead { return true }
                leftoverReaders.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        var failure: (any Error)?
        var placed = false
        if !(200..<300).contains(status) {
            failure = DownloadError.badStatus(status)
        } else if let description = downloadTask.taskDescription {
            // The file must move before this returns.
            let destination = self.destination(description: description)
            let folder = destination.deletingLastPathComponent()
            let manager = FileManager.default
            do {
                // The server's own folder (`<server>/songs/`'s) is made only by the app: gone, its downloads
                // were deleted (Delete All, logout, the server removed), and this file mustn't bring it back.
                guard manager.fileExists(atPath: folder.deletingLastPathComponent().path) else { throw CancellationError() }
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                try? manager.removeItem(at: destination)
                try manager.moveItem(at: location, to: destination)
                placed = true
            } catch {
                failure = error
            }
        }
        lock.withLock {
            waiters[downloadTask.taskIdentifier, default: Waiter()].failure = failure
            waiters[downloadTask.taskIdentifier]?.placed = placed
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = lock.withLock { waiters[downloadTask.taskIdentifier]?.progress }
        progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let waiter = lock.withLock { waiters.removeValue(forKey: task.taskIdentifier) }
        let failure: (any Error)? = if let error {
            (error as? URLError)?.code == .cancelled ? CancellationError() : error
        } else {
            waiter?.failure
        }
        // A task that never moved its file has nothing of its own there to delete.
        if failure != nil, waiter?.placed == true, let description = task.taskDescription {
            try? FileManager.default.removeItem(at: destination(description: description))
        }
        guard let continuation = waiter?.continuation else { return }
        if let failure {
            continuation.resume(throwing: failure)
        } else {
            continuation.resume()
        }
    }

    /// A server that asks for the device's certificate gets it (C45). Every other challenge, and a server
    /// without a certificate here, gets the system's default, as before. Kept for the session
    /// (`.forSession`): the system runs this session's connections while the app is suspended.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let (disposition, credential) = DeviceCertificates.shared.answer(challenge, persistence: .forSession)
        completionHandler(disposition, credential)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in self.eventsFinished() }
    }
}

/// Hands iOS's background-session relaunch to the downloader.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundDownloader.identifier else {
            completionHandler()
            return
        }
        BackgroundDownloader.shared.handleEvents(completion: completionHandler)
    }
}

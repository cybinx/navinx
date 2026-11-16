import Foundation
import Synchronization
import SubsonicKit
@testable import PlaybackKit

/// An engine that does nothing but record, so tests drive the player by sending its events.
@MainActor
final class FakeEngine: AudioEngine {
    var onEvent: (@MainActor (AudioEngineEvent) -> Void)?
    var hasItem = false
    var volume: Float = 1

    private(set) var loaded: [URL] = []
    private(set) var loadStarts: [TimeInterval] = []
    private(set) var next: URL?
    private(set) var nextChanges = 0
    private(set) var isPlaying = false
    private(set) var seeks: [TimeInterval] = []
    private(set) var stops = 0
    private(set) var advances = 0
    private(set) var rate: Float = 1
    private(set) var preservesPitch = true
    private(set) var rateChanges = 0
    /// The overlap the next item was lined up with (nil: gapless).
    private(set) var crossfade: Crossfade?
    /// The fade each `play` and `pause` asked for, in order.
    private(set) var playFades: [TimeInterval] = []
    private(set) var pauseFades: [TimeInterval] = []

    func load(_ url: URL, start: TimeInterval, next: URL?) {
        loaded.append(url)
        loadStarts.append(start)
        self.next = next
        crossfade = nil
        hasItem = true
        isPlaying = false
    }

    func setNext(_ url: URL?, crossfade: Crossfade?) {
        next = url
        self.crossfade = url == nil ? nil : crossfade
        nextChanges += 1
    }

    /// What `advanceToNext` reports: the handover, another event, or (nil) nothing at all.
    var advanceEvent: AudioEngineEvent? = .advanced

    func advanceToNext() {
        advances += 1
        if let advanceEvent { send(advanceEvent) }
    }

    /// The queued item is used up by a handover, as in the real engine.
    func send(_ event: AudioEngineEvent) {
        if event == .advanced {
            next = nil
            crossfade = nil
        }
        onEvent?(event)
    }

    func play(fadeIn: TimeInterval) {
        isPlaying = true
        playFades.append(fadeIn)
    }

    func pause(fadeOut: TimeInterval) {
        isPlaying = false
        pauseFades.append(fadeOut)
    }

    func stop() {
        stops += 1
        hasItem = false
        next = nil
        crossfade = nil
        isPlaying = false
    }

    func seek(to seconds: TimeInterval) { seeks.append(seconds) }

    func setRate(_ rate: Float, preservesPitch: Bool) {
        self.rate = rate
        self.preservesPitch = preservesPitch
        rateChanges += 1
    }

    /// A song has started making sound.
    func startSounding() { send(.buffering(false)) }

    /// The player's own clock (C20); nil like an engine that can't say.
    var clock: TimeInterval?
    var currentTime: TimeInterval? { clock }

    var loadedSongIDs: [String] { loaded.map(\.songID) }
    var nextSongID: String? { next?.songID }
}

extension URL {
    var params: [String: String] {
        let items = URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }

    var songID: String { params["id"] ?? "" }
}

/// A server that says OK (or fails, on demand) and records every call.
final class FakeServer: HTTPTransport {
    private struct State {
        var requests: [URL] = []
        var isFailing = false
        var songLists: [String: (key: String, ids: [String])] = [:]
        var payloads: [String: String] = [:]
        var held: Set<String> = []
        var waiting: [CheckedContinuation<Bool, Never>] = []
    }

    private let state = Mutex(State())

    var requests: [URL] { state.withLock { $0.requests } }

    /// Makes `endpoint` answer with these songs under `key`.
    func stubSongs(_ endpoint: String, key: String, ids: [String]) {
        state.withLock { $0.songLists[endpoint] = (key, ids) }
    }

    /// Makes `endpoint` answer with this JSON after the status, such as
    /// `,"albumList2":{"album":[{"id":"al","name":"A"}]}`.
    func stubPayload(_ endpoint: String, _ json: String) {
        state.withLock { $0.payloads[endpoint] = json }
    }

    func setFailing(_ isFailing: Bool) {
        state.withLock { $0.isFailing = isFailing }
    }

    /// Makes calls to `endpoint` wait until `release` lets them answer, one at a time.
    func hold(_ endpoint: String) {
        state.withLock { _ = $0.held.insert(endpoint) }
    }

    /// How many held calls are waiting.
    var waitingCount: Int { state.withLock { $0.waiting.count } }

    /// Lets the oldest held call answer, OK or failing.
    func release(failing: Bool = false) {
        let next = state.withLock { $0.waiting.isEmpty ? nil : $0.waiting.removeFirst() }
        next?.resume(returning: failing)
    }

    func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let (isFailing, list, raw, isHeld) = state.withLock { state in
            state.requests.append(url)
            return (
                state.isFailing, state.songLists[url.lastPathComponent], state.payloads[url.lastPathComponent],
                state.held.contains(url.lastPathComponent)
            )
        }
        if isFailing { throw URLError(.cannotConnectToHost) }
        if isHeld {
            let fails = await withCheckedContinuation { continuation in
                state.withLock { $0.waiting.append(continuation) }
            }
            if fails { throw URLError(.cannotConnectToHost) }
        }
        var payload = raw ?? ""
        if raw == nil, let list {
            let songs = list.ids.map { #"{"id":"\#($0)","title":"Song \#($0)"}"# }.joined(separator: ",")
            payload = #","\#(list.key)":{"song":[\#(songs)]}"#
        }
        let body = #"{"subsonic-response":{"status":"ok","version":"1.16.1"\#(payload)}}"#
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), response)
    }

    /// `"<song>:<submission>"` for each scrobble call, in order.
    var scrobbles: [String] {
        requests
            .filter { $0.lastPathComponent == "scrobble" }
            .map { "\($0.songID):\($0.params["submission"] ?? "")" }
    }

    func calls(to endpoint: String) -> [URL] {
        requests.filter { $0.lastPathComponent == endpoint }
    }
}

/// A clock tests move by hand.
@MainActor
final class TestClock {
    private(set) var date = Date(timeIntervalSince1970: 1_000_000)

    func advance(_ seconds: TimeInterval) {
        date += seconds
    }
}

func song(_ id: String, duration: Int? = 200) -> Song {
    Song(id: id, title: "Song \(id)", duration: duration)
}

func songs(_ ids: String...) -> [Song] {
    ids.map { song($0) }
}

/// A player with a fake engine and server, and its own settings and queue file.
@MainActor
struct Rig {
    let player: PlayerModel
    let engine: FakeEngine
    let server: FakeServer
    let clock: TestClock
    let defaults: UserDefaults
    let queueFile: URL

    init(defaults: UserDefaults? = nil, queueFile: URL? = nil, connects: Bool = true, profileID: String = "profile") throws {
        let defaults = defaults ?? UserDefaults(suiteName: "PlaybackKitTests-\(UUID().uuidString)")!
        let queueFile = queueFile ?? FileManager.default.temporaryDirectory
            .appending(path: "PlaybackKitTests-\(UUID().uuidString)/queue.json")
        let engine = FakeEngine()
        let clock = TestClock()
        self.engine = engine
        self.clock = clock
        self.defaults = defaults
        self.queueFile = queueFile
        server = FakeServer()
        player = PlayerModel(engine: engine, defaults: defaults, queueFile: queueFile, now: { clock.date })
        if connects {
            player.connect(client: try makeClient(server: server), profileID: profileID)
        }
    }
}

func makeClient(server: FakeServer) throws -> SubsonicClient {
    try SubsonicClient(
        config: ServerConfig(serverURL: "music.example.com", username: "demo", password: "demo"),
        coverArtSalt: "stablesalt123456",
        transport: server
    )
}

/// Waits for background work (a scrobble, a save) to land.
@MainActor
func eventually(_ timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

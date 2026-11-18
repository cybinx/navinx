import Foundation
import Testing
@testable import PlaybackKit

/// C68 (D225): a song that failed for a network reason is loaded again where it stopped once the
/// network is back, and plays; a few times at most, within a few minutes, and never once called off.
@MainActor
@Suite struct StreamRecoveryTests {
    /// Whether the network is there, as the app's `NetworkMonitor` says.
    @MainActor final class Network {
        var isUp = false
    }

    private func makeRig(_ network: Network) throws -> Rig {
        let rig = try Rig()
        rig.player.isNetworkAvailable = { network.isUp }
        rig.player.recoveryWaits = (.milliseconds(5), .milliseconds(5))
        return rig
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(60))
    }

    @Test func theDecisions() {
        var recovery = StreamRecovery()
        let start = Date(timeIntervalSince1970: 0)
        func fails(_ entry: UUID, at position: TimeInterval = 10, playing: Bool = true, network: Bool = true) -> Bool {
            recovery.failed(entry: entry, at: position, wasPlaying: playing, isNetwork: network, now: start)
        }
        func reload(_ entry: UUID, after seconds: TimeInterval = 0) -> StreamRecovery.Plan? {
            recovery.attempt(current: entry, now: start + seconds)
        }
        let entry = UUID()
        // Not the network's, or not playing: stopped, as before.
        #expect(!fails(entry, network: false))
        #expect(!fails(entry, playing: false))
        // Three reloads of one place, then it stays stopped.
        for _ in 0..<StreamRecovery.attemptLimit {
            #expect(fails(entry))
            #expect(reload(entry)?.position == 10)
        }
        #expect(!fails(entry))
        // Another song has its own; 30 s played after a reload counts afresh.
        let other = UUID()
        #expect(fails(other, at: 0))
        #expect(reload(other) != nil)
        recovery.played(other, to: 29)
        #expect(fails(other, at: 29))
        #expect(reload(other) != nil)
        recovery.played(other, to: 29 + StreamRecovery.playedToForgive)
        for _ in 0..<StreamRecovery.attemptLimit {
            #expect(fails(other, at: 60))
            #expect(reload(other) != nil)
        }
        // Too late, or another song current: no reload.
        let late = UUID()
        #expect(fails(late))
        #expect(reload(late, after: StreamRecovery.waitLimit + 1) == nil)
        #expect(fails(late))
        #expect(reload(UUID()) == nil)
        #expect(!recovery.isWaiting)
    }

    @Test func aSongLostWithTheNetworkPlaysAgainWhereItStopped() async throws {
        let network = Network()
        let rig = try makeRig(network)
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.engine.send(.position(42))
        rig.engine.send(.playing(false))
        rig.engine.send(.failed("Lost", isNetwork: true))
        // It shows as the network falling behind, not stopped.
        #expect(rig.player.isPlaying && rig.player.isLoading)
        try await settle()
        #expect(rig.engine.loaded.count == 1)
        network.isUp = true
        rig.player.networkReturned()
        #expect(await eventually { rig.engine.loaded.count == 2 })
        #expect(rig.engine.loadedSongIDs == ["a", "a"] && rig.engine.loadStarts.last == 42)
        #expect(rig.engine.isPlaying && rig.player.isPlaying)
    }

    @Test func aFailureForAnotherReasonOrWithTheNetworkUpStopsOrRetries() async throws {
        let network = Network()
        network.isUp = true
        let rig = try makeRig(network)
        rig.player.playSong(song("a"))
        // Not the network's: stopped, as before.
        rig.engine.send(.failed("No"))
        #expect(!rig.player.isPlaying)
        rig.player.play()
        // The network's with a network there (the feed gave up): tried again after a moment.
        rig.engine.send(.failed("Lost", isNetwork: true))
        #expect(await eventually { rig.engine.loaded.count == 3 })
        #expect(rig.player.isPlaying)
    }

    @Test func itGivesUpAfterThreeReloads() async throws {
        let network = Network()
        network.isUp = true
        let rig = try makeRig(network)
        rig.player.playSong(song("a"))
        for reload in 1...StreamRecovery.attemptLimit {
            rig.engine.send(.failed("Lost", isNetwork: true))
            #expect(await eventually { rig.engine.loaded.count == 1 + reload })
        }
        rig.engine.send(.failed("Lost", isNetwork: true))
        #expect(!rig.player.isPlaying && !rig.player.isLoading)
        try await settle()
        #expect(rig.engine.loaded.count == 1 + StreamRecovery.attemptLimit)
    }

    @Test func aNetworkBackTooLateLeavesItStopped() async throws {
        let network = Network()
        let rig = try makeRig(network)
        rig.player.playSong(song("a"))
        rig.engine.send(.failed("Lost", isNetwork: true))
        rig.clock.advance(StreamRecovery.waitLimit + 1)
        network.isUp = true
        rig.player.networkReturned()
        #expect(await eventually { !rig.player.isPlaying })
        #expect(!rig.player.isLoading && rig.engine.loaded.count == 1)
    }

    @Test func pauseSkipStopAndAnotherServerCallItOff() async throws {
        let network = Network()
        let rig = try makeRig(network)
        rig.player.playSong(song("a"), playlist: songs("a", "b"))

        rig.engine.send(.failed("Lost", isNetwork: true))
        rig.player.pause()
        #expect(!rig.player.isPlaying && !rig.player.isLoading)
        rig.player.networkReturned()
        try await settle()
        #expect(rig.engine.loaded.count == 1)

        // Play after a failure loads it again, as before; then a skip while it waits.
        rig.player.play()
        rig.engine.send(.failed("Lost", isNetwork: true))
        rig.player.skipNext()
        rig.player.networkReturned()
        try await settle()
        // The lined-up song took over (the gapless change); "a" isn't loaded again.
        #expect(rig.player.currentSong?.id == "b" && rig.engine.loadedSongIDs == ["a", "a"])

        rig.engine.send(.failed("Lost", isNetwork: true))
        rig.player.stop()
        rig.player.networkReturned()
        try await settle()
        #expect(rig.engine.loaded.count == 2)

        rig.player.play()
        #expect(rig.engine.loadedSongIDs == ["a", "a", "b"])
        rig.engine.send(.failed("Lost", isNetwork: true))
        rig.player.reset()
        rig.player.networkReturned()
        try await settle()
        #expect(rig.engine.loaded.count == 3 && !rig.player.isPlaying)
    }

    /// The app's own engine: the failure comes from the child playing, the reload goes to it.
    @Test func theCrossfadeEngineIsLoadedAgainToo() async throws {
        let children = [FakeEngine(), FakeEngine()]
        let engine = CrossfadeEngine(children: children, step: .milliseconds(5))
        let player = PlayerModel(
            engine: engine, defaults: UserDefaults(suiteName: "PlaybackKitTests-\(UUID().uuidString)")!,
            queueFile: FileManager.default.temporaryDirectory.appending(path: "PlaybackKitTests-\(UUID().uuidString)/queue.json")
        )
        player.connect(client: try makeClient(server: FakeServer()), profileID: "profile")
        let network = Network()
        player.isNetworkAvailable = { network.isUp }
        player.recoveryWaits = (.milliseconds(5), .milliseconds(5))
        player.playSong(song("a"), playlist: songs("a", "b"))
        children[0].send(.playing(true))
        children[0].send(.position(42))
        children[0].send(.failed("Lost"))
        #expect(player.isPlaying && player.isLoading)
        network.isUp = true
        player.networkReturned()
        #expect(await eventually { children[0].loaded.count == 2 })
        #expect(children[0].loadedSongIDs == ["a", "a"] && children[0].loadStarts.last == 42 && children[0].isPlaying)
    }
}

import Foundation
import SubsonicKit
import Testing
@testable import PlaybackKit

/// C36 (D143): the queue kept on the server, and another device's taken while nothing plays.
@MainActor
@Suite struct QueueSyncTests {
    // MARK: Taking or keeping

    private let a = QueueSnapshot(songIDs: ["1", "2"], currentID: "1", positionMs: 10_000)
    private let b = QueueSnapshot(songIDs: ["3", "4"], currentID: "4", positionMs: 5_000)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func decide(server: QueueSnapshot?, changed: Date? = nil, local: QueueSnapshot?, mark: QueueSnapshot?, here: Date? = nil) -> QueueSyncDecision {
        QueueSyncDecision.decide(
            server: server.map { ($0, changed) }, local: local,
            record: QueueSyncRecord(mark: mark, changedHereAt: here)
        )
    }

    @Test func theSameQueueOnBothSidesIsInSync() {
        let later = QueueSnapshot(songIDs: ["1", "2"], currentID: "1", positionMs: 11_500)
        #expect(decide(server: a, local: later, mark: nil) == .inSync)
    }

    @Test func aPhoneThatWasTheLastToSaveTakesNothingAndSendsItsNewerOne() {
        #expect(decide(server: a, local: b, mark: a) == .send)
        #expect(decide(server: a, local: b, mark: a, here: t0) == .send)
    }

    @Test func aQueueChangedOnlyElsewhereIsTaken() {
        #expect(decide(server: b, local: a, mark: a) == .take(announces: true))
    }

    @Test func whenBothChangedTheMostRecentlyPlayedWins() {
        #expect(decide(server: b, changed: t0 + 60, local: a, mark: a, here: t0) == .take(announces: true))
        #expect(decide(server: b, changed: t0 - 60, local: a, mark: a, here: t0) == .send)
        #expect(decide(server: b, changed: nil, local: a, mark: a, here: t0) == .send)
    }

    @Test func anEmptyPhoneTakesTheServersQueueAndAnnouncesOnlyAnotherDevicesOne() {
        #expect(decide(server: b, local: nil, mark: nil) == .take(announces: true))
        #expect(decide(server: b, local: nil, mark: a) == .take(announces: true))
        // A server switched away and back: its own queue comes back quietly.
        #expect(decide(server: a, local: nil, mark: a) == .take(announces: false))
    }

    @Test func theFirstRunKeepsThisPhonesQueue() {
        #expect(decide(server: b, local: a, mark: nil) == .send)
        #expect(decide(server: nil, local: a, mark: nil) == .send)
    }

    @Test func nothingSavedSendsOnlyWhatTheServerNeverHad() {
        #expect(decide(server: nil, local: a, mark: a) == .nothing)
        #expect(decide(server: nil, local: a, mark: a, here: t0) == .send)
        #expect(decide(server: nil, local: nil, mark: a) == .nothing)
    }

    /// C46 (D163): "changed here" is the time of the change, not of the last save.
    @Test func theSameUnsentChangeSavedAgainKeepsItsTime() {
        var record = QueueSyncRecord(mark: a)
        record.note(b, at: t0)
        // The app leaving the foreground, then coming back two hours later: the same queue.
        record.note(b, at: t0 + 60)
        record.note(b, at: t0 + 7200)
        #expect(record.changedHereAt == t0)
        // Played on: a new change, a new time.
        let playedOn = QueueSnapshot(songIDs: ["3", "4"], currentID: "4", positionMs: 90_000)
        record.note(playedOn, at: t0 + 7300)
        #expect(record.changedHereAt == t0 + 7300)
        // Back at what the server holds: nothing is unsent.
        record.note(a, at: t0 + 7400)
        #expect(record == QueueSyncRecord(mark: a))
        // A record from before C46 has a time and no queue beside it: the time is kept.
        var older = QueueSyncRecord(mark: a, changedHereAt: t0)
        older.note(b, at: t0 + 7200)
        #expect(older.changedHereAt == t0 && older.changedSnapshot == b)
    }

    /// A pause's fade-out moves the place after the pause was sent: within 2 s it's the same queue.
    @Test func thePlaceHasTwoSecondsOfTolerance() {
        let faded = QueueSnapshot(songIDs: ["1", "2"], currentID: "1", positionMs: 11_900)
        let moved = QueueSnapshot(songIDs: ["1", "2"], currentID: "1", positionMs: 12_100)
        #expect(a.matches(faded) && !a.matches(moved))
        #expect(QueueSnapshot.hash(["1", "2"]) != QueueSnapshot.hash(["12"]))
    }

    @Test func aLongQueueSendsAThousandSongsAroundTheCurrentOne() {
        #expect(PlayerModel.serverWindow(count: 50, current: 10) == 0..<50)
        #expect(PlayerModel.serverWindow(count: 5000, current: 2000) == 1900..<2900)
        #expect(PlayerModel.serverWindow(count: 5000, current: 30) == 0..<1000)
        #expect(PlayerModel.serverWindow(count: 5000, current: 4990) == 4000..<5000)
    }

    // MARK: The player

    private func queueJSON(_ ids: [String], current: String, positionMs: Int) -> String {
        let entries = ids.map { #"{"id":"\#($0)","title":"Song \#($0)","duration":200}"# }.joined(separator: ",")
        return #","playQueue":{"entry":[\#(entries)],"current":"\#(current)","position":\#(positionMs),"username":"demo","changed":"2026-11-13T18:00:00.123456789Z","changedBy":"Navinx"}"#
    }

    private func sent(_ rig: Rig) -> [URL] { rig.server.calls(to: "savePlayQueue") }

    @Test func leavingTheForegroundSendsTheQueueAndAnUnchangedOneOnlyOnce() async throws {
        let rig = try Rig()
        rig.player.playInOrder(songs("a", "b", "c"))
        rig.player.skipNext()
        rig.player.pause()
        rig.player.seek(to: 42.5)
        rig.player.saveNow()
        #expect(await eventually { sent(rig).count == 1 })
        let url = try #require(sent(rig).first)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.filter { $0.name == "id" }.map(\.value) == ["a", "b", "c"])
        #expect(url.params["current"] == "b" && url.params["position"] == "42500")
        // The app going inactive, then to the background: nothing new, nothing sent.
        rig.player.saveNow()
        try await Task.sleep(for: .milliseconds(1300))
        #expect(sent(rig).count == 1)
    }

    @Test func theKeptSongOfflineAndTheSwitchOffSendNothing() async throws {
        let placeholder = try Rig(connects: false)
        placeholder.server.stubPayload("getAlbumList2", #","albumList2":{"album":[{"id":"al","name":"A"}]}"#)
        placeholder.server.stubPayload("getAlbum", #","album":{"id":"al","name":"A","song":[{"id":"s1","title":"S"}]}"#)
        placeholder.player.connect(client: try makeClient(server: placeholder.server), profileID: "profile")
        #expect(await eventually { placeholder.player.currentSong?.id == "s1" })
        placeholder.player.saveNow()

        let offline = try Rig(connects: false)
        offline.player.connectOffline(profileID: "profile")
        offline.player.localFile = { URL(filePath: "/tmp/\($0.id).mp3") }
        offline.player.playInOrder(songs("a"))
        offline.player.pause()
        offline.player.saveNow()

        let switchedOff = try Rig()
        switchedOff.defaults.set(false, forKey: QueueSyncSettings.enabledKey)
        switchedOff.player.playInOrder(songs("a"))
        switchedOff.player.pause()
        switchedOff.player.saveNow()

        try await Task.sleep(for: .milliseconds(1300))
        #expect(sent(placeholder).isEmpty && offline.server.requests.isEmpty && sent(switchedOff).isEmpty)
        // Offline, the change is noted for the next look.
        let store = PlayerStore(defaults: offline.defaults, queueFile: offline.queueFile)
        #expect(store.queueSyncRecord(profileID: "profile").changedHereAt != nil)
    }

    @Test func anotherDevicesQueueIsTakenPausedAtItsPlaceWithTheToast() async throws {
        let rig = try Rig(connects: false)
        rig.server.stubPayload("getPlayQueue", queueJSON(["x", "y", "z"], current: "y", positionMs: 61_234))
        var toasts = 0
        rig.player.onQueueTaken = { toasts += 1 }
        rig.player.connect(client: try makeClient(server: rig.server), profileID: "profile")
        #expect(await eventually { rig.player.currentSong?.id == "y" })
        #expect(rig.player.queue.map(\.id) == ["x", "y", "z"])
        #expect(rig.player.position == 61.234 && !rig.player.isPlaying)
        #expect(rig.engine.loaded.isEmpty && rig.server.scrobbles.isEmpty)
        #expect(toasts == 1)
        // Play starts it where it was.
        rig.player.play()
        #expect(rig.engine.loadedSongIDs == ["y"] && rig.engine.loadStarts == [61.234])
    }

    /// This phone's queue reaches the server (the mark), then its place moves offline at the clock's
    /// time and the server never hears of it. Returns the store, to read the record.
    private func changeOffline(_ rig: Rig) async throws -> PlayerStore {
        let store = PlayerStore(defaults: rig.defaults, queueFile: rig.queueFile)
        rig.player.playInOrder(songs("a", "b", "c"))
        rig.engine.startSounding()
        rig.player.pause()
        rig.player.saveNow()
        #expect(await eventually { store.queueSyncRecord(profileID: "profile").mark != nil })
        rig.player.connectOffline(profileID: "profile")
        rig.player.seek(to: 120)
        rig.player.saveNow()
        #expect(store.queueSyncRecord(profileID: "profile").changedHereAt == rig.clock.date)
        return store
    }

    /// C46 (D163): the phone that played last wins, not the one opened last. The stub's queue was
    /// changed on 2026-11-13; the test clock starts in 1970.
    @Test func anOlderUnsentChangeLooksFirstAndGivesWayToADeviceThatPlayedLater() async throws {
        let rig = try Rig()
        let store = try await changeOffline(rig)
        // Two hours on, the app comes back online. The save on the way in sends nothing blind: it
        // looks, finds another device played since, and takes its queue.
        rig.clock.advance(7200)
        rig.server.stubPayload("getPlayQueue", queueJSON(["x", "y"], current: "y", positionMs: 30_000))
        rig.player.connect(client: try makeClient(server: rig.server), profileID: "profile", checksServerQueue: false)
        rig.player.saveNow()
        #expect(await eventually { rig.player.currentSong?.id == "y" })
        #expect(sent(rig).count == 1)
        #expect(store.queueSyncRecord(profileID: "profile").changedHereAt == nil)
    }

    @Test func anOlderUnsentChangeIsStillSentWhenNobodyPlayedSince() async throws {
        let rig = try Rig()
        // This phone's clock is past the stub's 2026-11-13: its change is the later one.
        rig.clock.advance(1_800_000_000)
        _ = try await changeOffline(rig)
        rig.clock.advance(7200)
        rig.server.stubPayload("getPlayQueue", queueJSON(["x", "y"], current: "y", positionMs: 30_000))
        let looks = rig.server.calls(to: "getPlayQueue").count
        rig.player.connect(client: try makeClient(server: rig.server), profileID: "profile", checksServerQueue: false)
        rig.player.saveNow()
        // It looks first, then sends.
        #expect(await eventually { sent(rig).count == 2 })
        #expect(rig.server.calls(to: "getPlayQueue").count == looks + 1)
        #expect(rig.player.queue.map(\.id) == ["a", "b", "c"] && sent(rig).last?.params["position"] == "120000")
    }

    /// Re-check item 19 (2026-11-15): the 30 s saves while playing went to the server only, so a phone
    /// killed while playing came back at an older place than the server's and sent that one over it.
    @Test func aPhoneKilledWhilePlayingComesBackAtTheServersPlaceAndSendsNothingOlder() async throws {
        let rig = try Rig()
        let store = PlayerStore(defaults: rig.defaults, queueFile: rig.queueFile)
        rig.player.playInOrder(songs("a", "b"))
        rig.engine.startSounding()
        #expect(await eventually { sent(rig).count == 1 })
        rig.clock.advance(31)
        rig.engine.send(.position(100))
        #expect(await eventually { sent(rig).last?.params["position"] == "100000" })
        #expect(await eventually {
            store.queueSyncRecord(profileID: "profile").mark?.positionMs == 100_000 && store.loadQueue()?.position == 100
        })
        // Killed here, with no save on the way out. The next launch reads its own file, then the server.
        let relaunch = try Rig(defaults: rig.defaults, queueFile: rig.queueFile, connects: false)
        relaunch.server.stubPayload("getPlayQueue", queueJSON(["a", "b"], current: "a", positionMs: 100_000))
        relaunch.player.connect(client: try makeClient(server: relaunch.server), profileID: "profile")
        #expect(await eventually { relaunch.server.calls(to: "getPlayQueue").count == 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(sent(relaunch).isEmpty)
        #expect(relaunch.player.currentSong?.id == "a" && relaunch.player.position == 100)
    }

    @Test func playingHereIsNeverInterrupted() async throws {
        // The look at sign-in is under way when a song starts: what it finds is dropped.
        let rig = try Rig(connects: false)
        rig.server.stubPayload("getPlayQueue", queueJSON(["x", "y"], current: "y", positionMs: 1_000))
        rig.server.hold("getPlayQueue")
        rig.player.connect(client: try makeClient(server: rig.server), profileID: "profile")
        #expect(await eventually { rig.server.waitingCount == 1 })
        rig.player.playInOrder(songs("a", "b"))
        rig.server.release()
        // And no look starts while playing.
        rig.player.checkServerQueue()
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.server.calls(to: "getPlayQueue").count == 1)
        #expect(rig.player.queue.map(\.id) == ["a", "b"] && rig.player.isPlaying)
    }
}

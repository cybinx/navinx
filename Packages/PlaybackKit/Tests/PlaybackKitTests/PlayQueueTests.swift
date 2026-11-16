import Testing
import SubsonicKit
@testable import PlaybackKit

private func ids(_ queue: PlayQueue) -> [String] { queue.songs.map(\.id) }

@Suite struct PlayQueueOrderTests {
    @Test func loadStartsAtTheGivenSong() {
        var queue = PlayQueue()
        queue.load(songs("a", "b", "c"), startIndex: 1)
        #expect(ids(queue) == ["a", "b", "c"])
        #expect(queue.current?.id == "b")
    }

    @Test func aStartPastTheEndIsClamped() {
        var queue = PlayQueue()
        queue.load(songs("a", "b"), startIndex: 9)
        #expect(queue.currentIndex == 1)
    }

    @Test func loadingNothingClears() {
        var queue = PlayQueue()
        queue.load(songs("a"))
        queue.load([])
        #expect(queue.isEmpty && queue.current == nil && queue.currentIndex == -1)
    }

    @Test func indexAfterEndFollowsTheRepeatMode() {
        var queue = PlayQueue()
        queue.load(songs("a", "b"))
        #expect(queue.indexAfterEnd(repeat: .off) == 1)
        #expect(queue.indexAfterEnd(repeat: .one) == 0)
        queue.move(to: 1)
        #expect(queue.indexAfterEnd(repeat: .off) == nil)
        #expect(queue.indexAfterEnd(repeat: .all) == 0)
        #expect(queue.indexAfterEnd(repeat: .one) == 1)
    }

    @Test func nextIgnoresRepeatOne() {
        var queue = PlayQueue()
        queue.load(songs("a", "b"))
        #expect(queue.indexForNext(repeat: .one) == 1)
        queue.move(to: 1)
        #expect(queue.indexForNext(repeat: .one) == nil)
        #expect(queue.indexForNext(repeat: .off) == nil)
        #expect(queue.indexForNext(repeat: .all) == 0)
    }

    @Test func previousWrapsOnlyOnRepeatAll() {
        var queue = PlayQueue()
        queue.load(songs("a", "b", "c"), startIndex: 1)
        #expect(queue.indexForPrevious(repeat: .off) == 0)
        queue.move(to: 0)
        #expect(queue.indexForPrevious(repeat: .off) == nil)
        #expect(queue.indexForPrevious(repeat: .one) == nil)
        #expect(queue.indexForPrevious(repeat: .all) == 2)
    }

    @Test func anEmptyQueueHasNowhereToGo() {
        let queue = PlayQueue()
        #expect(queue.indexForNext(repeat: .all) == nil)
        #expect(queue.indexForPrevious(repeat: .all) == nil)
        #expect(queue.indexAfterEnd(repeat: .one) == nil)
    }

    @Test func theRepeatButtonCycles() {
        #expect(RepeatMode.off.next == .all)
        #expect(RepeatMode.all.next == .one)
        #expect(RepeatMode.one.next == .off)
    }
}

/// D23: like Apple Music.
@Suite struct PlayQueueShuffleTests {
    private let list = songs("a", "b", "c", "d", "e", "f", "g", "h")

    @Test func shuffleKeepsTheCurrentSongAndEverySong() {
        var queue = PlayQueue()
        queue.load(list, startIndex: 3)
        queue.setShuffle(true)
        #expect(queue.current?.id == "d")
        #expect(queue.currentIndex == 0)
        #expect(Set(ids(queue)) == Set(list.map(\.id)))
        #expect(queue.count == list.count)
    }

    @Test func nextFollowsTheShuffledOrder() {
        var queue = PlayQueue()
        queue.load(list)
        queue.setShuffle(true)
        let order = ids(queue)
        var walked = [queue.current!.id]
        while let index = queue.indexForNext(repeat: .off) {
            queue.move(to: index)
            walked.append(queue.current!.id)
        }
        #expect(walked == order)
    }

    @Test func shuffleOffBringsTheOriginalOrderBackAroundTheCurrentSong() {
        var queue = PlayQueue()
        queue.load(list, startIndex: 2)
        queue.setShuffle(true)
        queue.move(to: 3)
        let playing = queue.current!.id
        queue.setShuffle(false)
        #expect(ids(queue) == list.map(\.id))
        #expect(queue.current?.id == playing)
    }

    @Test func aNewListStartsShuffledAroundTheTappedSong() {
        var queue = PlayQueue(isShuffled: true)
        queue.load(list, startIndex: 5)
        #expect(queue.current?.id == "f")
        #expect(queue.currentIndex == 0)
        #expect(queue.originalSongs.map(\.id) == list.map(\.id))
    }

    @Test func theSwitchRemembersWithNothingLoaded() {
        var queue = PlayQueue()
        queue.setShuffle(true)
        #expect(queue.isShuffled && queue.isEmpty)
        queue.load(list)
        #expect(queue.originalSongs.map(\.id) == list.map(\.id))
    }

    @Test func playInOrderTurnsShuffleOff() {
        var queue = PlayQueue(isShuffled: true)
        queue.loadInOrder(list)
        #expect(!queue.isShuffled)
        #expect(ids(queue) == list.map(\.id))
        #expect(queue.current?.id == "a")
    }

    @Test func playShuffledTurnsShuffleOnAndCanStartAnywhere() {
        var firsts = Set<String>()
        for _ in 0..<60 {
            var queue = PlayQueue()
            queue.loadShuffled(list)
            #expect(queue.isShuffled)
            #expect(queue.currentIndex == 0)
            #expect(Set(ids(queue)) == Set(list.map(\.id)))
            firsts.insert(queue.current!.id)
        }
        #expect(firsts.count > 1)
    }

    @Test func aSongAddedWhileShuffledStaysAfterShuffleOff() {
        var queue = PlayQueue()
        queue.load(list)
        queue.setShuffle(true)
        queue.append([song("z")])
        #expect(ids(queue).last == "z")
        queue.setShuffle(false)
        #expect(ids(queue) == list.map(\.id) + ["z"])
    }

    @Test func playNextStaysNextInBothOrders() {
        var queue = PlayQueue()
        queue.load(list, startIndex: 2)
        queue.setShuffle(true)
        queue.insertNext(song("z"))
        #expect(queue.songs[queue.currentIndex + 1].id == "z")
        queue.setShuffle(false)
        #expect(queue.current?.id == "c")
        #expect(queue.songs[queue.currentIndex + 1].id == "z")
    }

    @Test func aSongRemovedWhileShuffledStaysGoneAfterShuffleOff() {
        var queue = PlayQueue()
        queue.load(list)
        queue.setShuffle(true)
        let removed = queue.songs[3].id
        queue.remove(at: 3)
        queue.setShuffle(false)
        #expect(!ids(queue).contains(removed))
        #expect(queue.count == list.count - 1)
    }

    @Test func theSameSongTwiceKeepsItsPlace() {
        var queue = PlayQueue()
        queue.load(songs("a", "b", "a", "c"), startIndex: 2)
        queue.setShuffle(true)
        queue.setShuffle(false)
        #expect(queue.currentIndex == 2)
    }
}

@Suite struct PlayQueueEditingTests {
    @Test func appendGoesLast() {
        var queue = PlayQueue()
        queue.load(songs("a", "b"))
        queue.append(songs("c", "d"))
        #expect(ids(queue) == ["a", "b", "c", "d"])
        #expect(queue.current?.id == "a")
    }

    @Test func appendToAnEmptyQueueGivesItACurrentSong() {
        var queue = PlayQueue()
        queue.append(songs("a", "b"))
        #expect(queue.current?.id == "a")
    }

    @Test func insertNextGoesAfterTheCurrentSong() {
        var queue = PlayQueue()
        queue.load(songs("a", "b", "c"))
        queue.insertNext(song("z"))
        #expect(ids(queue) == ["a", "z", "b", "c"])
    }

    @Test func removingBeforeTheCurrentSongKeepsIt() {
        var queue = PlayQueue()
        queue.load(songs("a", "b", "c"), startIndex: 2)
        let wasCurrent = queue.remove(at: 0)
        #expect(!wasCurrent)
        #expect(queue.current?.id == "c")
    }

    @Test func removingAfterTheCurrentSongKeepsIt() {
        var queue = PlayQueue()
        queue.load(songs("a", "b", "c"))
        let wasCurrent = queue.remove(at: 2)
        #expect(!wasCurrent)
        #expect(queue.current?.id == "a")
    }

    @Test func removingTheCurrentSongMovesToTheNext() {
        var queue = PlayQueue()
        queue.load(songs("a", "b", "c"), startIndex: 1)
        let wasCurrent = queue.remove(at: 1)
        #expect(wasCurrent)
        #expect(queue.current?.id == "c")
    }

    @Test func removingTheLastAndCurrentSongMovesBack() {
        var queue = PlayQueue()
        queue.load(songs("a", "b"), startIndex: 1)
        let wasCurrent = queue.remove(at: 1)
        #expect(wasCurrent)
        #expect(queue.current?.id == "a")
    }

    @Test func removingTheOnlySongEmptiesTheQueue() {
        var queue = PlayQueue()
        queue.load(songs("a"))
        let wasCurrent = queue.remove(at: 0)
        #expect(wasCurrent)
        #expect(queue.isEmpty && queue.currentIndex == -1)
    }

    @Test(arguments: [
        (old: 0, new: 2, order: ["b", "a", "c", "d"], current: "b"),
        (old: 0, new: 4, order: ["b", "c", "d", "a"], current: "b"),
        (old: 3, new: 0, order: ["d", "a", "b", "c"], current: "b"),
        (old: 1, new: 4, order: ["a", "c", "d", "b"], current: "b"),
    ])
    func reorderUsesPositionsBeforeTheMove(old: Int, new: Int, order: [String], current: String) {
        var queue = PlayQueue()
        queue.load(songs("a", "b", "c", "d"), startIndex: 1)
        queue.reorder(from: old, to: new)
        #expect(ids(queue) == order)
        #expect(queue.current?.id == current)
    }

    @Test func updateChangesEveryCopyInBothOrders() {
        var queue = PlayQueue()
        queue.load(songs("a", "b", "a"))
        queue.setShuffle(true)
        queue.updateSongs(id: "a") { $0.starred = true }
        #expect(queue.songs.filter { $0.id == "a" }.allSatisfy { $0.starred })
        queue.setShuffle(false)
        #expect(queue.songs.filter { $0.id == "a" }.allSatisfy { $0.starred })
        #expect(queue.songs.filter { $0.id == "b" }.allSatisfy { !$0.starred })
    }
}

@Suite struct PlayQueueSavingTests {
    @Test func aPlainQueueComesBack() {
        var queue = PlayQueue()
        queue.load(songs("a", "b", "c"), startIndex: 1)
        let restored = PlayQueue(saved: queue.saved, isShuffled: false)
        #expect(ids(restored) == ["a", "b", "c"])
        #expect(restored.current?.id == "b")
    }

    @Test func aShuffledQueueComesBackWithItsOriginalOrder() {
        var queue = PlayQueue()
        queue.load(songs("a", "b", "c", "d", "e"), startIndex: 1)
        queue.setShuffle(true)
        queue.move(to: 2)
        let playing = queue.current?.id
        var restored = PlayQueue(saved: queue.saved, isShuffled: true)
        #expect(ids(restored) == ids(queue))
        #expect(restored.current?.id == playing)
        restored.setShuffle(false)
        #expect(ids(restored) == ["a", "b", "c", "d", "e"])
        #expect(restored.current?.id == playing)
    }

    /// Each saved position is that place in the shuffled order, with songs queued twice and a big queue.
    @Test func theOriginalOrderIsSavedAsPlaces() throws {
        var queue = PlayQueue()
        let listed = (0..<2000).map { "s\($0 % 1000)" }
        queue.load(listed.map { song($0) }, startIndex: 0)
        queue.setShuffle(true)
        let saved = queue.saved
        let order = try #require(saved.originalOrder)
        #expect(order.map { saved.songs[$0].id } == listed)
        #expect(Set(order).count == listed.count)
    }

    @Test func aWrongIndexIsFoundAgainByTheSongsID() {
        let saved = PlayQueue.Saved(songs: songs("a", "b", "c"), originalOrder: nil, currentIndex: 0, currentSongID: "c")
        #expect(PlayQueue(saved: saved, isShuffled: false).current?.id == "c")
    }

    @Test func anIndexPastTheEndIsClamped() {
        let saved = PlayQueue.Saved(songs: songs("a", "b"), originalOrder: nil, currentIndex: 9, currentSongID: nil)
        #expect(PlayQueue(saved: saved, isShuffled: false).current?.id == "b")
    }

    @Test func aBadOriginalOrderIsIgnored() {
        let saved = PlayQueue.Saved(songs: songs("a", "b"), originalOrder: [0, 7], currentIndex: 0, currentSongID: "a")
        var restored = PlayQueue(saved: saved, isShuffled: true)
        restored.setShuffle(false)
        #expect(ids(restored) == ["a", "b"])
    }
}

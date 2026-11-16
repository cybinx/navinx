import Testing
@testable import Navinx

/// A count with its noun: the singular for one only.
struct CountTextTests {
    @Test func singularForOneOnly() {
        #expect(CountText.of(1, "song") == "1 song")
        #expect(CountText.of(0, "song") == "0 songs")
        #expect(CountText.of(2, "song") == "2 songs")
        #expect(CountText.of(1, "downloaded song") == "1 downloaded song")
        #expect(CountText.of(12, "second") == "12 seconds")
    }
}

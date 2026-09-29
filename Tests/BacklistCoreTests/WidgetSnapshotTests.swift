import XCTest
@testable import BacklistCore

final class WidgetSnapshotTests: XCTestCase {

    private func snapshot(offset: TimeInterval, duration: TimeInterval, rate: Double = 1) -> WidgetSnapshot {
        WidgetSnapshot(
            title: "Outliers", author: "Malcolm Gladwell", chapterTitle: "Chapter 3",
            offset: offset, duration: duration, rate: rate,
            isPlaying: true, hasCover: true,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testRoundTrips() throws {
        let original = snapshot(offset: 100, duration: 1_000)
        XCTAssertEqual(WidgetSnapshot.decode(try original.encoded()), original)
    }

    func testGarbageDecodesToNil() {
        XCTAssertNil(WidgetSnapshot.decode(Data("{}".utf8)))
    }

    func testProgressIsClampedAndSafeWithUnknownLength() {
        XCTAssertEqual(snapshot(offset: 250, duration: 1_000).progress, 0.25)
        XCTAssertEqual(snapshot(offset: 2_000, duration: 1_000).progress, 1)
        XCTAssertEqual(snapshot(offset: 10, duration: 0).progress, 0)
    }

    func testRemainingAccountsForSpeed() {
        // Two hours of book at 2× is one hour of listening.
        XCTAssertEqual(snapshot(offset: 0, duration: 7_200, rate: 2).remaining, 3_600)
    }

    func testRemainingText() {
        XCTAssertEqual(snapshot(offset: 0, duration: 3 * 3_600 + 12 * 60).remainingText, "3 h 12 m left")
        XCTAssertEqual(snapshot(offset: 0, duration: 2 * 3_600).remainingText, "2 h left")
        XCTAssertEqual(snapshot(offset: 0, duration: 45 * 60).remainingText, "45 m left")
        XCTAssertEqual(snapshot(offset: 990, duration: 1_000).remainingText, "Almost done")
        XCTAssertEqual(snapshot(offset: 0, duration: 0).remainingText, "")
    }
}

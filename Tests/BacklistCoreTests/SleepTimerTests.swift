import XCTest
@testable import BacklistCore

final class SleepTimerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testInactiveTimerNeverInterferes() {
        var timer = SleepTimer()
        XCTAssertFalse(timer.isActive)
        XCTAssertEqual(timer.tick(now: at(9_999), offset: 0, rate: 1), .play(volume: 1))
        XCTAssertNil(timer.remaining(offset: 0, rate: 1))
    }

    func testCountdownStopsAfterItsLength() {
        var timer = SleepTimer()
        timer.start(.after(60), now: t0, chapterEnd: nil)

        XCTAssertEqual(timer.tick(now: at(30), offset: 0, rate: 1), .play(volume: 1))
        XCTAssertEqual(timer.tick(now: at(60), offset: 0, rate: 1), .stop)
        XCTAssertFalse(timer.isActive, "a fired timer resets itself")
    }

    func testFadesOverTheFinalSeconds() {
        var timer = SleepTimer()
        timer.start(.after(60), now: t0, chapterEnd: nil)
        _ = timer.tick(now: at(50), offset: 0, rate: 1)
        XCTAssertEqual(timer.tick(now: at(55), offset: 0, rate: 1), .play(volume: 0.5))
    }

    func testPausedTimeIsNotCharged() {
        // A book paused for a phone call keeps its remaining sleep time.
        var timer = SleepTimer()
        timer.start(.after(60), now: t0, chapterEnd: nil)
        _ = timer.tick(now: at(20), offset: 0, rate: 1)
        timer.suspend()

        // Resumed ten minutes later: the first tick only re-anchors.
        _ = timer.tick(now: at(620), offset: 0, rate: 1)
        XCTAssertEqual(timer.remaining(offset: 0, rate: 1), 40)
        XCTAssertEqual(timer.tick(now: at(630), offset: 0, rate: 1), .play(volume: 1))
        XCTAssertEqual(timer.remaining(offset: 0, rate: 1), 30)
    }

    func testShakeRestartsTheFullCountdown() {
        var timer = SleepTimer()
        timer.start(.after(600), now: t0, chapterEnd: nil)
        _ = timer.tick(now: at(595), offset: 0, rate: 1)
        timer.extend(now: at(595), nextChapterEnd: nil)
        XCTAssertEqual(timer.remaining(offset: 0, rate: 1), 600)
    }

    func testEndOfChapterStopsAtTheBoundary() {
        var timer = SleepTimer()
        timer.start(.endOfChapter, now: t0, chapterEnd: 1_000)
        XCTAssertEqual(timer.tick(now: at(1), offset: 900, rate: 1), .play(volume: 1))
        XCTAssertEqual(timer.tick(now: at(2), offset: 1_000, rate: 1), .stop)
    }

    func testEndOfChapterAccountsForPlaybackRate() {
        // 20 book-seconds left at 2× is 10 wall-seconds: the fade is over.
        var timer = SleepTimer()
        timer.start(.endOfChapter, now: t0, chapterEnd: 1_000)
        XCTAssertEqual(timer.remaining(offset: 980, rate: 2), 10)
        XCTAssertEqual(timer.tick(now: at(1), offset: 990, rate: 2), .play(volume: 0.5))
    }

    func testShakeAtEndOfChapterAddsTheNextChapter() {
        var timer = SleepTimer()
        timer.start(.endOfChapter, now: t0, chapterEnd: 1_000)
        timer.extend(now: at(1), nextChapterEnd: 2_500)
        XCTAssertEqual(timer.tick(now: at(2), offset: 1_000, rate: 1), .play(volume: 1))
        XCTAssertEqual(timer.remaining(offset: 1_500, rate: 1), 1_000)
    }

    func testCancelClearsEverything() {
        var timer = SleepTimer()
        timer.start(.after(60), now: t0, chapterEnd: nil)
        timer.cancel()
        XCTAssertEqual(timer, SleepTimer())
    }
}

import XCTest
@testable import BacklistCore

final class StoragePolicyTests: XCTestCase {

    // MARK: - Helpers

    private func MB(_ n: Int64) -> Int64 { n * 1024 * 1024 }
    private func GB(_ n: Int64) -> Int64 { n * 1024 * 1024 * 1024 }

    private func daysAgo(_ n: Int, from now: Date = Date()) -> Date {
        now.addingTimeInterval(-TimeInterval(n) * 86_400)
    }

    private func file(
        _ id: UUID = UUID(),
        bytes: Int64,
        resident: Bool = true,
        pinned: Bool = false,
        shelf: Shelf = .owned,
        queue: Int? = nil,
        played: Date? = nil,
        finished: Date? = nil,
        nowPlaying: Bool = false
    ) -> ManagedFile {
        ManagedFile(
            copyID: id,
            byteCount: bytes,
            availability: resident ? .downloaded : .cloudOnly,
            isPinned: pinned,
            shelf: shelf,
            queuePosition: queue,
            lastPlayedAt: played,
            finishedAt: finished,
            isNowPlaying: nowPlaying
        )
    }

    private var policy: StoragePolicy {
        StoragePolicy(budgetBytes: GB(2), autoDownloadCount: 3, finishedGraceDays: 7)
    }

    // MARK: - The promises that must never break

    func testPinnedIsNeverEvictedEvenWellOverBudget() {
        let pinned = file(bytes: GB(5), pinned: true)
        let plan = policy.plan(for: [pinned])

        XCTAssertTrue(plan.toEvict.isEmpty, "pinned must mean pinned")
        XCTAssertGreaterThan(plan.overBudgetBy, 0, "overage must be reported, not hidden")
    }

    func testPinnedFinishedBookIsNotReclaimedByAge() {
        // Deliberately kept, long finished. Reference books live here.
        let kept = file(
            bytes: MB(400), pinned: true, shelf: .finished, finished: daysAgo(400)
        )
        let plan = policy.plan(for: [kept])
        XCTAssertTrue(plan.toEvict.isEmpty)
    }

    func testNowPlayingIsNeverEvicted() {
        // Evicting this would stop playback mid-sentence, possibly while driving.
        let playing = file(bytes: GB(3), shelf: .finished, finished: daysAgo(90), nowPlaying: true)
        let plan = policy.plan(for: [playing])
        XCTAssertTrue(plan.toEvict.isEmpty)
    }

    // MARK: - Reclaiming finished books

    func testFinishedPastGraceIsReclaimed() {
        let old = file(bytes: MB(400), shelf: .finished, finished: daysAgo(30))
        let plan = policy.plan(for: [old])

        XCTAssertEqual(plan.toEvict.count, 1)
        XCTAssertEqual(plan.toEvict.first?.reason, .finishedAndAged)
        XCTAssertEqual(plan.reclaimedBytes, MB(400))
    }

    func testFinishedWithinGraceIsKept() {
        // You might want to skim the last chapter again.
        let recent = file(bytes: MB(400), shelf: .finished, finished: daysAgo(2))
        let plan = policy.plan(for: [recent])
        XCTAssertTrue(plan.toEvict.isEmpty)
    }

    func testFinishedHappensEvenWhenWellUnderBudget() {
        // Holding 400 MB of a book finished last month helps nobody, budget or not.
        let old = file(bytes: MB(400), shelf: .finished, finished: daysAgo(60))
        let roomy = StoragePolicy(budgetBytes: GB(100), finishedGraceDays: 7)
        XCTAssertEqual(roomy.plan(for: [old]).toEvict.count, 1)
    }

    func testFinishedWithNoDateIsNotReclaimed() {
        // Missing data must not be read as "finished long ago".
        let noDate = file(bytes: MB(400), shelf: .finished, finished: nil)
        XCTAssertTrue(policy.plan(for: [noDate]).toEvict.isEmpty)
    }

    func testAbandonedIsReclaimedImmediately() {
        let dnf = file(bytes: MB(400), shelf: .abandoned)
        let plan = policy.plan(for: [dnf])
        XCTAssertEqual(plan.toEvict.first?.reason, .abandoned)
    }

    // MARK: - Budget pressure

    func testEvictsUntilUnderBudget() {
        let files = (0..<6).map { _ in file(bytes: MB(500), shelf: .owned, played: daysAgo(10)) }
        // 3 GB resident against a 2 GB budget.
        let plan = policy.plan(for: files)

        XCTAssertLessThanOrEqual(plan.bytesAfter, GB(2))
        XCTAssertEqual(plan.overBudgetBy, 0)
        XCTAssertFalse(plan.toEvict.isEmpty)
    }

    func testEvictsLeastRecentlyPlayedFirst() {
        let stale = file(bytes: GB(2), shelf: .owned, played: daysAgo(200))
        let fresh = file(bytes: GB(1), shelf: .owned, played: daysAgo(1))
        let plan = policy.plan(for: [fresh, stale])

        XCTAssertEqual(plan.toEvict.map(\.copyID), [stale.copyID])
    }

    func testQueuedBooksSurviveBudgetPressureBeforeUnqueuedOnes() {
        let unqueued = file(bytes: GB(2), shelf: .owned, played: daysAgo(1))
        let queued = file(bytes: GB(1), shelf: .owned, queue: 0, played: daysAgo(300))
        let plan = policy.plan(for: [queued, unqueued])

        XCTAssertEqual(
            plan.toEvict.map(\.copyID), [unqueued.copyID],
            "the next book to listen to outranks recency"
        )
    }

    func testEvictionOrderRanking() {
        let finished = file(bytes: 1, shelf: .finished)
        let abandoned = file(bytes: 1, shelf: .abandoned)
        let forgotten = file(bytes: 1, shelf: .owned, played: nil)
        let played = file(bytes: 1, shelf: .owned, played: daysAgo(1))
        let upNext = file(bytes: 1, shelf: .owned, queue: 0)

        XCTAssertLessThan(StoragePolicy.rank(finished), StoragePolicy.rank(abandoned))
        XCTAssertLessThan(StoragePolicy.rank(abandoned), StoragePolicy.rank(forgotten))
        XCTAssertLessThan(StoragePolicy.rank(forgotten), StoragePolicy.rank(played))
        XCTAssertLessThan(StoragePolicy.rank(played), StoragePolicy.rank(upNext))
    }

    // MARK: - Downloading

    func testDownloadsTopOfQueue() {
        let files = (0..<5).map { index in
            file(bytes: MB(300), resident: false, queue: index)
        }
        let plan = policy.plan(for: files)

        XCTAssertEqual(plan.toDownload.count, 3, "autoDownloadCount is 3")
        XCTAssertEqual(plan.toDownload, files.prefix(3).map(\.copyID))
    }

    func testDoesNotDownloadOnCellularWhenWiFiRequired() {
        let queued = file(bytes: MB(300), resident: false, queue: 0)
        let plan = policy.plan(
            for: [queued],
            conditions: DeviceConditions(onWiFi: false, isCharging: true)
        )
        XCTAssertTrue(plan.toDownload.isEmpty)
    }

    func testDownloadsOnCellularWhenAllowed() {
        var relaxed = policy
        relaxed.requiresWiFi = false
        let queued = file(bytes: MB(300), resident: false, queue: 0)
        let plan = relaxed.plan(
            for: [queued],
            conditions: DeviceConditions(onWiFi: false, isCharging: false)
        )
        XCTAssertEqual(plan.toDownload.count, 1)
    }

    func testChargingRequirementIsHonouredWhenSet() {
        var strict = policy
        strict.requiresCharging = true
        let queued = file(bytes: MB(300), resident: false, queue: 0)
        let plan = strict.plan(
            for: [queued],
            conditions: DeviceConditions(onWiFi: true, isCharging: false)
        )
        XCTAssertTrue(plan.toDownload.isEmpty)
    }

    func testOnlyDownloadsWhatFits() {
        // One 900 MB resident book, 2 GB budget, three 800 MB books queued.
        let resident = file(bytes: MB(900), shelf: .owned, queue: 0, played: daysAgo(1))
        let queued = (1...3).map { index in
            file(bytes: MB(800), resident: false, queue: index)
        }
        let plan = policy.plan(for: [resident] + queued)

        XCTAssertLessThanOrEqual(plan.bytesAfter, GB(2))
        XCTAssertLessThan(plan.toDownload.count, 3)
    }

    func testDoesNotDownloadSomethingAlreadyResident() {
        let here = file(bytes: MB(300), resident: true, queue: 0)
        XCTAssertTrue(policy.plan(for: [here]).toDownload.isEmpty)
    }

    func testIgnoresQueuePositionsBeyondAutoDownloadCount() {
        let deep = file(bytes: MB(100), resident: false, queue: 9)
        XCTAssertTrue(policy.plan(for: [deep]).toDownload.isEmpty)
    }

    func testTracksAndPhysicalCopiesAreNeverDownloaded() {
        var kindle = file(bytes: 0, resident: false, queue: 0)
        kindle.availability = .notAFile
        XCTAssertTrue(policy.plan(for: [kindle]).toDownload.isEmpty)
    }

    // MARK: - Real disk pressure

    func testFreeDiskCanConstrainBelowTheBudget() {
        // Budget says 2 GB, but the phone has 600 MB free and 500 MB of headroom.
        let queued = file(bytes: MB(400), resident: false, queue: 0)
        let plan = policy.plan(
            for: [queued],
            conditions: DeviceConditions(onWiFi: true, isCharging: true, freeDiskBytes: MB(600))
        )
        XCTAssertTrue(plan.toDownload.isEmpty, "must not fill the device to honour a budget")
    }

    func testFreeDiskIsIgnoredWhenUnknown() {
        let queued = file(bytes: MB(400), resident: false, queue: 0)
        let plan = policy.plan(
            for: [queued],
            conditions: DeviceConditions(onWiFi: true, isCharging: true, freeDiskBytes: nil)
        )
        XCTAssertEqual(plan.toDownload.count, 1)
    }

    // MARK: - Bookkeeping

    func testEmptyLibraryIsANoOp() {
        let plan = policy.plan(for: [])
        XCTAssertTrue(plan.isNoOp)
        XCTAssertEqual(plan.bytesBefore, 0)
        XCTAssertEqual(plan.bytesAfter, 0)
    }

    func testByteAccountingBalances() {
        let files = [
            file(bytes: MB(500), shelf: .finished, finished: daysAgo(30)),
            file(bytes: MB(500), shelf: .owned, played: daysAgo(1)),
            file(bytes: MB(500), resident: false, queue: 0),
        ]
        let plan = policy.plan(for: files)
        let downloaded = files
            .filter { plan.toDownload.contains($0.copyID) }
            .reduce(0) { $0 + $1.byteCount }

        XCTAssertEqual(plan.bytesAfter, plan.bytesBefore - plan.reclaimedBytes + downloaded)
    }

    func testPlanIsStableAcrossRuns() {
        // Identical input must not shuffle, or the UI flickers and downloads churn.
        let files = (0..<8).map { _ in file(bytes: MB(500), shelf: .owned, played: daysAgo(5)) }
        let now = Date()
        let first = policy.plan(for: files, now: now)
        let second = policy.plan(for: files, now: now)
        XCTAssertEqual(first.toEvict.map(\.copyID), second.toEvict.map(\.copyID))
    }
}

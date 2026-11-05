import XCTest
@testable import QuickCullCore

final class WorkSchedulerTests: XCTestCase {
    func testVisibleRunsBeforeBackground() {
        let scheduler = WorkScheduler()
        let background = scheduler.enqueue(
            group: "index", name: "walk", lane: .background, volume: "/Volumes/Slow",
            pace: .slow, generation: 1, now: 0)
        let visible = scheduler.enqueue(
            group: "thumb", name: "cell", lane: .visible, volume: "/Volumes/Slow",
            pace: .slow, generation: 1, now: 1)
        let first = scheduler.promoteNext(now: 2)
        XCTAssertEqual(first?.id, visible)
        XCTAssertEqual(first?.lane, .visible)
        XCTAssertNotEqual(first?.id, background)
    }

    func testCancelGenerationDropsQueuedWork() {
        let scheduler = WorkScheduler()
        let stale = scheduler.enqueue(
            group: "exif", name: "old folder", lane: .prefetch, volume: "/",
            pace: .fast, generation: 3, now: 0)
        _ = scheduler.enqueue(
            group: "exif", name: "new folder", lane: .prefetch, volume: "/",
            pace: .fast, generation: 4, now: 1)
        scheduler.cancel(group: "exif", generation: 3)
        XCTAssertTrue(scheduler.isCancelled(stale))
        let next = scheduler.promoteNext(now: 2)
        XCTAssertEqual(next?.name, "new folder")
        XCTAssertEqual(next?.generation, 4)
    }

    func testSlowVolumeAllowsOnlyTwoReads() {
        let scheduler = WorkScheduler(slowLimit: 2, fastLimit: 6, globalLimit: 8)
        for index in 0..<4 {
            scheduler.enqueue(
                group: "thumb", name: "file \(index)", lane: .visible, volume: "/Volumes/Card",
                pace: .slow, generation: 1, now: TimeInterval(index))
        }
        let first = scheduler.promoteNext(now: 10)
        let second = scheduler.promoteNext(now: 11)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNil(scheduler.promoteNext(now: 12))
        scheduler.finish(first!.id)
        XCTAssertNotNil(scheduler.promoteNext(now: 13))
    }

    func testFolderLoadHoldsTheIndexWalk() {
        let scheduler = WorkScheduler()
        scheduler.setFolderLoading(true)
        scheduler.enqueue(
            group: "index", name: "walk", lane: .background, volume: "/",
            pace: .fast, generation: 1, now: 0)
        scheduler.enqueue(
            group: "thumb", name: "cell", lane: .visible, volume: "/",
            pace: .fast, generation: 1, now: 1)
        XCTAssertTrue(scheduler.backgroundShouldYield)
        XCTAssertEqual(scheduler.promoteNext(now: 2)?.name, "cell")
        XCTAssertNil(scheduler.promoteNext(now: 3))
        scheduler.setFolderLoading(false)
        scheduler.finish(scheduler.live().first { $0.state == .running }!.id)
        XCTAssertEqual(scheduler.promoteNext(now: 4)?.name, "walk")
    }

    func testTwentyThousandJobsPromoteAndChangeLanesQuickly() {
        let scheduler = WorkScheduler()
        var ids: [Int] = []
        ids.reserveCapacity(20_000)
        for index in 0..<20_000 {
            ids.append(scheduler.enqueue(
                group: "thumb", name: "file \(index)", lane: .prefetch, volume: "/fast",
                pace: .fast, generation: 1, now: TimeInterval(index)))
        }
        let started = Date()
        for id in ids.prefix(1_000) {
            scheduler.noteLane(id, .visible)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05)
        scheduler.applyLaneNotes()
        let move = Date()
        for id in ids.dropFirst(1_000).prefix(1_000) {
            scheduler.setLane(id, .selected)
        }
        XCTAssertLessThan(Date().timeIntervalSince(move), 0.05)
        var startedCount = 0
        var sawVisible = false
        while let job = scheduler.promoteNext(now: 1) {
            if job.lane == .visible { sawVisible = true }
            startedCount += 1
        }
        XCTAssertTrue(sawVisible)
        XCTAssertEqual(startedCount, 6)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05)
    }

    func testNoteLaneDoesNotBlockTheCallerOnTheJobLock() {
        let scheduler = WorkScheduler()
        let id = scheduler.enqueue(
            group: "thumb", name: "cell", lane: .prefetch, volume: "/",
            pace: .fast, generation: 1, now: 0)
        scheduler.noteLane(id, .visible)
        let before = scheduler.promoteNext(now: 1)
        XCTAssertEqual(before?.id, id)
        XCTAssertEqual(before?.lane, .prefetch)
        scheduler.finish(id)
        scheduler.applyLaneNotes()
        let again = scheduler.enqueue(
            group: "thumb", name: "next", lane: .prefetch, volume: "/",
            pace: .fast, generation: 1, now: 2)
        scheduler.noteLane(again, .visible)
        scheduler.applyLaneNotes()
        XCTAssertEqual(scheduler.promoteNext(now: 3)?.lane, .visible)
    }

    func testWatchdogFindsAJobThatRunsTooLong() {
        let scheduler = WorkScheduler(timeout: 5)
        scheduler.enqueue(
            group: "index", name: "stuck walk", lane: .background, volume: "/",
            pace: .fast, generation: 1, now: 0)
        let job = scheduler.promoteNext(now: 1)!
        XCTAssertTrue(scheduler.overdue(now: 6).isEmpty)
        XCTAssertEqual(scheduler.overdue(now: 6.1).map(\.name), ["stuck walk"])
        scheduler.markTimedOut(job.id, now: 6.1)
        XCTAssertTrue(scheduler.isCancelled(job.id))
    }
}

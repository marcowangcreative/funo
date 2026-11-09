import XCTest
@testable import QuickCullCore

final class ThumbRetryTests: XCTestCase {
    func testCancellationDoesNotCountAndRequeuesAWaiter() {
        let decision = ThumbRetryPolicy.decide(outcome: .cancelled, failures: 2, hasWaiter: true)
        XCTAssertEqual(decision.failures, 2)
        XCTAssertFalse(decision.giveUp)
        XCTAssertTrue(decision.requeue)
    }

    func testCancellationWithoutAWaiterIsDropped() {
        let decision = ThumbRetryPolicy.decide(outcome: .cancelled, failures: 0, hasWaiter: false)
        XCTAssertEqual(decision.failures, 0)
        XCTAssertFalse(decision.requeue)
        XCTAssertFalse(decision.giveUp)
    }

    func testOnlyRealFailuresReachTheCap() {
        var failures = 0
        for _ in 0..<2 {
            let step = ThumbRetryPolicy.decide(outcome: .failed, failures: failures, hasWaiter: true)
            failures = step.failures
            XCTAssertFalse(step.giveUp)
            XCTAssertTrue(step.requeue)
        }
        let third = ThumbRetryPolicy.decide(outcome: .failed, failures: failures, hasWaiter: true)
        XCTAssertEqual(third.failures, ThumbRetryPolicy.failureCap)
        XCTAssertTrue(third.giveUp)
        XCTAssertFalse(third.requeue)
    }

    func testACancelBetweenFailuresDoesNotAdvanceTheCap() {
        let once = ThumbRetryPolicy.decide(outcome: .failed, failures: 0, hasWaiter: true)
        let cancelled = ThumbRetryPolicy.decide(outcome: .cancelled, failures: once.failures, hasWaiter: true)
        XCTAssertEqual(cancelled.failures, 1)
        XCTAssertTrue(cancelled.requeue)
        let twice = ThumbRetryPolicy.decide(outcome: .failed, failures: cancelled.failures, hasWaiter: true)
        XCTAssertEqual(twice.failures, 2)
        XCTAssertFalse(twice.giveUp)
    }

    func testAGoodImageClearsTheFailureCount() {
        let decision = ThumbRetryPolicy.decide(outcome: .ready, failures: 2, hasWaiter: true)
        XCTAssertEqual(decision.failures, 0)
        XCTAssertFalse(decision.giveUp)
        XCTAssertFalse(decision.requeue)
    }
}
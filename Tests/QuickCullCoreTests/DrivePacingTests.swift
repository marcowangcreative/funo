import XCTest
@testable import QuickCullCore

final class DrivePacingTests: XCTestCase {
    func testCardExternalAndInternalAreDifferentPaces() {
        XCTAssertEqual(DrivePacing.pace(removable: true, isInternal: false), .card)
        XCTAssertEqual(DrivePacing.pace(removable: true, isInternal: true), .card)
        // An exFAT SSD reports not-removable and not-internal. It is not a card.
        XCTAssertEqual(DrivePacing.pace(removable: false, isInternal: false), .external)
        XCTAssertEqual(DrivePacing.pace(removable: false, isInternal: true), .internalDisk)
    }

    func testLimitsFollowCoreCount() {
        let studio = DrivePacing.limits(cores: 24)
        XCTAssertEqual(studio.card, 2)
        XCTAssertEqual(studio.external, 22)
        XCTAssertEqual(studio.internalDisk, 23)
        XCTAssertGreaterThanOrEqual(studio.global, 23)

        let small = DrivePacing.limits(cores: 4)
        XCTAssertEqual(small.card, 2)
        XCTAssertEqual(small.external, 4)
        XCTAssertEqual(small.internalDisk, 4)
        XCTAssertGreaterThanOrEqual(small.global, 3)
    }

    func testSchedulerUsesThoseLimits() {
        let limits = DrivePacing.limits(cores: 16)
        XCTAssertEqual(DrivePacing.limit(.card, limits), 2)
        XCTAssertEqual(DrivePacing.limit(.external, limits), 14)
        XCTAssertEqual(DrivePacing.limit(.internalDisk, limits), 15)
        XCTAssertGreaterThan(limits.external, 2)
    }
}

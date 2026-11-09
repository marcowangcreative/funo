import XCTest
@testable import QuickCullCore

final class GridEditTests: XCTestCase {
    private let order = ["a", "b", "c", "d", "e"]

    func testRemovingBlockAboveAnchorKeepsAnchorAndSelectsNext() {
        let anchor = VisibleAnchor(id: "c", offset: 12)
        let plan = GridEdit.removalPlan(order: order, removing: ["a", "b"], anchor: anchor)
        XCTAssertEqual(plan.remaining, ["c", "d", "e"])
        XCTAssertEqual(plan.removedIndexes, [0, 1])
        XCTAssertEqual(plan.selectionID, "c")
        XCTAssertEqual(plan.anchor, anchor)
    }

    func testRemovingBlockInsideViewKeepsAnchor() {
        let anchor = VisibleAnchor(id: "b", offset: 4)
        let plan = GridEdit.removalPlan(order: order, removing: ["c", "d"], anchor: anchor)
        XCTAssertEqual(plan.remaining, ["a", "b", "e"])
        XCTAssertEqual(plan.removedIndexes, [2, 3])
        XCTAssertEqual(plan.selectionID, "e")
        XCTAssertEqual(plan.anchor, anchor)
    }

    func testRemovingBlockBelowAnchorKeepsAnchor() {
        let anchor = VisibleAnchor(id: "b", offset: -6)
        let plan = GridEdit.removalPlan(order: order, removing: ["d", "e"], anchor: anchor)
        XCTAssertEqual(plan.remaining, ["a", "b", "c"])
        XCTAssertEqual(plan.selectionID, "c")
        XCTAssertEqual(plan.anchor, anchor)
    }

    func testRemovingTheAnchorItselfHandsOffsetToTheNextPhoto() {
        let plan = GridEdit.removalPlan(order: order, removing: ["c"], anchor: VisibleAnchor(id: "c", offset: 18))
        XCTAssertEqual(plan.remaining, ["a", "b", "d", "e"])
        XCTAssertEqual(plan.selectionID, "d")
        XCTAssertEqual(plan.anchor, VisibleAnchor(id: "d", offset: 18))
    }

    func testRemovingTheLastItemsSelectsThePreviousPhoto() {
        let plan = GridEdit.removalPlan(order: order, removing: ["d", "e"], anchor: VisibleAnchor(id: "e", offset: 2))
        XCTAssertEqual(plan.selectionID, "c")
        XCTAssertEqual(plan.anchor, VisibleAnchor(id: "c", offset: 2))
    }

    func testRemovingRawAndJPEGPairDropsBoth() {
        let order = ["raw", "jpg", "next"]
        let removing = GridEdit.withCompanions(["raw"], companions: ["raw": "jpg", "jpg": "raw"])
        let plan = GridEdit.removalPlan(order: order, removing: removing, anchor: VisibleAnchor(id: "raw", offset: 0))
        XCTAssertEqual(removing, ["raw", "jpg"])
        XCTAssertEqual(plan.remaining, ["next"])
        XCTAssertEqual(plan.removedIndexes, [0, 1])
        XCTAssertEqual(plan.selectionID, "next")
        XCTAssertEqual(plan.anchor, VisibleAnchor(id: "next", offset: 0))
    }

    func testRemovingEverythingLeavesNoSelection() {
        let plan = GridEdit.removalPlan(order: order, removing: Set(order), anchor: VisibleAnchor(id: "a", offset: 1))
        XCTAssertEqual(plan.remaining, [])
        XCTAssertNil(plan.selectionID)
        XCTAssertNil(plan.anchor)
    }
}

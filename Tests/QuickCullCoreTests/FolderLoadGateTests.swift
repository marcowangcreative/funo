import XCTest
@testable import QuickCullCore

final class FolderLoadGateTests: XCTestCase {

    func testLateFolderLoadIsDropped() {
        var gate = FolderLoadGate()
        let first = gate.begin(to: "/Volumes/Card/Monday")
        let second = gate.begin(to: "/Volumes/Card/Tuesday")
        XCTAssertFalse(gate.accepts(first.generation))
        XCTAssertTrue(gate.accepts(second.generation))
        XCTAssertEqual(gate.path, "/Volumes/Card/Tuesday")
    }

    func testSwitchBlanksAndReloadOfTheSameFolderDoesNot() {
        var gate = FolderLoadGate()
        let first = gate.begin(to: "/Jobs/A")
        XCTAssertTrue(first.blank)
        let again = gate.begin(to: "/Jobs/A")
        XCTAssertFalse(again.blank)
        XCTAssertFalse(gate.accepts(first.generation))
        XCTAssertTrue(gate.accepts(again.generation))
        let other = gate.begin(to: "/Jobs/B")
        XCTAssertTrue(other.blank)
        XCTAssertFalse(gate.accepts(again.generation))
    }

    func testOnlyTheNewestOfThreeClicksApplies() {
        var gate = FolderLoadGate()
        let a = gate.begin(to: "/A")
        let b = gate.begin(to: "/B")
        let c = gate.begin(to: "/C")
        XCTAssertFalse(gate.accepts(a.generation))
        XCTAssertFalse(gate.accepts(b.generation))
        XCTAssertTrue(gate.accepts(c.generation))
        XCTAssertTrue(a.blank)
        XCTAssertTrue(b.blank)
        XCTAssertTrue(c.blank)
    }
}

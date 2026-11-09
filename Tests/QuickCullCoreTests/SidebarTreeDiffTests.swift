import XCTest
@testable import QuickCullCore

final class SidebarTreeDiffTests: XCTestCase {

    private func replay(_ old: [String], _ new: [String]) -> [String] {
        var working = old
        for edit in SidebarTreeDiff.diff(old: old, new: new) {
            switch edit {
            case .remove(let index):
                working.remove(at: index)
            case .insert(let key, let index):
                working.insert(key, at: index)
            case .move(let key, let from, let to):
                XCTAssertEqual(working[from], key)
                let item = working.remove(at: from)
                working.insert(item, at: to)
            }
        }
        return working
    }

    func testNoEditsWhenTheLevelIsUnchanged() {
        XCTAssertTrue(SidebarTreeDiff.diff(old: ["a", "b"], new: ["a", "b"]).isEmpty)
    }

    func testRemovalsComeFromTheEndSoIndexesStayValid() {
        let edits = SidebarTreeDiff.diff(old: ["a", "b", "c", "d"], new: ["b", "d"])
        let removals = edits.compactMap { edit -> Int? in
            if case .remove(let index) = edit { return index }
            return nil
        }
        XCTAssertEqual(removals, [2, 0])
        XCTAssertEqual(replay(["a", "b", "c", "d"], ["b", "d"]), ["b", "d"])
    }

    func testInsertAndReorderReplay() {
        XCTAssertEqual(replay(["a", "b"], ["c", "a", "b"]), ["c", "a", "b"])
        XCTAssertEqual(replay(["a", "b", "c"], ["c", "a", "b"]), ["c", "a", "b"])
        XCTAssertEqual(replay(["Pictures", "Desktop", "Home"], ["Desktop", "Home"]), ["Desktop", "Home"])
    }

    func testExpansionDropsMissingPathsAndOpensParentsFirst() {
        let kept = SidebarTreeDiff.preservedExpansion(
            ["/Jobs/Day/Selects", "/Jobs", "/Jobs/Day", "/Volumes/Card"],
            present: ["/Jobs", "/Jobs/Day", "/Jobs/Day/Selects"]
        )
        XCTAssertEqual(kept, ["/Jobs", "/Jobs/Day", "/Jobs/Day/Selects"])
    }

    func testEmptyExpansionStaysEmpty() {
        XCTAssertTrue(SidebarTreeDiff.preservedExpansion([], present: ["/Jobs"]).isEmpty)
        XCTAssertTrue(SidebarTreeDiff.preservedExpansion(["/Gone"], present: []).isEmpty)
    }
}

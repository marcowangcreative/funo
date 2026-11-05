import XCTest
@testable import QuickCullCore

final class SidebarRelocationTests: XCTestCase {
    func testMoveRemovesTheOldSiblingAndInsertsInOrder() {
        var source = ["Ann", "Moved", "Zoe"]
        var destination = ["Bea", "Nia"]
        let fromIndex = source.firstIndex(of: "Moved")!
        source.remove(at: fromIndex)
        let toIndex = SidebarRelocation.insertionIndex(of: "Moved", among: destination)
        destination.insert("Moved", at: toIndex)
        XCTAssertEqual(fromIndex, 1)
        XCTAssertEqual(toIndex, 1)
        XCTAssertEqual(source, ["Ann", "Zoe"])
        XCTAssertEqual(destination, ["Bea", "Moved", "Nia"])
    }

    func testUniqueNameAvoidsACaseInsensitiveCollision() {
        XCTAssertEqual(SidebarRelocation.uniqueName("Jobs", existing: ["Archive"]), "Jobs")
        XCTAssertEqual(SidebarRelocation.uniqueName("Jobs", existing: ["jobs", "Jobs 2"]), "Jobs 3")
    }

    func testRekeyRewritesTheFolderAndItsChildrenOnly() {
        let from = "/Volumes/MWP2026/2026 Weddings/Ashley and Will"
        let to = "/Volumes/Extreme Pro/Archive/Ashley and Will"
        XCTAssertEqual(SidebarRelocation.rekey(path: from, from: from, to: to), to)
        XCTAssertEqual(
            SidebarRelocation.rekey(path: from + "/Ceremony/IMG.CR3", from: from, to: to),
            to + "/Ceremony/IMG.CR3"
        )
        XCTAssertNil(SidebarRelocation.rekey(path: from + " Extra", from: from, to: to))
        XCTAssertEqual(
            SidebarRelocation.rekeyAll([from, from + "/Day", "/Elsewhere"], from: from, to: to),
            [from: to, from + "/Day": to + "/Day"]
        )
    }

    func testSelfCausedEventsIgnoreBothSidesUntilTheMoveEnds() {
        var moves = SelfCausedMoves()
        let move = SelfCausedMove(
            from: "/Volumes/MWP2026/2026 Weddings/Ashley and Will",
            to: "/Volumes/Extreme Pro/Archive/Ashley and Will"
        )
        moves.begin(move)
        XCTAssertTrue(moves.involves(move.from))
        XCTAssertTrue(moves.involves(move.from + "/Ceremony"))
        XCTAssertTrue(moves.involves(move.to + "/Ceremony"))
        XCTAssertFalse(moves.involves("/Volumes/MWP2026/2026 Weddings/Sam and Joy"))
        XCTAssertFalse(moves.involves(move.from + " Extra"))
        XCTAssertTrue(moves.isStaleSource(move.from + "/Ceremony"))
        XCTAssertFalse(moves.isStaleSource(move.to))
        moves.end(from: move.from)
        XCTAssertFalse(moves.involves(move.from))
        XCTAssertFalse(moves.isStaleSource(move.to))
    }

    func testVolumeIndexRekeyDropsTheOldPath() {
        let from = "/Volumes/MWP2026/Jobs"
        let child = from + "/Day"
        var index = VolumeNameIndex(entries: [
            VolumeNameEntry(path: from, isFolder: true, depth: 1, modified: 10,
                            volumeName: "MWP2026", volumeRoot: "/Volumes/MWP2026"),
            VolumeNameEntry(path: child, isFolder: true, depth: 2, modified: 11,
                            volumeName: "MWP2026", volumeRoot: "/Volumes/MWP2026"),
            VolumeNameEntry(path: "/Volumes/MWP2026/Other", isFolder: true, depth: 1, modified: 1,
                            volumeName: "MWP2026", volumeRoot: "/Volumes/MWP2026")
        ])
        let to = "/Volumes/Extreme Pro/Archive/Jobs"
        index.rekey(from: from, to: to, volumeName: "Extreme Pro", volumeRoot: "/Volumes/Extreme Pro")
        let paths = index.entries.map(\.path)
        XCTAssertFalse(paths.contains(from))
        XCTAssertFalse(paths.contains(child))
        XCTAssertTrue(paths.contains(to))
        XCTAssertTrue(paths.contains(to + "/Day"))
        XCTAssertTrue(paths.contains("/Volumes/MWP2026/Other"))
        let moved = index.entries.first { $0.path == to + "/Day" }
        XCTAssertEqual(moved?.volumeName, "Extreme Pro")
        XCTAssertEqual(moved?.volumeRoot, "/Volumes/Extreme Pro")
        XCTAssertEqual(moved?.depth, 3)
    }
}
import XCTest
@testable import QuickCullCore

final class ColorLabelSelectionTests: XCTestCase {

    private func photos(_ pairs: [(String, Int)]) -> [ColorLabelSelection.Photo] {
        pairs.map { ColorLabelSelection.Photo(id: $0.0, label: $0.1) }
    }

    func testMultiSelectionKeepsOnlyTheChosenLabel() {
        let displayed = photos([
            ("a", 1), ("b", 2), ("c", 1), ("d", 0), ("e", 1)
        ])
        // Working set is b, c, d, e — "a" is the same color but not selected,
        // so it must stay unselected.
        let ids = ColorLabelSelection.idsToSelect(
            displayed: displayed,
            selectedIDs: ["b", "c", "d", "e"],
            label: 1
        )
        XCTAssertEqual(ids, ["c", "e"])
        XCTAssertEqual(ColorLabelSelection.scopeName(selectedCount: 4), "selection")
    }

    func testSingleSelectionSelectsTheWholeFolder() {
        let displayed = photos([
            ("a", 3), ("b", 1), ("c", 3), ("d", 0)
        ])
        let ids = ColorLabelSelection.idsToSelect(
            displayed: displayed,
            selectedIDs: ["b"],
            label: 3
        )
        XCTAssertEqual(ids, ["a", "c"])
        XCTAssertEqual(ColorLabelSelection.scopeName(selectedCount: 1), "folder")
    }

    func testEmptySelectionSelectsEveryMatchInOrder() {
        let displayed = photos([
            ("a", 0), ("b", 4), ("c", 0), ("d", 4)
        ])
        let unlabeled = ColorLabelSelection.idsToSelect(
            displayed: displayed,
            selectedIDs: [],
            label: 0
        )
        XCTAssertEqual(unlabeled, ["a", "c"])
        let blue = ColorLabelSelection.idsToSelect(
            displayed: displayed,
            selectedIDs: [],
            label: 4
        )
        XCTAssertEqual(blue, ["b", "d"])
    }

    func testNoMatchReturnsEmpty() {
        let displayed = photos([("a", 1), ("b", 2)])
        let ids = ColorLabelSelection.idsToSelect(
            displayed: displayed,
            selectedIDs: ["a", "b"],
            label: 5
        )
        XCTAssertEqual(ids, [])
    }

    func testNarrowingPreservesDisplayOrder() {
        let displayed = photos([
            ("z", 2), ("a", 2), ("m", 5), ("b", 2)
        ])
        let ids = ColorLabelSelection.idsToSelect(
            displayed: displayed,
            selectedIDs: ["b", "z", "a", "m"],
            label: 2
        )
        XCTAssertEqual(ids, ["z", "a", "b"])
    }
}

final class FaceResultLedgerTests: XCTestCase {

    func testSettledZeroIsCachedAndDistinctFromFailure() {
        var ledger = FaceResultLedger(maxFailures: 3)
        let decision = ledger.record(id: "landscape", outcome: .settled(faceCount: 0))
        XCTAssertEqual(decision, .commit(faceCount: 0))
        XCTAssertEqual(ledger.phase(id: "landscape", storedFaceCount: 0), .noFaces)
        XCTAssertFalse(ledger.isAbandoned("landscape"))
    }

    func testSettledFacesCommit() {
        var ledger = FaceResultLedger()
        XCTAssertEqual(
            ledger.record(id: "group", outcome: .settled(faceCount: 4)),
            .commit(faceCount: 4)
        )
        XCTAssertEqual(ledger.committed["group"], 4)
        XCTAssertEqual(ledger.phase(id: "group", storedFaceCount: 4), .faces(4))
    }

    func testNegativeCountClampsToZero() {
        var ledger = FaceResultLedger()
        XCTAssertEqual(
            ledger.record(id: "x", outcome: .settled(faceCount: -2)),
            .commit(faceCount: 0)
        )
    }

    func testUnavailableRetriesThenAbandonsWithoutCommitting() {
        var ledger = FaceResultLedger(maxFailures: 3)
        XCTAssertEqual(ledger.record(id: "busy", outcome: .unavailable), .retry)
        XCTAssertEqual(ledger.phase(id: "busy", storedFaceCount: nil), .pending)
        XCTAssertEqual(ledger.record(id: "busy", outcome: .unavailable), .retry)
        XCTAssertEqual(ledger.record(id: "busy", outcome: .unavailable), .retry)
        XCTAssertEqual(ledger.record(id: "busy", outcome: .unavailable), .abandon)
        XCTAssertNil(ledger.committed["busy"])
        XCTAssertTrue(ledger.isAbandoned("busy"))
        XCTAssertEqual(ledger.phase(id: "busy", storedFaceCount: nil), .unavailable)
    }

    func testSuccessAfterFailuresClearsTheRetryState() {
        var ledger = FaceResultLedger(maxFailures: 2)
        _ = ledger.record(id: "p", outcome: .unavailable)
        _ = ledger.record(id: "p", outcome: .unavailable)
        XCTAssertEqual(ledger.record(id: "p", outcome: .unavailable), .abandon)
        // A fresh pass (folder reload) restores the budget, then a good
        // decode commits and the panel can leave "unavailable".
        ledger.resetAttempts("p")
        XCTAssertEqual(ledger.phase(id: "p", storedFaceCount: nil), .pending)
        XCTAssertEqual(
            ledger.record(id: "p", outcome: .settled(faceCount: 2)),
            .commit(faceCount: 2)
        )
        XCTAssertFalse(ledger.isAbandoned("p"))
        XCTAssertEqual(ledger.phase(id: "p", storedFaceCount: 2), .faces(2))
    }

    func testForgetDropsACommittedVerdict() {
        var ledger = FaceResultLedger()
        _ = ledger.record(id: "p", outcome: .settled(faceCount: 1))
        ledger.forget("p")
        XCTAssertNil(ledger.committed["p"])
        XCTAssertEqual(ledger.phase(id: "p", storedFaceCount: nil), .pending)
    }

    func testOnePhotoFailingDoesNotAffectAnother() {
        var ledger = FaceResultLedger(maxFailures: 1)
        _ = ledger.record(id: "bad", outcome: .unavailable)
        XCTAssertEqual(ledger.record(id: "bad", outcome: .unavailable), .abandon)
        XCTAssertEqual(
            ledger.record(id: "good", outcome: .settled(faceCount: 1)),
            .commit(faceCount: 1)
        )
        XCTAssertEqual(ledger.phase(id: "bad", storedFaceCount: nil), .unavailable)
        XCTAssertEqual(ledger.phase(id: "good", storedFaceCount: 1), .faces(1))
    }
}

final class CellCaptionTests: XCTestCase {

    func testUnratedUnlabeledIsFilenameOnly() {
        let caption = CellCaption.make(filename: "A7_2048.JPG", format: "JPG",
                                       rating: 0, rejected: false, colorLabel: 0)
        XCTAssertFalse(caption.showsColorDot)
        XCTAssertEqual(caption.mark, "")
        XCTAssertEqual(caption.filename, "A7_2048.JPG")
        XCTAssertEqual(caption.format, "JPG")
        XCTAssertFalse(caption.rejected)
    }

    func testStarsAndColorStayInTheCaption() {
        let caption = CellCaption.make(filename: "A7_2041.CR3", format: "RAW",
                                       rating: 2, rejected: false, colorLabel: 1)
        XCTAssertTrue(caption.showsColorDot)
        XCTAssertEqual(caption.colorLabel, 1)
        XCTAssertEqual(caption.mark, "★★")
        XCTAssertEqual(caption.format, "RAW")
    }

    func testRejectReplacesStars() {
        let caption = CellCaption.make(filename: "A7_2061.CR3", format: "RAW",
                                       rating: 4, rejected: true, colorLabel: 3)
        XCTAssertTrue(caption.rejected)
        XCTAssertEqual(caption.mark, "✕")
        XCTAssertTrue(caption.showsColorDot)
    }

    func testFormatTag() {
        XCTAssertEqual(CellCaption.formatTag(isRAW: true, hasJPEGPair: true, pathExtension: "cr3"), "R+J")
        XCTAssertEqual(CellCaption.formatTag(isRAW: true, hasJPEGPair: false, pathExtension: "cr3"), "RAW")
        XCTAssertEqual(CellCaption.formatTag(isRAW: false, hasJPEGPair: false, pathExtension: "jpg"), "JPG")
    }

    func testColorLabelClamps() {
        let caption = CellCaption.make(filename: "a", format: "", rating: 9, rejected: false, colorLabel: 9)
        XCTAssertEqual(caption.colorLabel, 5)
        XCTAssertEqual(caption.mark, "★★★★★")
    }

    func testFilenameLeadDoesNotDependOnRatingOrColor() {
        let samples = [
            CellCaption.make(filename: "a", format: "JPG", rating: 0, rejected: false, colorLabel: 0),
            CellCaption.make(filename: "a", format: "JPG", rating: 1, rejected: false, colorLabel: 0),
            CellCaption.make(filename: "a", format: "JPG", rating: 5, rejected: false, colorLabel: 3),
            CellCaption.make(filename: "a", format: "JPG", rating: 4, rejected: true, colorLabel: 0)
        ]
        let leads = Set(samples.map { $0.filenameLeadUnits() })
        XCTAssertEqual(leads, [CellCaption.filenameLeadUnits()])
        XCTAssertEqual(CellCaption.reservedStarColumns, 5)
        XCTAssertTrue(samples.allSatisfy { $0.mark.count <= CellCaption.reservedStarColumns })
    }
}

final class ThumbnailDeliveryTests: XCTestCase {

    func testAuthoritativeOpPublishes() {
        XCTAssertTrue(ThumbnailDelivery.shouldPublish(pendingOpIsSelf: true))
    }

    func testSupersededOpDoesNotPublish() {
        // The bug: a cancelled prefetch finished after a visible cell had
        // already registered a replacement op, stole that cell's waiters,
        // and delivered nil or a stale image. The replacement then had
        // nobody to call, so the cell stayed blank.
        XCTAssertFalse(ThumbnailDelivery.shouldPublish(pendingOpIsSelf: false))
    }
}

final class ColorLabelFilterTests: XCTestCase {

    func testEmptyFilterShowsEveryLabel() {
        for label in 0...5 {
            XCTAssertTrue(ColorLabelFilter.shows(label: label, active: []))
        }
    }

    func testActiveSetIsOR() {
        let active: Set<Int> = [1, 4]
        XCTAssertTrue(ColorLabelFilter.shows(label: 1, active: active))
        XCTAssertTrue(ColorLabelFilter.shows(label: 4, active: active))
        XCTAssertFalse(ColorLabelFilter.shows(label: 2, active: active))
        XCTAssertFalse(ColorLabelFilter.shows(label: 0, active: active))
    }

    func testToggleAddsThenRemovesBackToAll() {
        var active: Set<Int> = []
        active = ColorLabelFilter.toggle(1, in: active)
        XCTAssertEqual(active, [1])
        active = ColorLabelFilter.toggle(3, in: active)
        XCTAssertEqual(active, [1, 3])
        active = ColorLabelFilter.toggle(1, in: active)
        XCTAssertEqual(active, [3])
        active = ColorLabelFilter.toggle(3, in: active)
        XCTAssertTrue(active.isEmpty)
        XCTAssertTrue(ColorLabelFilter.shows(label: 2, active: active))
    }

    func testUnlabeledIsItsOwnClass() {
        let active = ColorLabelFilter.toggle(0, in: [])
        XCTAssertTrue(ColorLabelFilter.shows(label: 0, active: active))
        XCTAssertFalse(ColorLabelFilter.shows(label: 1, active: active))
    }
}

final class FolderTabPolicyTests: XCTestCase {

    private func tabs(_ paths: [String?]) -> [FolderTabPolicy.Tab] {
        paths.map { FolderTabPolicy.Tab(path: $0) }
    }

    func testAlreadyOpenFolderIsFocused() {
        let action = FolderTabPolicy.decide(
            opening: "/shoots/a",
            tabs: tabs(["/shoots/a", "/shoots/b"]),
            activeIndex: 1,
            replacingActive: false
        )
        XCTAssertEqual(action, .focusExisting(0))
    }

    func testEmptyActiveTabIsFilled() {
        let action = FolderTabPolicy.decide(
            opening: "/shoots/a",
            tabs: tabs([nil]),
            activeIndex: 0,
            replacingActive: false
        )
        XCTAssertEqual(action, .fillActive)
    }

    func testDifferentFolderSpawnsATab() {
        let action = FolderTabPolicy.decide(
            opening: "/shoots/b",
            tabs: tabs(["/shoots/a"]),
            activeIndex: 0,
            replacingActive: false
        )
        XCTAssertEqual(action, .spawn)
    }

    func testReplaceStaysInTheActiveTab() {
        let action = FolderTabPolicy.decide(
            opening: "/shoots/b",
            tabs: tabs(["/shoots/a", "/shoots/c"]),
            activeIndex: 0,
            replacingActive: true
        )
        XCTAssertEqual(action, .fillActive)
    }

    func testReplaceStillDedupesAnOpenFolder() {
        let action = FolderTabPolicy.decide(
            opening: "/shoots/c",
            tabs: tabs(["/shoots/a", "/shoots/c"]),
            activeIndex: 0,
            replacingActive: true
        )
        XCTAssertEqual(action, .focusExisting(1))
    }

    func testCapReusesTheOldestBackgroundTab() {
        let paths = (0..<12).map { "/shoots/\($0)" }
        let action = FolderTabPolicy.decide(
            opening: "/shoots/new",
            tabs: tabs(paths),
            activeIndex: 5,
            replacingActive: false
        )
        XCTAssertEqual(action, .reuseOldestBackground(0))
    }

    func testCapSkipsTheActiveTabWhenItIsTheOldest() {
        let paths = (0..<12).map { "/shoots/\($0)" }
        let action = FolderTabPolicy.decide(
            opening: "/shoots/new",
            tabs: tabs(paths),
            activeIndex: 0,
            replacingActive: false
        )
        XCTAssertEqual(action, .reuseOldestBackground(1))
    }
}

import XCTest
@testable import QuickCullCore

final class FolderSearchTests: XCTestCase {

    private func index(_ names: [String]) -> FolderSearchIndex {
        FolderSearchIndex(photos: names.enumerated().map { ($0.offset.description, $0.element) })
    }

    func testExactSpellingIsFound() {
        let hits = index(["IMG_4021.CR3", "IMG_4022.CR3", "notes.txt"]).hits(query: "IMG_4021.CR3")
        XCTAssertEqual(hits.map(\.name), ["IMG_4021.CR3"])
    }

    func testCaseDoesNotHideAMatch() {
        let hits = index(["IMG_2048.CR3"]).hits(query: "img_2048")
        XCTAssertEqual(hits.map(\.id), ["0"])
    }

    func testDiacriticsAndNFDMatchComposedTyping() {
        let composed = index(["Café_José.CR3"])
        XCTAssertEqual(composed.hits(query: "cafe").map(\.id), ["0"])
        XCTAssertEqual(composed.hits(query: "JOSE").map(\.id), ["0"])

        let decomposed = "Cafe\u{0301}_01.CR3"
        let nfd = index([decomposed])
        XCTAssertEqual(nfd.hits(query: "Café").map(\.id), ["0"])
        XCTAssertEqual(FolderSearchIndex.fold("Café_01.CR3"), FolderSearchIndex.fold(decomposed))
    }

    func testJpegQueryFindsTheRawPairByStem() {
        let hits = index(["IMG_4021.CR3", "Other.JPG"]).hits(query: "IMG_4021.JPG")
        XCTAssertEqual(hits.first?.name, "IMG_4021.CR3")
    }

    func testSuffixDigitsPreferTheFrameNumber() {
        let hits = index(["MWP16954.CR3", "MWP36954.CR3", "X69540.CR3"]).hits(query: "6954")
        XCTAssertEqual(hits.map(\.name), ["MWP16954.CR3", "MWP36954.CR3", "X69540.CR3"])
    }

    func testExactNameIsNotCrowdedOutByEarlierPrefixes() {
        var names: [String] = (0..<40).map { String(format: "DSC_%04d.NEF", $0) }
        names.append("Wedding_Ceremony.CR3")
        let hits = index(names).hits(query: "Wedding_Ceremony", limit: 5)
        XCTAssertEqual(hits.first?.name, "Wedding_Ceremony.CR3")
    }

    func testFullFolderNotAFilteredSubset() {
        // The grid used to hand search only the photos still on screen.
        // A red-filtered view dropped a correctly spelled unlabeled file.
        let full = index(["Red_01.CR3", "Ceremony.CR3", "Blue_02.CR3"])
        let filtered = index(["Red_01.CR3"])
        XCTAssertEqual(full.hits(query: "Ceremony").map(\.name), ["Ceremony.CR3"])
        XCTAssertTrue(filtered.hits(query: "Ceremony").isEmpty)
    }

    func testEmptyQueryMatchesNothing() {
        XCTAssertTrue(index(["A.JPG"]).hits(query: "   ").isEmpty)
    }
}

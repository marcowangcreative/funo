import XCTest
@testable import QuickCullCore

final class DriveSearchTests: XCTestCase {

    private func item(_ path: String, folder: Bool) -> DriveSearchMerge.Item {
        DriveSearchMerge.Item(path: path, name: (path as NSString).lastPathComponent, isFolder: folder)
    }

    func testCurrentFolderRanksBeforeDriveHits() {
        let rows = DriveSearchMerge.rows(
            currentHits: [("id-here", "Ceremony.CR3")],
            currentIDs: ["/Jobs/Day/Ceremony.CR3"],
            currentFolderPath: "/Jobs/Day",
            recents: ["/Archive/Ceremony Selects"],
            spotlight: [
                item("/Volumes/Card/Ceremony.CR3", folder: false),
                item("/Volumes/Card/Ceremony", folder: true)
            ],
            query: "Ceremony",
            home: "/Users/ada"
        )
        XCTAssertEqual(rows.map(\.kind), [
            .currentFile(id: "id-here"),
            .folder,
            .folder,
            .driveFile
        ])
        XCTAssertEqual(rows.map(\.name), [
            "Ceremony.CR3",
            "Ceremony Selects",
            "Ceremony",
            "Ceremony.CR3"
        ])
    }

    func testInFolderSpotlightFileIsNotRepeated() {
        let rows = DriveSearchMerge.rows(
            currentHits: [("/Jobs/Day/IMG_4021.CR3", "IMG_4021.CR3")],
            currentIDs: ["/Jobs/Day/IMG_4021.CR3"],
            currentFolderPath: "/Jobs/Day",
            recents: [],
            spotlight: [
                item("/Jobs/Day/IMG_4021.CR3", folder: false),
                item("/Jobs/Day/IMG_4021.JPG", folder: false)
            ],
            query: "IMG_4021",
            home: ""
        )
        XCTAssertEqual(rows.map(\.kind), [.currentFile(id: "/Jobs/Day/IMG_4021.CR3")])
    }

    func testLibraryAndSystemPathsAreDropped() {
        XCTAssertFalse(DriveSearchMerge.includePath("/Users/ada/Library/Caches/Ceremony"))
        XCTAssertFalse(DriveSearchMerge.includePath("/System/Library/Ceremony"))
        XCTAssertFalse(DriveSearchMerge.includePath("/Users/ada/.Trash/Ceremony"))
        XCTAssertTrue(DriveSearchMerge.includePath("/Volumes/Card/Ceremony"))
        let rows = DriveSearchMerge.rows(
            currentHits: [],
            currentIDs: [],
            currentFolderPath: "/Jobs/Day",
            recents: ["/Users/ada/Library/Ceremony"],
            spotlight: [item("/System/Library/Ceremony", folder: true)],
            query: "Ceremony",
            home: "/Users/ada"
        )
        XCTAssertTrue(rows.isEmpty)
    }

    func testJpegQueryStillFindsRawInTheOpenFolderAndACopyOnACard() {
        let index = FolderSearchIndex(photos: [("/Jobs/Day/IMG_4021.CR3", "IMG_4021.CR3")])
        let hits = index.hits(query: "IMG_4021.JPG", limit: 8)
        let rows = DriveSearchMerge.rows(
            currentHits: hits,
            currentIDs: Set(index.entries.map(\.id)),
            currentFolderPath: "/Jobs/Day",
            recents: [],
            spotlight: [item("/Volumes/Card/Wedding/IMG_4021.CR3", folder: false)],
            query: "IMG_4021.JPG",
            home: ""
        )
        XCTAssertEqual(rows.first?.kind, .currentFile(id: "/Jobs/Day/IMG_4021.CR3"))
        XCTAssertEqual(rows.last?.path, "/Volumes/Card/Wedding/IMG_4021.CR3")
    }

    func testParentDetailUsesHomeAbbreviation() {
        XCTAssertEqual(
            DriveSearchMerge.parentDetail("/Users/ada/Jobs/Day/IMG.CR3", home: "/Users/ada"),
            "~/Jobs/Day"
        )
    }
}

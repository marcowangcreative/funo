import XCTest
@testable import QuickCullCore

/// Marco's drives, as `find -maxdepth 4 -iname '*ashley*'` reported them.
/// Spotlight's index returned nothing for the same name.
final class VolumeNameIndexTests: XCTestCase {
    private let will = "/Volumes/MWP2026/2026 Weddings/20261010 - Ashley and Will"
    private let noboa = "/Volumes/MWP2026/2026 Portraits & Events/InCompass26/Wednesday/Ashley_Noboa_0.CR3"
    private let collin = "/Volumes/Extreme Pro/2021 Weddings/20211016 - Ashley and Collin"

    private func marcoTree() -> [VolumeNameEntry] {
        let mwp = VolumeIndexBuild.collect(
            volumeRoot: "/Volumes/MWP2026",
            volumeName: "MWP2026",
            children: [
                .folder(name: "2026 Weddings", modified: 1_700_000_000, children: [
                    .folder(name: "20261010 - Ashley and Will", modified: 1_760_140_800, children: [
                        .file(name: "IMG_1000.CR3", modified: 1_760_140_900)
                    ]),
                    .folder(name: "20260901 - Sam and Joy", modified: 1_750_000_000, children: [])
                ]),
                .folder(name: "2026 Portraits & Events", modified: 1_700_000_000, children: [
                    .folder(name: "InCompass26", modified: 1_700_000_000, children: [
                        .folder(name: "Wednesday", modified: 1_770_000_000, children: [
                            .file(name: "Ashley_Noboa_0.CR3", modified: 1_770_000_000)
                        ])
                    ])
                ]),
                .folder(name: "Catalog.lrdata", modified: 1_700_000_000, children: [
                    .file(name: "Ashley.CR3", modified: 1_770_000_100)
                ]),
                .folder(name: ".hidden", modified: 1, children: [
                    .file(name: "ashley.txt", modified: 1)
                ]),
                .file(name: "._Ashley.jpg", modified: 1)
            ])
        let extreme = VolumeIndexBuild.collect(
            volumeRoot: "/Volumes/Extreme Pro",
            volumeName: "Extreme Pro",
            children: [
                .folder(name: "2021 Weddings", modified: 1_600_000_000, children: [
                    .folder(name: "20211016 - Ashley and Collin", modified: 1_634_000_000, children: []),
                    .folder(name: "Misc", modified: 1_600_000_000, children: [
                        .folder(name: "Ashley Notes", modified: 1_620_000_000, children: [])
                    ])
                ])
            ])
        let boot = VolumeIndexBuild.collect(
            volumeRoot: "/",
            volumeName: "Macintosh HD",
            children: [
                .folder(name: "System", modified: 1, children: [
                    .folder(name: "Library", modified: 1, children: [
                        .file(name: "ashley.plist", modified: 1)
                    ])
                ]),
                .folder(name: "Volumes", modified: 1, children: [
                    .folder(name: "MWP2026", modified: 1, children: [
                        .file(name: "should-not-be-walked-twice.txt", modified: 1)
                    ])
                ])
            ])
        return mwp + extreme + boot
    }

    func testAshleyReturnsTheThreeRealHitsWithWillFirst() {
        let hits = VolumeNameIndex(entries: marcoTree()).search(query: "ashley", limit: 10)
        let paths = hits.map(\.path)
        XCTAssertEqual(paths.first, will)
        XCTAssertTrue(paths.contains(collin))
        XCTAssertTrue(paths.contains(noboa))
        XCTAssertLessThan(paths.firstIndex(of: will)!, paths.firstIndex(of: collin)!)
        XCTAssertLessThan(paths.firstIndex(of: collin)!, paths.firstIndex(of: noboa)!)
        XCTAssertFalse(paths.contains("/Volumes/MWP2026/Catalog.lrdata/Ashley.CR3"))
        XCTAssertFalse(paths.contains("/Volumes/MWP2026/.hidden/ashley.txt"))
        XCTAssertFalse(paths.contains("/Volumes/MWP2026/._Ashley.jpg"))
        XCTAssertFalse(paths.contains("/System/Library/ashley.plist"))
        XCTAssertFalse(paths.contains("/Volumes/MWP2026/should-not-be-walked-twice.txt"))
        XCTAssertFalse(paths.contains { $0.contains("Sam and Joy") })
    }

    func testCaseDiacriticsAndTokensAcrossComponents() {
        let index = VolumeNameIndex(entries: marcoTree())
        XCTAssertEqual(index.search(query: "ASHLEY", limit: 1).first?.path, will)
        let accented = VolumeNameIndex(entries: [
            VolumeNameEntry(path: "/Volumes/MWP2026/Ashléy Dinner", isFolder: true, depth: 1,
                            modified: 1, volumeName: "MWP2026", volumeRoot: "/Volumes/MWP2026")
        ])
        XCTAssertEqual(accented.search(query: "ashley").map(\.name), ["Ashléy Dinner"])

        let both = index.search(query: "weddings ashley", limit: 10).map(\.path)
        XCTAssertTrue(both.contains(will))
        XCTAssertTrue(both.contains(collin))
        XCTAssertFalse(both.contains(noboa))
    }

    func testShallowerFolderBeatsADeeperOneAndANewerFile() {
        let hits = VolumeNameIndex(entries: marcoTree()).search(query: "ashley", limit: 10)
        let notes = "/Volumes/Extreme Pro/2021 Weddings/Misc/Ashley Notes"
        let paths = hits.map(\.path)
        XCTAssertLessThan(paths.firstIndex(of: collin)!, paths.firstIndex(of: notes)!)
        XCTAssertLessThan(paths.firstIndex(of: notes)!, paths.firstIndex(of: noboa)!)
        let inside = "/Volumes/MWP2026/2026 Weddings/20261010 - Ashley and Will/IMG_1000.CR3"
        XCTAssertLessThan(paths.firstIndex(of: noboa)!, paths.firstIndex(of: inside)!)
    }

    func testSubtreeReplaceDropsOnlyThatBranch() {
        var index = VolumeNameIndex(entries: marcoTree())
        let renamed = VolumeNameEntry(
            path: "/Volumes/MWP2026/2026 Weddings/20261010 - Ashley and William",
            isFolder: true, depth: 2, modified: 1_760_140_800,
            volumeName: "MWP2026", volumeRoot: "/Volumes/MWP2026")
        index.replaceSubtree(
            prefix: "/Volumes/MWP2026/2026 Weddings/20261010 - Ashley and Will",
            entries: [renamed])
        let paths = index.search(query: "ashley", limit: 10).map(\.path)
        XCTAssertFalse(paths.contains(will))
        XCTAssertFalse(paths.contains("/Volumes/MWP2026/2026 Weddings/20261010 - Ashley and Will/IMG_1000.CR3"))
        XCTAssertTrue(paths.contains(renamed.path))
        XCTAssertTrue(paths.contains(collin))
        XCTAssertTrue(paths.contains(noboa))
    }

    func testCacheRoundTrip() {
        let entries = marcoTree()
        let decoded = VolumeIndexCodec.decode(VolumeIndexCodec.encode(entries))
        XCTAssertEqual(decoded, entries)
        XCTAssertNil(VolumeIndexCodec.decode(Data("nope".utf8)))
    }

    func testMergeShowsTheDriveNameAndKeepsWillNearTheTop() {
        let rows = DriveSearchMerge.rows(
            currentHits: [],
            currentIDs: [],
            currentFolderPath: "",
            recents: [],
            spotlight: [],
            query: "ashley",
            home: "/Users/marco",
            indexed: marcoTree(),
            bootVolumeName: "Macintosh HD"
        )
        XCTAssertEqual(rows.first?.path, will)
        XCTAssertEqual(rows.first?.kind, .folder)
        XCTAssertTrue(rows.first?.detail.contains("MWP2026") == true)
        let paths = rows.map(\.path)
        XCTAssertTrue(paths.contains(collin))
        XCTAssertTrue(paths.contains(noboa))
        XCTAssertLessThan(paths.firstIndex(of: will)!, paths.firstIndex(of: collin)!)
        XCTAssertLessThan(paths.firstIndex(of: collin)!, paths.firstIndex(of: noboa)!)
        XCTAssertTrue(rows.first { $0.path == collin }?.detail.contains("Extreme Pro") == true)
        XCTAssertEqual(rows.first { $0.path == noboa }?.kind, .driveFile)
    }
}

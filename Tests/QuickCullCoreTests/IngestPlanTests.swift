import XCTest
@testable import QuickCullCore

final class IngestNamingTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }
    private var date: Date {
        Date(timeIntervalSince1970: 1_762_300_800) // 2025-11-05 00:00 UTC
    }

    func testRenameOffKeepsTheOriginalStem() {
        let stem = IngestNaming.renderStem(
            pattern: "{date}_{seq}",
            renameEnabled: false,
            sequence: 3,
            ingest: 4,
            date: date,
            originalStem: "IMG_4021",
            calendar: calendar
        )
        XCTAssertEqual(stem, "IMG_4021")
    }

    func testEmptyPatternKeepsTheOriginalStem() {
        let stem = IngestNaming.renderStem(
            pattern: "   ",
            renameEnabled: true,
            sequence: 1,
            ingest: 1,
            date: date,
            originalStem: "IMG_4021",
            calendar: calendar
        )
        XCTAssertEqual(stem, "IMG_4021")
    }

    func testTokensSubstituteWithoutAHiddenCounter() {
        let stem = IngestNaming.renderStem(
            pattern: "{job}_{date}",
            renameEnabled: true,
            sequence: 7,
            ingest: 4,
            date: date,
            originalStem: "IMG_4021",
            job: "Chen/Wedding",
            calendar: calendar
        )
        XCTAssertEqual(stem, "Chen-Wedding_20251105")
        XCTAssertFalse(stem.contains("_0007"))
    }

    func testSequenceAndOriginalName() {
        let stem = IngestNaming.renderStem(
            pattern: "{iseq}_{name}_{seq}",
            renameEnabled: true,
            sequence: 12,
            ingest: 3,
            date: date,
            originalStem: "IMG_4021",
            calendar: calendar
        )
        XCTAssertEqual(stem, "03_IMG_4021_0012")
    }
}

final class IngestTemplateTests: XCTestCase {
    func testMigrationKeepsLegacyFoldersAndDoesNotDropNames() {
        let migrated = IngestTemplates.migrate(
            folderLists: ["Wedding": ["01 Ceremony", "02 Reception/Speeches"]],
            pathPatterns: ["Wedding": "{Job}/{YYYY}"]
        )
        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated[0].pathPattern, "{Job}/{YYYY}")
        XCTAssertEqual(migrated[0].subfolders, ["01 Ceremony", "02 Reception/Speeches"])
    }

    func testLegacyOnlyTemplateDefaultsPatternToJob() {
        let migrated = IngestTemplates.migrate(
            folderLists: ["Basic Shoot": ["Selects", "Alts"], "Unsafe": ["../etc"]],
            pathPatterns: [:]
        )
        let basic = migrated.first { $0.name == "Basic Shoot" }
        XCTAssertEqual(basic?.pathPattern, "{Job}")
        XCTAssertEqual(basic?.subfolders, ["Selects", "Alts"])
        XCTAssertEqual(migrated.first { $0.name == "Unsafe" }?.subfolders, [])
    }

    func testSavedPatternWinsAndUnknownPatternIsKept() {
        let migrated = IngestTemplates.migrate(
            folderLists: [:],
            pathPatterns: ["Studio": "{Job}/{Camera}"]
        )
        XCTAssertEqual(migrated.first?.name, "Studio")
        XCTAssertEqual(migrated.first?.pathPattern, "{Job}/{Camera}")
        XCTAssertEqual(migrated.first?.subfolders, [])
    }

    func testExamplePath() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 1_762_300_800)
        let path = IngestTemplates.render(
            pattern: "{Job}/{YYYY}/{MM}/{DD}",
            job: "Chen Wedding",
            date: date,
            calendar: cal
        )
        XCTAssertEqual(path, "Chen Wedding/2025/11/05")
    }

    func testPatternRejectsParentSegments() {
        let path = IngestTemplates.render(pattern: "{Job}/../secret", job: "Job")
        XCTAssertFalse(path.contains(".."))
        XCTAssertTrue(path.hasPrefix("Job"))
    }

    func testLiveFolderPreviewResolvesTheTemplate() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 1_762_300_800)
        let path = IngestTemplates.render(
            pattern: "{Job}/{YYYYMMDD}/{Camera}",
            job: "Chen Wedding",
            camera: "EOS R5",
            card: "EOS_DIGITAL",
            date: date,
            calendar: cal
        )
        XCTAssertEqual(path, "Chen Wedding/20251105/EOS R5")
    }
}

final class IngestPlannerTests: XCTestCase {
    private func file(_ name: String, stem: String, ext: String, size: Int64, folder: String = "100CANON") -> IngestSourceFile {
        IngestSourceFile(originalName: name, stem: stem, ext: ext, size: size, folderName: folder, modified: Date(timeIntervalSince1970: 0))
    }

    func testRenameOffPreservesNames() {
        let rows = IngestPlanner.rows(
            files: [file("IMG_4021.CR3", stem: "IMG_4021", ext: "CR3", size: 10)],
            renameEnabled: false,
            pattern: "{seq}",
            ingestNumber: 1,
            preserveFolders: false,
            skipDuplicates: true,
            existing: []
        )
        XCTAssertEqual(rows.first?.newName, "IMG_4021.CR3")
        XCTAssertEqual(rows.first?.note, .copy)
        XCTAssertEqual(rows.first?.relativePath, "IMG_4021.CR3")
    }

    func testPairSharesAStemAndFlattenedDatePatternIsNumberedInThePreview() {
        let rows = IngestPlanner.rows(
            files: [
                file("IMG_4022.CR3", stem: "IMG_4022", ext: "CR3", size: 20),
                file("IMG_4021.CR3", stem: "IMG_4021", ext: "CR3", size: 10),
                file("IMG_4021.JPG", stem: "IMG_4021", ext: "JPG", size: 5)
            ],
            renameEnabled: true,
            pattern: "{date}",
            ingestNumber: 1,
            preserveFolders: false,
            skipDuplicates: true,
            existing: []
        )
        let cr3 = rows.first { $0.originalName == "IMG_4021.CR3" }
        let jpg = rows.first { $0.originalName == "IMG_4021.JPG" }
        XCTAssertEqual(cr3?.newName.split(separator: ".").first, jpg?.newName.split(separator: ".").first)
        // The second RAW shares the rendered stem and is numbered. The JPEG
        // keeps the pair's stem because the extension differs.
        XCTAssertEqual(rows.filter { $0.note == .numbered }.count, 1)
        let names = Set(rows.map(\.newName))
        XCTAssertEqual(names.count, 3)
    }

    func testSameSizeCollisionSkipsAndDifferentSizeIsNumbered() {
        let rows = IngestPlanner.rows(
            files: [
                file("IMG_1.CR3", stem: "IMG_1", ext: "CR3", size: 100),
                file("IMG_2.CR3", stem: "IMG_2", ext: "CR3", size: 50)
            ],
            renameEnabled: false,
            pattern: "",
            ingestNumber: 1,
            preserveFolders: true,
            skipDuplicates: true,
            existing: [
                IngestExisting(folder: "100CANON", name: "IMG_1.CR3", size: 100),
                IngestExisting(folder: "100CANON", name: "IMG_2.CR3", size: 40)
            ]
        )
        XCTAssertEqual(rows.first { $0.originalName == "IMG_1.CR3" }?.note, .skipDuplicate)
        let second = rows.first { $0.originalName == "IMG_2.CR3" }
        XCTAssertEqual(second?.note, .numbered)
        XCTAssertEqual(second?.newName, "IMG_2 2.CR3")
        XCTAssertEqual(second?.relativePath, "100CANON/IMG_2 2.CR3")
    }

    func testRenamePreviewShowsTheArrowAndStaysPutWhenOff() {
        XCTAssertEqual(
            IngestRenamePreview.line(original: "IMG_1234.CR3", enabled: false, pattern: "{job}_{seq}"),
            "IMG_1234.CR3 → IMG_1234.CR3"
        )
        XCTAssertEqual(
            IngestRenamePreview.line(original: "IMG_1234.CR3", enabled: true, pattern: "{job}_{seq}", job: "Chen"),
            "IMG_1234.CR3 → Chen_0001.CR3"
        )
    }

    func testIncrementalSkipsADifferentSizeWithTheSameName() {
        let rows = IngestPlanner.rows(
            files: [file("IMG_1.CR3", stem: "IMG_1", ext: "CR3", size: 20)],
            renameEnabled: false,
            pattern: "{name}",
            ingestNumber: 1,
            preserveFolders: false,
            skipDuplicates: false,
            existing: [IngestExisting(folder: "", name: "IMG_1.CR3", size: 10)],
            incremental: true
        )
        XCTAssertEqual(rows.first?.note, .skipDuplicate)
    }

    func testFileKindFilter() {
        XCTAssertTrue(IngestFileKinds.allows(extension: "CR3", raw: true, jpeg: false, other: false))
        XCTAssertFalse(IngestFileKinds.allows(extension: "JPG", raw: true, jpeg: false, other: false))
        XCTAssertTrue(IngestFileKinds.allows(extension: "jpg", raw: false, jpeg: true, other: false))
        XCTAssertTrue(IngestFileKinds.allows(extension: "MOV", raw: false, jpeg: false, other: true))
        XCTAssertFalse(IngestFileKinds.allows(extension: "MOV", raw: true, jpeg: true, other: false))
    }

    func testSummaryCountsBytesOfWhatWillCopy() {
        let rows = IngestPlanner.rows(
            files: [
                file("A.CR3", stem: "A", ext: "CR3", size: 10),
                file("B.CR3", stem: "B", ext: "CR3", size: 25)
            ],
            renameEnabled: true,
            pattern: "Keep_{name}",
            ingestNumber: 1,
            preserveFolders: false,
            skipDuplicates: true,
            existing: [IngestExisting(name: "Keep_B.CR3", size: 25)]
        )
        let summary = IngestPlanner.summary(rows)
        XCTAssertEqual(summary.renamed, 1)
        XCTAssertEqual(summary.skipping, 1)
        XCTAssertEqual(summary.copying, 1)
        XCTAssertEqual(summary.bytes, 10)
    }
}

final class IngestVerifyTests: XCTestCase {
    func testMatch() {
        let result = IngestCheck.evaluate(expectedSize: 10, actualSize: 10, expectedChecksum: "abc", actualChecksum: "ABC")
        XCTAssertEqual(result, .verified)
    }

    func testSizeMismatch() {
        let result = IngestCheck.evaluate(expectedSize: 10, actualSize: 9, expectedChecksum: "abc", actualChecksum: "abc")
        XCTAssertEqual(result, .sizeMismatch(expected: 10, actual: 9))
    }

    func testChecksumMismatch() {
        let result = IngestCheck.evaluate(expectedSize: 10, actualSize: 10, expectedChecksum: "abc", actualChecksum: "def")
        XCTAssertEqual(result, .checksumMismatch)
    }

    func testMissingFile() {
        let result = IngestCheck.evaluate(expectedSize: 10, actualSize: nil, expectedChecksum: "abc", actualChecksum: nil)
        XCTAssertEqual(result, .unreadable)
    }
}

final class IngestSidecarTests: XCTestCase {
    func testXMPEscapesJobText() {
        let xml = IngestSidecar.xmp(job: "A & B <studio>", originalName: "IMG_1.CR3")
        XCTAssertTrue(xml.contains("A &amp; B &lt;studio&gt;"))
        XCTAssertTrue(xml.contains("IMG_1.CR3"))
        XCTAssertFalse(xml.contains("A & B"))
    }

    func testLogLineIsTabSeparated() {
        let line = IngestLog.line(when: Date(timeIntervalSince1970: 0), result: "OK", original: "a.CR3", relative: "Job/a.CR3", bytes: 12, checksum: "ff")
        XCTAssertTrue(line.contains("\tOK\t"))
        XCTAssertTrue(line.hasSuffix("\t12\tff"))
    }
}

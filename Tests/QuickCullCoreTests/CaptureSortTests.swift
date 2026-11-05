import XCTest
@testable import QuickCullCore

final class CaptureSortTests: XCTestCase {
    private func key(_ name: String, _ exif: String?, sub: String? = nil) -> CaptureSortKey {
        if let exif, let parsed = CaptureSort.parse(dateTime: exif, subsec: sub) {
            return CaptureSortKey(filename: name, hasDate: true, seconds: parsed.seconds, subsecMillis: parsed.millis)
        }
        return CaptureSortKey(filename: name, hasDate: false)
    }

    private func sorted(_ keys: [CaptureSortKey], ascending: Bool) -> [String] {
        keys.sorted { CaptureSort.isOrderedBefore($0, $1, ascending: ascending) }.map(\.filename)
    }

    func testAscendingAndDescending() {
        let early = key("A.CR3", "2026:03:15 14:22:01")
        let later = key("B.CR3", "2026:03:15 14:22:02")
        XCTAssertEqual(sorted([later, early], ascending: true), ["A.CR3", "B.CR3"])
        XCTAssertEqual(sorted([early, later], ascending: false), ["B.CR3", "A.CR3"])
    }

    func testSubsecondsBreakATieInsideTheSameSecond() {
        let first = key("B.CR3", "2026:03:15 14:22:01", sub: "100")
        let second = key("A.CR3", "2026:03:15 14:22:01", sub: "900")
        XCTAssertEqual(CaptureSort.subsecMillis("5"), 500)
        XCTAssertEqual(CaptureSort.subsecMillis("12"), 120)
        XCTAssertEqual(CaptureSort.subsecMillis("9567"), 956)
        XCTAssertEqual(sorted([second, first], ascending: true), ["B.CR3", "A.CR3"])
        XCTAssertEqual(sorted([first, second], ascending: false), ["A.CR3", "B.CR3"])
    }

    func testFilenameBreaksAnExactTimeTie() {
        let a = key("IMG_0002.CR3", "2026:03:15 14:22:01", sub: "5")
        let b = key("IMG_0001.CR3", "2026:03:15 14:22:01", sub: "5")
        XCTAssertEqual(sorted([a, b], ascending: true), ["IMG_0001.CR3", "IMG_0002.CR3"])
        XCTAssertEqual(sorted([b, a], ascending: false), ["IMG_0002.CR3", "IMG_0001.CR3"])
    }

    func testMissingDatesStayLastInBothDirections() {
        let early = key("B.CR3", "2026:03:15 14:22:01")
        let later = key("C.CR3", "2026:03:15 18:00:00")
        let missing = key("A.CR3", nil)
        XCTAssertEqual(sorted([missing, later, early], ascending: true), ["B.CR3", "C.CR3", "A.CR3"])
        XCTAssertEqual(sorted([missing, early, later], ascending: false), ["C.CR3", "B.CR3", "A.CR3"])
    }

    func testCacheKeyUsesPathSizeAndMtime() {
        var cache = CaptureDateCache()
        let identity = CaptureDateCache.identity(path: "/Vol/IMG.CR3", size: 20_000_000, mtime: 1_760_000_000)
        cache.store(CaptureDateRecord(identity: identity, hasDate: true, seconds: 10, subsecMillis: 250))
        XCTAssertEqual(
            cache.record(path: "/Vol/IMG.CR3", size: 20_000_000, mtime: 1_760_000_000)?.subsecMillis,
            250
        )
        XCTAssertNil(cache.record(path: "/Vol/IMG.CR3", size: 20_000_000, mtime: 1_760_000_001))
        XCTAssertNil(cache.record(path: "/Vol/IMG.CR3", size: 20, mtime: 1_760_000_000))
        let decoded = CaptureDateCacheCodec.decode(CaptureDateCacheCodec.encode(Array(cache.records.values)))
        XCTAssertEqual(decoded, Array(cache.records.values))
        XCTAssertNil(CaptureDateCacheCodec.decode(Data("nope".utf8)))
    }
}

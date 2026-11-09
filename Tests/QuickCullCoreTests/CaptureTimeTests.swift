import XCTest
@testable import QuickCullCore

final class CaptureTimeTests: XCTestCase {

    func testExifDateKeepsTheCameraClock() {
        XCTAssertEqual(CaptureTime.display(exif: "2026:03:15 14:22:01"), "Mar 15, 2026  14:22:01")
    }

    func testUnparsedExifIsRejected() {
        XCTAssertNil(CaptureTime.display(exif: "not a date"))
        XCTAssertNil(CaptureTime.display(exif: ""))
    }

    func testFileDateUsesTheSameStamp() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2024, month: 1, day: 2, hour: 3, minute: 4, second: 5))!
        XCTAssertEqual(CaptureTime.display(fileDate: date), "Jan 2, 2024  03:04:05")
    }
}

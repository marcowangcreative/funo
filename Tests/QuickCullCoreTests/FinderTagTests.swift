import XCTest
@testable import QuickCullCore

final class FinderTagTests: XCTestCase {
    func testLabelNumbersMatchFinder() {
        XCTAssertNil(FinderLabelColor(labelNumber: 0))
        XCTAssertEqual(FinderLabelColor(labelNumber: 1), .gray)
        XCTAssertEqual(FinderLabelColor(labelNumber: 2), .green)
        XCTAssertEqual(FinderLabelColor(labelNumber: 3), .purple)
        XCTAssertEqual(FinderLabelColor(labelNumber: 4), .blue)
        XCTAssertEqual(FinderLabelColor(labelNumber: 5), .yellow)
        XCTAssertEqual(FinderLabelColor(labelNumber: 6), .red)
        XCTAssertEqual(FinderLabelColor(labelNumber: 7), .orange)
        XCTAssertNil(FinderLabelColor(labelNumber: 8))
        XCTAssertNil(FinderLabelColor(labelNumber: -1))
    }

    func testStandardNamesAndGreyAlias() {
        XCTAssertEqual(FinderLabelColor(tagName: "Red"), .red)
        XCTAssertEqual(FinderLabelColor(tagName: "  orange "), .orange)
        XCTAssertEqual(FinderLabelColor(tagName: "YELLOW"), .yellow)
        XCTAssertEqual(FinderLabelColor(tagName: "Green"), .green)
        XCTAssertEqual(FinderLabelColor(tagName: "blue"), .blue)
        XCTAssertEqual(FinderLabelColor(tagName: "Purple"), .purple)
        XCTAssertEqual(FinderLabelColor(tagName: "Gray"), .gray)
        XCTAssertEqual(FinderLabelColor(tagName: "Grey"), .gray)
        XCTAssertNil(FinderLabelColor(tagName: "Selects"))
        XCTAssertNil(FinderLabelColor(tagName: "Reddish"))
    }

    func testMenuOrderIsTheSevenFinderColors() {
        XCTAssertEqual(
            FinderLabelColor.menuOrder,
            [.red, .orange, .yellow, .green, .blue, .purple, .gray]
        )
        XCTAssertEqual(Set(FinderLabelColor.menuOrder).count, 7)
    }

    func testResolveKeepsColorDotsAndCustomNames() {
        let tags = FinderFolderTags.resolve(
            tagNames: ["Red", "Selects", "Blue", "Red", "  ", "Work"],
            labelNumber: 0
        )
        XCTAssertEqual(tags.colors, [.red, .blue])
        XCTAssertEqual(tags.custom, ["Selects", "Work"])
        XCTAssertEqual(tags.finderTagNames, ["Red", "Blue", "Selects", "Work"])
        XCTAssertEqual(tags.finderLabelNumber, FinderLabelColor.red.rawValue)
        XCTAssertEqual(tags.summary, "Red, Blue, Selects, Work")
    }

    func testLabelNumberLeadsWhenTheNameIsMissingOrCustom() {
        let numbered = FinderFolderTags.resolve(tagNames: ["Green"], labelNumber: 6)
        XCTAssertEqual(numbered.colors, [.red, .green])
        XCTAssertTrue(numbered.custom.isEmpty)

        let renamed = FinderFolderTags.resolve(tagNames: ["Hero"], labelNumber: 7)
        XCTAssertEqual(renamed.colors, [.orange])
        XCTAssertEqual(renamed.custom, ["Hero"])

        let already = FinderFolderTags.resolve(tagNames: ["Red", "Hero"], labelNumber: 6)
        XCTAssertEqual(already.colors, [.red])
        XCTAssertEqual(already.custom, ["Hero"])
    }

    func testEmptyAndNoneStayEmpty() {
        XCTAssertEqual(FinderFolderTags.resolve(tagNames: [], labelNumber: 0), .empty)
        XCTAssertEqual(FinderFolderTags.resolve(tagNames: ["  ", ""], labelNumber: 0), .empty)
        XCTAssertEqual(FinderFolderTags.resolve(tagNames: [], labelNumber: 9), .empty)
        XCTAssertTrue(FinderFolderTags.empty.isEmpty)
    }

    func testToggleAndRemoveKeepTheOtherTags() {
        let start = FinderFolderTags.resolve(tagNames: ["Red", "Selects"], labelNumber: 0)
        let added = start.toggling(.blue)
        XCTAssertEqual(added.colors, [.red, .blue])
        XCTAssertEqual(added.custom, ["Selects"])
        let removed = added.toggling(.red)
        XCTAssertEqual(removed.colors, [.blue])
        XCTAssertEqual(removed.custom, ["Selects"])
        XCTAssertEqual(removed.removingCustom("Selects"), FinderFolderTags(colors: [.blue]))
        XCTAssertEqual(removed.removingCustom("Missing"), removed)
    }

    func testMutedColorsStayDistinctAndOffPureNeon() {
        var seen: Set<String> = []
        for color in FinderLabelColor.allCases {
            let (r, g, b) = color.rgba
            for channel in [r, g, b] {
                XCTAssertGreaterThanOrEqual(channel, 0.2)
                XCTAssertLessThanOrEqual(channel, 0.8)
            }
            seen.insert("\(r),\(g),\(b)")
        }
        XCTAssertEqual(seen.count, FinderLabelColor.allCases.count)
        XCTAssertGreaterThan(FinderLabelColor.red.rgba.r, FinderLabelColor.red.rgba.g)
        XCTAssertGreaterThan(FinderLabelColor.green.rgba.g, FinderLabelColor.green.rgba.r)
        XCTAssertGreaterThan(FinderLabelColor.blue.rgba.b, FinderLabelColor.blue.rgba.r)
    }
}

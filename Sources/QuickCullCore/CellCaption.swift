import Foundation

/// What a contact-sheet caption draws under the thumbnail.
/// The photograph itself stays bare. Color is a square in a reserved slot,
/// stars occupy a fixed 5-column slot even when empty, and the filename
/// follows those slots so a rating change cannot slide it. Format trails.
/// A light caption-row tint is drawn by the view; nothing is painted on the photo.
public struct CellCaption: Equatable {
    /// 0 hides the color square. 1...5 is the label class.
    public var colorLabel: Int
    /// Stars, a reject mark, or empty.
    public var mark: String
    public var rejected: Bool
    public var filename: String
    public var format: String

    public var showsColorDot: Bool { colorLabel > 0 }

    /// The star column is always five marks wide. Empty, reject, and five
    /// stars occupy the same slot, so the filename's start does not move.
    public static let reservedStarColumns = 5

    /// Slot units before the filename: color, gap, stars, gap.
    /// The same for every rating and every label, including none.
    public static func filenameLeadUnits() -> Int { 1 + 1 + reservedStarColumns + 1 }

    public func filenameLeadUnits() -> Int { Self.filenameLeadUnits() }

    public init(colorLabel: Int, mark: String, rejected: Bool, filename: String, format: String) {
        self.colorLabel = colorLabel
        self.mark = mark
        self.rejected = rejected
        self.filename = filename
        self.format = format
    }

    public static func formatTag(isRAW: Bool, hasJPEGPair: Bool, pathExtension: String) -> String {
        if hasJPEGPair { return "R+J" }
        if isRAW { return "RAW" }
        let ext = pathExtension.uppercased()
        return ext
    }

    public static func make(filename: String, format: String, rating: Int, rejected: Bool, colorLabel: Int) -> CellCaption {
        let mark: String
        if rejected {
            mark = "✕"
        } else if rating > 0 {
            mark = String(repeating: "★", count: min(rating, 5))
        } else {
            mark = ""
        }
        let label = min(5, max(0, colorLabel))
        return CellCaption(colorLabel: label, mark: mark, rejected: rejected,
                           filename: filename, format: format)
    }
}

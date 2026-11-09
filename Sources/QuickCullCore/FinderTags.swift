import Foundation

/// One Finder label color. Raw values are `URLResourceValues.labelNumber`
/// (0 is none and is not a case): gray 1, green 2, purple 3, blue 4,
/// yellow 5, red 6, orange 7.
public enum FinderLabelColor: Int, CaseIterable, Equatable, Sendable {
    case gray = 1
    case green = 2
    case purple = 3
    case blue = 4
    case yellow = 5
    case red = 6
    case orange = 7

    /// The order Finder's color row uses, and the order the sidebar menu uses.
    public static let menuOrder: [FinderLabelColor] = [
        .red, .orange, .yellow, .green, .blue, .purple, .gray
    ]

    public var finderName: String {
        switch self {
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .gray: return "Gray"
        }
    }

    public init?(tagName: String) {
        switch tagName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "red": self = .red
        case "orange": self = .orange
        case "yellow": self = .yellow
        case "green": self = .green
        case "blue": self = .blue
        case "purple": self = .purple
        case "gray", "grey": self = .gray
        default: return nil
        }
    }

    public init?(labelNumber: Int) {
        self.init(rawValue: labelNumber)
    }

    /// sRGB, pulled down from Finder's neon chips so the dots sit in graphite.
    public var rgba: (r: Double, g: Double, b: Double) {
        switch self {
        case .red:    return (0.70, 0.34, 0.32)
        case .orange: return (0.74, 0.48, 0.26)
        case .yellow: return (0.70, 0.60, 0.30)
        case .green:  return (0.36, 0.56, 0.40)
        case .blue:   return (0.36, 0.50, 0.68)
        case .purple: return (0.52, 0.40, 0.64)
        case .gray:   return (0.52, 0.53, 0.55)
        }
    }
}

/// What the sidebar draws for one folder, and what a menu edit writes back.
/// Color dots come from the seven standard names plus `labelNumber`.
/// Anything else is a custom tag and stays text.
public struct FinderFolderTags: Equatable, Sendable {
    public var colors: [FinderLabelColor]
    public var custom: [String]

    public static let empty = FinderFolderTags(colors: [], custom: [])

    public init(colors: [FinderLabelColor] = [], custom: [String] = []) {
        self.colors = colors
        self.custom = custom
    }

    public var isEmpty: Bool { colors.isEmpty && custom.isEmpty }

    /// Names Finder should store. Colors use the canonical English tag, then
    /// custom names, so a renamed color is not required to round-trip.
    public var finderTagNames: [String] {
        colors.map(\.finderName) + custom
    }

    /// The single legacy label. Finder keeps only one; the tag names carry
    /// the rest of the colors.
    public var finderLabelNumber: Int {
        colors.first?.rawValue ?? 0
    }

    public var summary: String {
        finderTagNames.joined(separator: ", ")
    }

    /// `labelNumber` wins the first dot when that color is not already named.
    /// Known color names become dots, in the order Finder listed them.
    /// Other names stay custom, in that same order.
    public static func resolve(tagNames: [String], labelNumber: Int) -> FinderFolderTags {
        var colors: [FinderLabelColor] = []
        var custom: [String] = []
        if let label = FinderLabelColor(labelNumber: labelNumber) {
            colors.append(label)
        }
        for raw in tagNames {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { continue }
            if let color = FinderLabelColor(tagName: name) {
                if !colors.contains(color) { colors.append(color) }
            } else if !custom.contains(name) {
                custom.append(name)
            }
        }
        return FinderFolderTags(colors: colors, custom: custom)
    }

    public func toggling(_ color: FinderLabelColor) -> FinderFolderTags {
        var next = self
        if let index = next.colors.firstIndex(of: color) {
            next.colors.remove(at: index)
        } else {
            next.colors.append(color)
        }
        return next
    }

    public func removingCustom(_ name: String) -> FinderFolderTags {
        var next = self
        next.custom.removeAll { $0 == name }
        return next
    }
}

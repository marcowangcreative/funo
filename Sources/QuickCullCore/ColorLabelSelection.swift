import Foundation

/// Photo Mechanic-style "select by color class".
///
/// Labels are the app's existing classes: 0 = unlabeled, 1...5 = the color
/// classes (red, yellow, green, blue, purple). The pool is the current
/// filtered folder, in display order.
///
/// A multi-selection is a working set: everything in it that doesn't wear
/// `label` is clicked off, and the matches stay selected. A single photo (or
/// nothing) isn't a working set, so the command selects every matching photo
/// in the folder instead of collapsing to that one frame.
public enum ColorLabelSelection {

    public struct Photo: Equatable {
        public var id: String
        public var label: Int

        public init(id: String, label: Int) {
            self.id = id
            self.label = label
        }
    }

    /// Ordered ids that should be selected. Empty when nothing matches.
    public static func idsToSelect(
        displayed: [Photo],
        selectedIDs: Set<String>,
        label: Int
    ) -> [String] {
        let pool: [Photo]
        if selectedIDs.count >= 2 {
            pool = displayed.filter { selectedIDs.contains($0.id) }
        } else {
            pool = displayed
        }
        return pool.filter { $0.label == label }.map(\.id)
    }

    /// "selection" when a multi-selection was narrowed, otherwise "folder".
    /// Status copy uses this so a miss says where we looked.
    public static func scopeName(selectedCount: Int) -> String {
        selectedCount >= 2 ? "selection" : "folder"
    }
}

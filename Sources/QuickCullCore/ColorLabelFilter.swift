import Foundation

/// View filter for color labels. Empty means every label is visible — the
/// "All" state. A non-empty set keeps a photo when its label is in the set
/// (OR). Stars and rejects are a separate filter ANDed with this one by the
/// grid; this type only answers the color half.
///
/// Labels match the app: 0 = unlabeled, 1...5 = red, yellow, green, blue, purple.
public enum ColorLabelFilter {

    /// A photo with `label` stays on screen under `active`.
    public static func shows(label: Int, active: Set<Int>) -> Bool {
        active.isEmpty || active.contains(label)
    }

    /// Click a swatch. On adds it (multi-color). On again removes it.
    /// Removing the last swatch returns to All.
    public static func toggle(_ label: Int, in active: Set<Int>) -> Set<Int> {
        var next = active
        if next.contains(label) {
            next.remove(label)
        } else {
            next.insert(label)
        }
        return next
    }
}

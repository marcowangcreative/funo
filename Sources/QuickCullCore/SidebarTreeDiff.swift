import Foundation

/// Incremental edits for one level of the folder sidebar.
///
/// NSOutlineView identifies rows by object. Replacing the whole tree with
/// `reloadData` builds new objects, so expansion, selection, and scroll
/// collapse. These edits are applied in order to the live child list:
/// removals come from the end, then insertions, then moves. Replaying them
/// on the old paths yields the new paths.
public enum SidebarTreeDiff {

    public enum Edit: Equatable {
        case remove(index: Int)
        /// `key` is the stable id of the child now at `index`.
        case insert(key: String, index: Int)
        case move(key: String, from: Int, to: Int)
    }

    public static func diff(old: [String], new: [String]) -> [Edit] {
        if old == new { return [] }
        var edits: [Edit] = []
        var working = old
        for (index, key) in old.enumerated().reversed() where !new.contains(key) {
            edits.append(.remove(index: index))
            working.remove(at: index)
        }
        for (index, key) in new.enumerated() where !working.contains(key) {
            let at = min(index, working.count)
            edits.append(.insert(key: key, index: at))
            working.insert(key, at: at)
        }
        if working != new {
            for index in new.indices where working[index] != new[index] {
                guard let from = working.firstIndex(of: new[index]) else { continue }
                edits.append(.move(key: new[index], from: from, to: index))
                let item = working.remove(at: from)
                working.insert(item, at: index)
            }
        }
        return edits
    }

    /// Expansion keys that still exist, parents before children, so a restore
    /// can expand without a full reload.
    public static func preservedExpansion(_ expanded: [String], present: Set<String>) -> [String] {
        expanded.filter { present.contains($0) }.sorted { lhs, rhs in
            let left = lhs.split(separator: "/").count
            let right = rhs.split(separator: "/").count
            if left != right { return left < right }
            return lhs < rhs
        }
    }
}

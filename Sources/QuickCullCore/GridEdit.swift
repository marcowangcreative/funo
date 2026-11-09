import Foundation

/// The top visible photo and how far its top sits from the top of the
/// viewport, in points. Restoring this — not the raw scroll origin — keeps
/// the same photo in the same place after items above it disappear.
public struct VisibleAnchor: Equatable {
    public var id: String
    public var offset: Double

    public init(id: String, offset: Double) {
        self.id = id
        self.offset = offset
    }
}

/// What an in-place removal does to the grid: which rows go, which photo
/// the selection lands on, and which photo should stay pinned in view.
public struct GridRemovalPlan: Equatable {
    public var remaining: [String]
    /// Indexes in the original order, ascending.
    public var removedIndexes: [Int]
    /// The photo after the removed block, or the one before it when the
    /// block ran to the end of the grid. Nil when nothing is left.
    public var selectionID: String?
    public var anchor: VisibleAnchor?

    public init(remaining: [String], removedIndexes: [Int], selectionID: String?, anchor: VisibleAnchor?) {
        self.remaining = remaining
        self.removedIndexes = removedIndexes
        self.selectionID = selectionID
        self.anchor = anchor
    }
}

public enum GridEdit {
    /// A RAW and its JPEG companion leave together. `companions` maps either
    /// id to the other.
    public static func withCompanions(_ ids: Set<String>, companions: [String: String]) -> Set<String> {
        var out = ids
        for id in ids {
            if let other = companions[id] {
                out.insert(other)
            }
        }
        return out
    }

    public static func removalPlan(order: [String], removing: Set<String>, anchor: VisibleAnchor?) -> GridRemovalPlan {
        var removedIndexes: [Int] = []
        removedIndexes.reserveCapacity(removing.count)
        var remaining: [String] = []
        remaining.reserveCapacity(order.count)
        for (index, id) in order.enumerated() {
            if removing.contains(id) {
                removedIndexes.append(index)
            } else {
                remaining.append(id)
            }
        }
        return GridRemovalPlan(
            remaining: remaining,
            removedIndexes: removedIndexes,
            selectionID: selectionAfterRemoval(order: order, removing: removing),
            anchor: adjustedAnchor(order: order, removing: removing, anchor: anchor)
        )
    }

    /// The first survivor after the removed block. When the block includes
    /// the last photo, the survivor just before the block.
    public static func selectionAfterRemoval(order: [String], removing: Set<String>) -> String? {
        let removed = order.indices.filter { removing.contains(order[$0]) }
        guard let first = removed.first, let last = removed.last else { return nil }
        let after = order.index(after: last)
        if after < order.endIndex {
            for index in after..<order.endIndex where !removing.contains(order[index]) {
                return order[index]
            }
        }
        if first > order.startIndex {
            for index in stride(from: first - 1, through: order.startIndex, by: -1) where !removing.contains(order[index]) {
                return order[index]
            }
        }
        return nil
    }

    /// The anchored photo stays put, offset included, when it survives —
    /// including when the removed block is above, inside, or below it.
    /// When the anchored photo itself leaves, the next survivor takes its
    /// offset, or the previous survivor when nothing follows.
    public static func adjustedAnchor(order: [String], removing: Set<String>, anchor: VisibleAnchor?) -> VisibleAnchor? {
        guard let anchor else { return nil }
        guard let index = order.firstIndex(of: anchor.id) else { return nil }
        if !removing.contains(anchor.id) {
            return anchor
        }
        if index + 1 < order.count {
            for next in (index + 1)..<order.count where !removing.contains(order[next]) {
                return VisibleAnchor(id: order[next], offset: anchor.offset)
            }
        }
        if index > 0 {
            for previous in stride(from: index - 1, through: 0, by: -1) where !removing.contains(order[previous]) {
                return VisibleAnchor(id: order[previous], offset: anchor.offset)
            }
        }
        return nil
    }
}

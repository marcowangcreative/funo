import Foundation

/// Where a dragged folder lands among its new siblings, and how paths are
/// rewritten when that folder changes name or parent. The outline view keeps
/// the same row object; only the path changes.
public enum SidebarRelocation {
    public static func insertionIndex(of name: String, among siblings: [String]) -> Int {
        for (index, sibling) in siblings.enumerated() {
            if name.localizedStandardCompare(sibling) == .orderedAscending { return index }
        }
        return siblings.count
    }

    /// Case-insensitive. `"Jobs"` and `"jobs"` are the same folder on disk.
    public static func uniqueName(_ name: String, existing: [String]) -> String {
        func taken(_ candidate: String) -> Bool {
            existing.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
        }
        if !taken(name) { return name }
        var counter = 2
        while taken("\(name) \(counter)") { counter += 1 }
        return "\(name) \(counter)"
    }

    public static func joined(directory: String, name: String) -> String {
        if directory == "/" || directory.isEmpty { return "/" + name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// `nil` when `path` is not the moved folder and not inside it.
    /// `/Jobs/MovedAgain` is not inside `/Jobs/Moved`.
    public static func rekey(path: String, from: String, to: String) -> String? {
        if path == from { return to }
        let prefix = from.hasSuffix("/") ? from : from + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return to + path.dropFirst(from.count)
    }

    public static func rekeyAll(_ paths: [String], from: String, to: String) -> [String: String] {
        var out: [String: String] = [:]
        for path in paths {
            if let next = rekey(path: path, from: from, to: to) {
                out[path] = next
            }
        }
        return out
    }
}

/// A folder move this process started. FSEvents for the old path and the new
/// path are ours; applying them again would put the old row back or duplicate
/// the new one.
public struct SelfCausedMove: Equatable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }

    public func involves(_ path: String) -> Bool {
        Self.covers(path, root: from) || Self.covers(path, root: to)
    }

    /// A directory listing that still contains the pre-move path is stale.
    /// The new path is not stale: the row already lives there.
    public func isStaleSource(_ path: String) -> Bool {
        Self.covers(path, root: from)
    }

    private static func covers(_ path: String, root: String) -> Bool {
        if path == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }
}

public struct SelfCausedMoves: Equatable {
    public private(set) var items: [SelfCausedMove]

    public init(items: [SelfCausedMove] = []) {
        self.items = items
    }

    public mutating func begin(_ move: SelfCausedMove) {
        items.append(move)
    }

    public mutating func end(from: String) {
        items.removeAll { $0.from == from }
    }

    public func involves(_ path: String) -> Bool {
        items.contains { $0.involves(path) }
    }

    public func isStaleSource(_ path: String) -> Bool {
        items.contains { $0.isStaleSource(path) }
    }
}

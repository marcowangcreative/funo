import Foundation

/// What a volume walk keeps. Hidden names, AppleDouble `._` files, system
/// directories, and the inside of Lightroom packages are not searchable.
/// The package folder itself still is: the photographer may look it up by name.
public enum VolumeIndexRules {
    public enum Visit: Equatable {
        case skip
        case indexOnly
        case indexAndDescend
    }

    public static func isPackage(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".lrdata")
            || lower.hasSuffix(".lrcat-data")
            || lower.hasSuffix(".app")
            || lower.hasSuffix(".photoslibrary")
            || lower.hasSuffix(".bundle")
    }

    /// System and support trees. A job folder that happens to be named
    /// Library is not `/Library` or `~/Library`, so it stays.
    public static func isSystemPath(_ path: String) -> Bool {
        if path == "/Library" || path.hasPrefix("/Library/") { return true }
        // /System/Volumes is where APFS mounts the data volume. The rest of
        // /System is the sealed system, and it is not a photo folder.
        if path == "/System" || (path.hasPrefix("/System/") && !path.hasPrefix("/System/Volumes/")) { return true }
        if path == "/private" || path.hasPrefix("/private/") { return true }
        if path.hasPrefix("/usr/") || path == "/usr" { return true }
        if path.hasPrefix("/bin/") || path == "/bin" { return true }
        if path.hasPrefix("/sbin/") || path == "/sbin" { return true }
        if path.hasPrefix("/opt/") || path == "/opt" { return true }
        if path.hasPrefix("/dev/") || path == "/dev" { return true }
        if path.hasPrefix("/cores/") || path == "/cores" { return true }
        if path.contains("/.Trash/") || path.contains("/.Trashes/") { return true }
        if path.contains("/Backups.backupdb/") { return true }
        if path.contains("/.Spotlight-V100") || path.contains("/.fseventsd") { return true }
        if path.contains("/.DocumentRevisions-V100") || path.contains("/.TemporaryItems") { return true }
        if path.contains(".app/") { return true }
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 3, parts[0] == "Users", parts[2] == "Library" { return true }
        return false
    }

    public static func visit(name: String, path: String, isFolder: Bool, volumeRoot: String) -> Visit {
        if name.isEmpty || name.hasPrefix(".") { return .skip }
        if volumeRoot == "/", name == "Volumes" { return .skip }
        if isSystemPath(path) { return .skip }
        if isFolder, isPackage(name) { return .indexOnly }
        return isFolder ? .indexAndDescend : .indexOnly
    }
}

public struct VolumeNameEntry: Equatable {
    public var path: String
    public var name: String
    public var isFolder: Bool
    public var depth: Int
    public var modified: TimeInterval
    public var volumeName: String
    public var volumeRoot: String
    public var foldedName: String
    public var foldedPath: String

    public init(path: String, name: String? = nil, isFolder: Bool, depth: Int,
                modified: TimeInterval, volumeName: String, volumeRoot: String) {
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.isFolder = isFolder
        self.depth = depth
        self.modified = modified
        self.volumeName = volumeName
        self.volumeRoot = volumeRoot
        self.foldedName = FolderSearchIndex.fold(self.name)
        self.foldedPath = FolderSearchIndex.fold(path)
    }
}

/// One node in a test tree, or the shape the volume walker follows.
public enum VolumeScanNode: Equatable {
    case folder(name: String, modified: TimeInterval, children: [VolumeScanNode])
    case file(name: String, modified: TimeInterval)
}

public enum VolumeIndexBuild {
    public static func collect(volumeRoot: String, volumeName: String, children: [VolumeScanNode]) -> [VolumeNameEntry] {
        var out: [VolumeNameEntry] = []
        func walk(_ nodes: [VolumeScanNode], parent: String) {
            for node in nodes {
                let name: String
                let modified: TimeInterval
                let isFolder: Bool
                let kids: [VolumeScanNode]
                switch node {
                case .folder(let folderName, let when, let children):
                    name = folderName
                    modified = when
                    isFolder = true
                    kids = children
                case .file(let fileName, let when):
                    name = fileName
                    modified = when
                    isFolder = false
                    kids = []
                }
                let path = parent == "/" ? "/" + name : parent + "/" + name
                switch VolumeIndexRules.visit(name: name, path: path, isFolder: isFolder, volumeRoot: volumeRoot) {
                case .skip:
                    continue
                case .indexOnly:
                    out.append(VolumeNameEntry(
                        path: path, name: name, isFolder: isFolder,
                        depth: VolumeNameQuery.depth(of: path, volumeRoot: volumeRoot),
                        modified: modified, volumeName: volumeName, volumeRoot: volumeRoot))
                case .indexAndDescend:
                    out.append(VolumeNameEntry(
                        path: path, name: name, isFolder: true,
                        depth: VolumeNameQuery.depth(of: path, volumeRoot: volumeRoot),
                        modified: modified, volumeName: volumeName, volumeRoot: volumeRoot))
                    walk(kids, parent: path)
                }
            }
        }
        walk(children, parent: volumeRoot == "/" ? "" : volumeRoot)
        return out
    }
}

public enum VolumeNameQuery {
    public static func tokens(in query: String) -> [String] {
        FolderSearchIndex.fold(query)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    public static func volumeRoot(of path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "Volumes" {
            return "/Volumes/" + parts[1]
        }
        return "/"
    }

    public static func volumeName(of path: String, boot: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "Volumes" { return parts[1] }
        return boot
    }

    /// Levels below the volume root. The drive itself is 0.
    public static func depth(of path: String, volumeRoot: String) -> Int {
        let root = volumeRoot == "/" ? "" : volumeRoot
        var rest = path
        if !root.isEmpty, rest.hasPrefix(root) {
            rest.removeFirst(root.count)
        }
        return rest.split(separator: "/").filter { !$0.isEmpty }.count
    }

    public static func detail(volumeName: String, path: String, home: String) -> String {
        let parent = DriveSearchMerge.parentDetail(path, home: home)
        if volumeName.isEmpty { return parent }
        if parent.isEmpty || parent == "/Volumes/\(volumeName)" || parent == "~" { return volumeName }
        return volumeName + "  ·  " + parent
    }

    /// Relative components only, so the volume's own name does not make
    /// every file on Extreme Pro match the query "extreme".
    public static func relativeComponents(_ entry: VolumeNameEntry) -> [String] {
        let root = FolderSearchIndex.fold(entry.volumeRoot)
        var path = entry.foldedPath
        if root != "/", path.hasPrefix(root) {
            path.removeFirst(root.count)
        }
        return path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
    }

    public static func words(_ folded: String) -> [String] {
        folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Exact-word on the item's own name, then own-name substring, then
    /// folders, then shallower, then newer. Tokens may hit any component
    /// below the volume root.
    public static func rank(_ entries: [VolumeNameEntry], query: String, limit: Int) -> [VolumeNameEntry] {
        let tokens = tokens(in: query)
        guard !tokens.isEmpty, limit > 0 else { return [] }
        struct Scored {
            var exact: Bool
            var ownName: Bool
            var entry: VolumeNameEntry
        }
        var scored: [Scored] = []
        scored.reserveCapacity(min(entries.count, 256))
        for entry in entries {
            let components = relativeComponents(entry)
            let nameStem = FolderSearchIndex.stem(entry.foldedName)
            func tokenHits(_ token: String) -> Bool {
                if components.contains(where: { $0.contains(token) }) { return true }
                let stem = FolderSearchIndex.stem(token)
                return !stem.isEmpty && stem == nameStem
            }
            guard tokens.allSatisfy(tokenHits) else { continue }
            let ownWords = words(entry.foldedName)
            let stemHit = tokens.allSatisfy { token in
                let stem = FolderSearchIndex.stem(token)
                return !stem.isEmpty && stem == nameStem
            }
            let exact = stemHit || tokens.allSatisfy { ownWords.contains($0) }
            let ownName = stemHit || tokens.allSatisfy { entry.foldedName.contains($0) }
            scored.append(Scored(exact: exact, ownName: ownName, entry: entry))
        }
        scored.sort { a, b in
            if a.exact != b.exact { return a.exact }
            if a.ownName != b.ownName { return a.ownName }
            if a.entry.isFolder != b.entry.isFolder { return a.entry.isFolder }
            if a.entry.depth != b.entry.depth { return a.entry.depth < b.entry.depth }
            if a.entry.modified != b.entry.modified { return a.entry.modified > b.entry.modified }
            let byName = a.entry.foldedName.compare(b.entry.foldedName)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.entry.path < b.entry.path
        }
        if scored.count <= limit { return scored.map(\.entry) }
        return scored.prefix(limit).map(\.entry)
    }
}

public struct VolumeNameIndex: Equatable {
    public private(set) var entries: [VolumeNameEntry]

    public init(entries: [VolumeNameEntry] = []) {
        self.entries = entries
    }

    public func search(query: String, limit: Int = 80) -> [VolumeNameEntry] {
        VolumeNameQuery.rank(entries, query: query, limit: limit)
    }

    public mutating func replaceVolume(root: String, entries replacement: [VolumeNameEntry]) {
        entries.removeAll { $0.volumeRoot == root }
        entries.append(contentsOf: replacement)
    }

    /// Drop one directory (and everything under it) and insert the fresh listing.
    /// FSEvents hands the walker a changed folder; the rest of the volume stays.
    public mutating func replaceSubtree(prefix: String, entries replacement: [VolumeNameEntry]) {
        let root = prefix == "/" ? "/" : prefix
        let nested = root == "/" ? "/" : root + "/"
        entries.removeAll { $0.path == root || $0.path.hasPrefix(nested) }
        entries.append(contentsOf: replacement)
    }

    public mutating func remove(path: String, includingDescendants: Bool) {
        if includingDescendants {
            let nested = path == "/" ? "/" : path + "/"
            entries.removeAll { $0.path == path || $0.path.hasPrefix(nested) }
        } else {
            entries.removeAll { $0.path == path }
        }
    }

    /// Rewrite every entry that lived in the moved folder. Used when this
    /// process moved the folder, so an FSEvents rescan is not required.
    public mutating func rekey(from: String, to: String, volumeName: String, volumeRoot: String) {
        entries = entries.map { entry in
            guard let path = SidebarRelocation.rekey(path: entry.path, from: from, to: to) else { return entry }
            return VolumeNameEntry(
                path: path,
                isFolder: entry.isFolder,
                depth: VolumeNameQuery.depth(of: path, volumeRoot: volumeRoot),
                modified: entry.modified,
                volumeName: volumeName,
                volumeRoot: volumeRoot
            )
        }
    }

    public mutating func upsert(_ entry: VolumeNameEntry) {
        if let index = entries.firstIndex(where: { $0.path == entry.path }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }
}

/// On-disk cache. One record per line so a partial write can be ignored
/// and a full decode does not need a JSON tree of every filename.
public enum VolumeIndexCodec {
    private static let sep: Character = "\u{1f}"

    public static func encode(_ entries: [VolumeNameEntry]) -> Data {
        var text = "FUNOIDX1\n"
        text.reserveCapacity(entries.count * 80)
        for entry in entries {
            guard !entry.path.contains("\n"), !entry.path.contains(sep) else { continue }
            let kind = entry.isFolder ? "D" : "F"
            let ms = Int64((entry.modified * 1000).rounded())
            text += [kind, String(entry.depth), String(ms), entry.volumeName, entry.volumeRoot, entry.path]
                .joined(separator: String(sep))
            text += "\n"
        }
        return Data(text.utf8)
    }

    public static func decode(_ data: Data) -> [VolumeNameEntry]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "FUNOIDX1" else { return nil }
        lines.removeFirst()
        var entries: [VolumeNameEntry] = []
        entries.reserveCapacity(lines.count)
        for line in lines where !line.isEmpty {
            let parts = line.split(separator: sep, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 6,
                  parts[0] == "D" || parts[0] == "F",
                  let depth = Int(parts[1]),
                  let ms = Int64(parts[2]) else { return nil }
            entries.append(VolumeNameEntry(
                path: parts[5],
                isFolder: parts[0] == "D",
                depth: depth,
                modified: TimeInterval(ms) / 1000,
                volumeName: parts[3],
                volumeRoot: parts[4]
            ))
        }
        return entries
    }
}

import Foundation

/// How ⌘F combines the open folder, f/uno's own volume index, and Spotlight.
///
/// Current-folder files stay first (they are already ranked by
/// `FolderSearchIndex`, including files a view filter has hidden). Drive
/// hits come from the on-disk filename index. Spotlight is merged in when
/// it has something, and never required: a stale index returns nothing and
/// the volume index still answers. Folders rank above files, shallower and
/// newer above deep, exact-word matches first. Each drive row names the volume.
public enum DriveSearchMerge {

    public struct Item: Equatable {
        public var path: String
        public var name: String
        public var isFolder: Bool

        public init(path: String, name: String, isFolder: Bool) {
            self.path = path
            self.name = name
            self.isFolder = isFolder
        }
    }

    public struct Row: Equatable {
        public enum Kind: Equatable {
            case currentFile(id: String)
            case folder
            case driveFile
        }
        public var kind: Kind
        public var name: String
        public var path: String
        public var detail: String

        public init(kind: Kind, name: String, path: String, detail: String) {
            self.kind = kind
            self.name = name
            self.path = path
            self.detail = detail
        }
    }

    /// Spotlight returns a lot of support files. Keep volumes and user folders.
    public static func includePath(_ path: String) -> Bool {
        if path.contains("/Library/") { return false }
        if path == "/System" || (path.hasPrefix("/System/") && !path.hasPrefix("/System/Volumes/")) { return false }
        if path.contains("/.Trash/") || path.contains("/.Trashes/") { return false }
        if path.contains("/Backups.backupdb/") { return false }
        if path.contains(".app/") { return false }
        return true
    }

    public static func parentDetail(_ path: String, home: String) -> String {
        var parent = (path as NSString).deletingLastPathComponent
        if !home.isEmpty, parent.hasPrefix(home) {
            parent = "~" + parent.dropFirst(home.count)
        }
        return parent
    }

    public static func rows(currentHits: [(id: String, name: String)],
                            currentIDs: Set<String>,
                            currentFolderPath: String,
                            recents: [String],
                            spotlight: [Item],
                            query: String,
                            home: String,
                            indexed: [VolumeNameEntry] = [],
                            bootVolumeName: String = "Macintosh HD",
                            fileLimit: Int = 8,
                            folderLimit: Int = 8,
                            elsewhereLimit: Int = 8) -> [Row] {
        var out: [Row] = []
        var seen = Set<String>()
        func norm(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.path
        }
        let folderNorm = currentFolderPath.isEmpty ? "" : norm(currentFolderPath)
        var owned = Set(currentIDs.map(norm))

        for hit in currentHits.prefix(max(0, fileLimit)) {
            let key = norm(hit.id)
            guard seen.insert(key).inserted else { continue }
            owned.insert(key)
            out.append(Row(kind: .currentFile(id: hit.id), name: hit.name, path: hit.id, detail: ""))
        }

        guard !VolumeNameQuery.tokens(in: query).isEmpty else { return out }

        var pool: [VolumeNameEntry] = []
        var pooled = Set<String>()
        func consider(_ entry: VolumeNameEntry) {
            let key = norm(entry.path)
            guard includePath(key), pooled.insert(key).inserted else { return }
            if !entry.isFolder {
                if owned.contains(key) { return }
                if !folderNorm.isEmpty, norm((entry.path as NSString).deletingLastPathComponent) == folderNorm {
                    return
                }
            }
            pool.append(entry)
        }
        for entry in indexed { consider(entry) }
        for path in recents {
            let root = VolumeNameQuery.volumeRoot(of: path)
            consider(VolumeNameEntry(
                path: path, isFolder: true,
                depth: VolumeNameQuery.depth(of: path, volumeRoot: root),
                modified: Date.distantFuture.timeIntervalSince1970,
                volumeName: VolumeNameQuery.volumeName(of: path, boot: bootVolumeName),
                volumeRoot: root))
        }
        for item in spotlight {
            let root = VolumeNameQuery.volumeRoot(of: item.path)
            consider(VolumeNameEntry(
                path: item.path, name: item.name, isFolder: item.isFolder,
                depth: VolumeNameQuery.depth(of: item.path, volumeRoot: root),
                modified: 0,
                volumeName: VolumeNameQuery.volumeName(of: item.path, boot: bootVolumeName),
                volumeRoot: root))
        }

        let ranked = VolumeNameQuery.rank(pool, query: query, limit: max(pool.count, 1))
        var folders = 0
        var elsewhere = 0
        for entry in ranked {
            let key = norm(entry.path)
            guard seen.insert(key).inserted else { continue }
            let detail = VolumeNameQuery.detail(volumeName: entry.volumeName, path: entry.path, home: home)
            if entry.isFolder {
                guard folders < folderLimit else { continue }
                out.append(Row(kind: .folder, name: entry.name, path: entry.path, detail: detail))
                folders += 1
            } else {
                guard elsewhere < elsewhereLimit else { continue }
                out.append(Row(kind: .driveFile, name: entry.name, path: entry.path, detail: detail))
                elsewhere += 1
            }
        }
        return out
    }
}

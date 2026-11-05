import Foundation

/// How ⌘F combines the open folder with drive-wide Spotlight hits.
///
/// Current-folder files stay first (they are already ranked by
/// `FolderSearchIndex`, including files a view filter has hidden). Then
/// folders the user has opened, then other folders, then image files that
/// live somewhere else. Picking one of those opens its folder.
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
        if path.hasPrefix("/System/") { return false }
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

        let foldedQuery = FolderSearchIndex.fold(query)
        guard !foldedQuery.isEmpty else { return out }
        let queryStem = FolderSearchIndex.stem(foldedQuery)
        var folders = 0

        func addFolder(path: String, name: String) {
            guard folders < folderLimit else { return }
            let key = norm(path)
            guard includePath(key), seen.insert(key).inserted else { return }
            guard FolderSearchIndex.fold(name).contains(foldedQuery) else { return }
            out.append(Row(kind: .folder, name: name, path: path,
                           detail: parentDetail(path, home: home)))
            folders += 1
        }

        for path in recents {
            addFolder(path: path, name: (path as NSString).lastPathComponent)
        }
        for item in spotlight where item.isFolder {
            addFolder(path: item.path, name: item.name)
        }
        var elsewhere = 0
        for item in spotlight where !item.isFolder {
            guard elsewhere < elsewhereLimit else { continue }
            let key = norm(item.path)
            guard includePath(key), seen.insert(key).inserted else { continue }
            if owned.contains(key) { continue }
            if !folderNorm.isEmpty, norm((item.path as NSString).deletingLastPathComponent) == folderNorm {
                continue
            }
            let foldedName = FolderSearchIndex.fold(item.name)
            let stem = FolderSearchIndex.stem(foldedName)
            let nameHit = foldedName.contains(foldedQuery)
                || (!queryStem.isEmpty && stem == queryStem)
            guard nameHit else { continue }
            out.append(Row(kind: .driveFile, name: item.name, path: item.path,
                           detail: parentDetail(item.path, home: home)))
            elsewhere += 1
        }
        return out
    }
}

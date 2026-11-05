import AppKit
import CoreServices
import QuickCullCore

/// Filename and folder-name index for every mounted local volume.
///
/// Spotlight is not the source of truth: on Marco's Mac `mdfind -name ashley`
/// returned nothing while the folders were on disk. This walks with
/// FileManager (the same keep/skip rules as `VolumeIndexBuild`), writes a
/// cache so the next launch can answer immediately, and applies FSEvents
/// to the changed directory instead of rebuilding the tree of results.
final class VolumeIndexService {
    static let shared = VolumeIndexService()
    static let didUpdate = Notification.Name("QuickCullVolumeIndexUpdated")

    /// Read on the main thread. Set once the boot volume's name is known.
    private(set) var bootVolumeName = "Macintosh HD"
    /// Read on the main thread. True while a volume walk is still running.
    private(set) var isScanning = false

    private let indexQueue = DispatchQueue(label: "funo.volume-index")
    /// One walk at a time. A sleeping card must not fan out into a thread per directory.
    private let scanQueue = DispatchQueue(label: "funo.volume-scan", qos: .utility)
    private var index = VolumeNameIndex()
    private var volumeNames: [String: String] = [:]
    /// Volumes walked this session. The disk cache fills `volumeNames` too,
    /// and that must not skip the refresh.
    private var scanned: Set<String> = []
    private var stream: FSEventStreamRef?
    private var saveWork: DispatchWorkItem?
    private var rescanWork: DispatchWorkItem?
    private var pendingRescans: Set<String> = []
    private var scansInFlight = 0
    private var started = false
    private var workspaceObservers: [NSObjectProtocol] = []

    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.indexQueue.async { self?.refreshVolumes() }
            }
            workspaceObservers.append(token)
        }
        indexQueue.async { [weak self] in
            guard let self else { return }
            self.loadCache()
            self.publish()
            self.refreshVolumes()
        }
    }

    func search(query: String, limit: Int = 80, completion: @escaping ([VolumeNameEntry]) -> Void) {
        let folded = FolderSearchIndex.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard folded.count >= 2 else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        indexQueue.async { [weak self] in
            let hits = self?.index.search(query: query, limit: limit) ?? []
            DispatchQueue.main.async { completion(hits) }
        }
    }

    // MARK: - Volumes

    private struct Volume {
        var url: URL
        var name: String
        var removable: Bool
    }

    private func refreshVolumes() {
        let found = localVolumes()
        if let boot = found.first(where: { $0.url.path == "/" }) {
            let name = boot.name
            DispatchQueue.main.async { self.bootVolumeName = name }
        }
        let live = Set(found.map(\.url.path))
        var dropped = false
        for gone in volumeNames.keys where !live.contains(gone) {
            volumeNames.removeValue(forKey: gone)
            scanned.remove(gone)
            index.replaceVolume(root: gone, entries: [])
            dropped = true
        }
        for volume in found {
            volumeNames[volume.url.path] = volume.name
            guard scanned.insert(volume.url.path).inserted else { continue }
            beginScan()
            let url = volume.url
            let name = volume.name
            scanQueue.async { [weak self] in
                guard let self else { return }
                let entries = self.scan(root: url, volumeName: name, volumeRoot: url)
                self.indexQueue.async {
                    guard self.volumeNames[url.path] != nil else {
                        self.endScan()
                        return
                    }
                    self.index.replaceVolume(root: url.path, entries: entries)
                    self.endScan()
                    self.scheduleSave()
                    self.publish()
                }
            }
        }
        rewatch(Array(volumeNames.keys))
        if dropped {
            scheduleSave()
            publish()
        }
    }

    private func localVolumes() -> [Volume] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeIsLocalKey, .volumeIsBrowsableKey, .volumeIsRemovableKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []
        var volumes: [Volume] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.volumeIsLocal == false || values?.volumeIsBrowsable == false { continue }
            let standardized = url.standardizedFileURL
            let name = values?.volumeName ?? standardized.lastPathComponent
            volumes.append(Volume(
                url: standardized,
                name: name.isEmpty ? "Macintosh HD" : name,
                removable: values?.volumeIsRemovable ?? false
            ))
        }
        volumes.sort { lhs, rhs in
            if lhs.removable != rhs.removable { return !lhs.removable }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return volumes
    }

    /// Same keep/skip decisions as `VolumeIndexBuild`. `volumeRoot` stays the
    /// drive even when `root` is a single changed folder.
    private func scan(root: URL, volumeName: String, volumeRoot: URL) -> [VolumeNameEntry] {
        let fm = FileManager.default
        let rootPath = volumeRoot.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let keySet = Set(keys)
        var entries: [VolumeNameEntry] = []
        while let item = enumerator.nextObject() as? URL {
            let url = item.standardizedFileURL
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: keySet)
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let isFolder = values?.isDirectory == true
            let path = url.path
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            switch VolumeIndexRules.visit(name: name, path: path, isFolder: isFolder, volumeRoot: rootPath) {
            case .skip:
                if isFolder { enumerator.skipDescendants() }
            case .indexOnly:
                entries.append(VolumeNameEntry(
                    path: path, name: name, isFolder: isFolder,
                    depth: VolumeNameQuery.depth(of: path, volumeRoot: rootPath),
                    modified: modified, volumeName: volumeName, volumeRoot: rootPath))
                if isFolder { enumerator.skipDescendants() }
            case .indexAndDescend:
                entries.append(VolumeNameEntry(
                    path: path, name: name, isFolder: true,
                    depth: VolumeNameQuery.depth(of: path, volumeRoot: rootPath),
                    modified: modified, volumeName: volumeName, volumeRoot: rootPath))
            }
        }
        return entries
    }

    // MARK: - FSEvents

    private func rewatch(_ roots: [String]) {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        let paths = roots.filter { !$0.isEmpty }
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
            guard let info else { return }
            let service = Unmanaged<VolumeIndexService>.fromOpaque(info).takeUnretainedValue()
            // useCFTypes hands the callback a CFArray of paths. That pointer is
            // not an UnsafeRawPointer, so the cast is a bitcast, not fromOpaque.
            let array = unsafeBitCast(eventPaths, to: NSArray.self)
            guard let paths = array as? [String] else { return }
            let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)
            service.ingest(paths: paths, flags: Array(flags))
        }
        guard let created = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(created, indexQueue)
        FSEventStreamStart(created)
        stream = created
    }

    private func ingest(paths: [String], flags: [FSEventStreamEventFlags]) {
        for (path, rawFlag) in zip(paths, flags) {
            let flag = FSFlag(rawValue: UInt32(rawFlag))
            if flag.contains(.itemIsSymlink) { continue }
            if flag.contains(.itemRemoved) {
                index.remove(path: path, includingDescendants: flag.contains(.itemIsDir))
                continue
            }
            if flag.contains(.mustScanSubDirs) || (flag.contains(.itemIsDir) && (flag.contains(.itemCreated) || flag.contains(.itemRenamed))) {
                pendingRescans.insert(path)
            } else {
                pendingRescans.insert((path as NSString).deletingLastPathComponent)
            }
        }
        scheduleRescans()
        scheduleSave()
        publish()
    }

    private func scheduleRescans() {
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let paths = self.coarsen(Array(self.pendingRescans))
            self.pendingRescans.removeAll()
            for path in paths {
                let root = VolumeNameQuery.volumeRoot(of: path)
                let name = self.volumeNames[root] ?? VolumeNameQuery.volumeName(of: path, boot: self.bootVolumeName)
                self.scanQueue.async { [weak self] in
                    guard let self else { return }
                    let directory = self.directory(for: path)
                    let entries = self.scan(
                        root: URL(fileURLWithPath: directory),
                        volumeName: name,
                        volumeRoot: URL(fileURLWithPath: root))
                    self.indexQueue.async {
                        self.index.replaceSubtree(prefix: directory, entries: entries)
                        self.scheduleSave()
                        self.publish()
                    }
                }
            }
        }
        rescanWork = work
        indexQueue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func coarsen(_ paths: [String]) -> [String] {
        var kept: [String] = []
        for path in paths.sorted() {
            if kept.contains(where: { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) { continue }
            kept.removeAll { $0.hasPrefix(path == "/" ? "/" : path + "/") }
            kept.append(path)
        }
        return kept
    }

    private func directory(for path: String) -> String {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return path
        }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    // MARK: - Cache

    private func cacheURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("QuickCull", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("volume-index.v1")
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL()),
              let entries = VolumeIndexCodec.decode(data) else { return }
        index = VolumeNameIndex(entries: entries)
        for entry in entries {
            if volumeNames[entry.volumeRoot] == nil {
                volumeNames[entry.volumeRoot] = entry.volumeName
            }
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let entries = self.index.entries
            let url = self.cacheURL()
            self.scanQueue.async {
                try? VolumeIndexCodec.encode(entries).write(to: url, options: .atomic)
            }
        }
        saveWork = work
        indexQueue.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func beginScan() {
        scansInFlight += 1
        DispatchQueue.main.async { self.isScanning = true }
    }

    private func endScan() {
        scansInFlight = max(0, scansInFlight - 1)
        if scansInFlight == 0 {
            DispatchQueue.main.async { self.isScanning = false }
        }
    }

    private func publish() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: VolumeIndexService.didUpdate, object: nil)
        }
    }
}

/// FSEvents flags arrive as a bare UInt32 on macOS; wrap them so call sites read as a set.
private struct FSFlag: OptionSet {
    let rawValue: UInt32
    static let mustScanSubDirs = FSFlag(rawValue: UInt32(kFSEventStreamEventFlagMustScanSubDirs))
    static let itemCreated = FSFlag(rawValue: UInt32(kFSEventStreamEventFlagItemCreated))
    static let itemRemoved = FSFlag(rawValue: UInt32(kFSEventStreamEventFlagItemRemoved))
    static let itemRenamed = FSFlag(rawValue: UInt32(kFSEventStreamEventFlagItemRenamed))
    static let itemIsDir = FSFlag(rawValue: UInt32(kFSEventStreamEventFlagItemIsDir))
    static let itemIsSymlink = FSFlag(rawValue: UInt32(kFSEventStreamEventFlagItemIsSymlink))
}

import AppKit
import QuickCullCore

/// One node in the lazy directory tree. Children are only read from disk
/// when the user expands the folder - never recursively.
final class FolderNode {
    /// Stable for the life of the row. Path can change on rename; the outline
    /// view keeps expansion because it holds this object, not the path.
    let stableID = UUID().uuidString
    var url: URL
    var displayName: String
    let isSectionHeader: Bool
    /// True = removable MEDIA (SD/CF card, flash stick) → card glyph.
    /// Resolved ONCE at mount enumeration; the cell renderer must never
    /// stat the volume - statfs on a sleeping drive blocks the main thread
    /// for the entire spin-up, which read as "lag when clicking a drive".
    let isRemovableMedia: Bool
    private var loadedChildren: [FolderNode]?

    init(url: URL, displayName: String? = nil, isSectionHeader: Bool = false,
         isRemovableMedia: Bool = false) {
        self.url = url
        self.displayName = displayName ?? FileManager.default.displayName(atPath: url.path)
        self.isSectionHeader = isSectionHeader
        self.isRemovableMedia = isRemovableMedia
    }

    var identityKey: String {
        isSectionHeader ? "header:\(displayName)" : stableID
    }

    var standardizedPath: String { url.standardizedFileURL.path }

    /// Point this row and its already-loaded descendants at a renamed folder
    /// without replacing the objects the outline view has expanded.
    func retarget(to newURL: URL, name: String) {
        url = newURL
        displayName = name
        guard let kids = loadedChildren else { return }
        for child in kids {
            let childURL = newURL.appendingPathComponent(child.url.lastPathComponent, isDirectory: true)
            child.retarget(to: childURL, name: child.displayName)
        }
    }

    var children: [FolderNode] {
        if let loadedChildren { return loadedChildren }
        let dirs = Self.readChildren(of: url)
        loadedChildren = dirs
        return dirs
    }

    /// The blocking enumeration, factored so the background prefetch and the
    /// synchronous fallback share one implementation.
    static func readChildren(of url: URL) -> [FolderNode] {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var dirs: [FolderNode] = []
        for child in contents {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                dirs.append(FolderNode(url: child))
            }
        }
        dirs.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return dirs
    }

    /// Warm this node's children off the main thread. On an idle external
    /// drive the first directory read stalls while the volume wakes - paying
    /// that on a background queue means the user's expand/click finds the
    /// children already cached and the main thread never blocks on the disk.
    /// One serial queue for ALL sidebar prefetching: on the concurrent
    /// global queue, one slow volume stalling an enumeration made dispatch
    /// spawn thread after thread (20+ blocked workers in the crash log).
    /// Serial means one directory read at a time - plenty, and bounded.
    private static let prefetchQueue = DispatchQueue(label: "funo.sidebar.prefetch", qos: .utility)

    func prefetchChildren() {
        guard loadedChildren == nil else { return }
        let url = self.url
        FolderNode.prefetchQueue.async { [weak self] in
            guard self != nil else { return }
            let dirs = FolderNode.readChildren(of: url)
            DispatchQueue.main.async {
                guard let self, self.loadedChildren == nil else { return }
                self.loadedChildren = dirs
            }
        }
    }

    /// Graft children read on a BACKGROUND queue (tree refresh) so the main
    /// thread never re-lists big folders while rebuilding the sidebar.
    func preloadChildren(_ kids: [FolderNode]) { loadedChildren = kids }

    func invalidateChildren() {
        loadedChildren = nil
    }

    /// Children if already read from disk - nil means "haven't looked yet".
    var childrenIfLoaded: [FolderNode]? { loadedChildren }
}

/// The left column: real folders, real drives. No library, no collections.
final class FolderSidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    var onSelectFolder: ((URL) -> Void)?
    var onOpenFolderInNewTab: ((URL) -> Void)?
    /// ⌥-click and keyboard: load into the current tab instead of spawning one.
    var onOpenFolderInPlace: ((URL) -> Void)?
    /// Fired after photos are dropped onto a folder (count, destination).
    var onFilesMoved: ((Int, URL) -> Void)?

    private var roots: [FolderNode] = []
    private let outlineView = NSOutlineView()
    private let scrollView = GraphiteScrollView()
    /// Same header objects for the life of the sidebar. New objects would
    /// collapse every group on the next reload.
    private let favoritesHeader = FolderNode(url: URL(fileURLWithPath: "/"), displayName: "FAVORITES", isSectionHeader: true)
    private let placesHeader = FolderNode(url: URL(fileURLWithPath: "/"), displayName: "PLACES", isSectionHeader: true)
    private let drivesHeader = FolderNode(url: URL(fileURLWithPath: "/Volumes"), displayName: "DRIVES", isSectionHeader: true)
    /// False until the first reloadData. Later updates are incremental.
    private var treeReady = false
    /// Structural updates can move the selection. That must not be treated
    /// as the user clicking a folder.
    private var suppressSelection = false

    override func loadView() {
        view = NSView()
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 800)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildRoots()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.title = "Folders"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.registerForDraggedTypes([.fileURL])

        // Right-click: folder management (rebuilt per click - see menuNeedsUpdate)
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        // Drives appear and disappear - keep the tree truthful.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(volumesChanged(_:)),
                              name: NSWorkspace.didMountNotification, object: nil)
        workspace.addObserver(self, selector: #selector(volumesChanged(_:)),
                              name: NSWorkspace.didUnmountNotification, object: nil)

        // Folders born in Finder: the tree can't see them until re-read. The
        // natural moment is coming BACK to f/uno (make folder in Finder,
        // ⌘-tab return) - refresh then, off-main, keeping expansion.
        NotificationCenter.default.addObserver(self, selector: #selector(appActivated(_:)),
                                               name: NSApplication.didBecomeActiveNotification,
                                               object: nil)

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        outlineView.reloadData()
        // Pre-expand the groups so the app doesn't open onto an empty pane.
        // This is the only full reload. Later updates insert and remove rows.
        for root in roots {
            outlineView.expandItem(root)
        }
        treeReady = true
    }

    // MARK: - Favorites (persisted; any folder can be pinned as a workspace)

    private var favoritePaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: "QuickCullFavorites") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "QuickCullFavorites") }
    }

    /// Favorites, places, and drives can appear or disappear. The outline
    /// rows already on screen stay the same objects, so expansion and scroll
    /// survive. A full reloadData is what was resetting the tree.
    private func syncRootStructure() {
        syncFavorites()
        syncPlaces()
        syncDrives()
        var desired: [FolderNode] = []
        if !(placesGroupChildren[ObjectIdentifier(favoritesHeader)] ?? []).isEmpty {
            desired.append(favoritesHeader)
        }
        if !(placesGroupChildren[ObjectIdentifier(placesHeader)] ?? []).isEmpty {
            desired.append(placesHeader)
        }
        if !(placesGroupChildren[ObjectIdentifier(drivesHeader)] ?? []).isEmpty {
            desired.append(drivesHeader)
        }
        applyDiff(parent: nil, desired: desired, current: roots) { self.roots = $0 }
    }

    // MARK: - Tree refresh (folders born outside f/uno)

    private var lastTreeRefreshAt = Date.distantPast

    @objc private func appActivated(_ note: Notification) {
        // Throttle: activation can fire in bursts (launch, dialogs), and a
        // refresh mid file-op would fight the progress lock.
        guard Date().timeIntervalSince(lastTreeRefreshAt) > 2.0,
              !FileOpProgress.shared.isActive else { return }
        refreshTree()
    }

    /// Re-read expanded branches off the main thread and patch each level
    /// in place. Clicking a folder or switching tabs does not come through here.
    func refreshTree() {
        guard treeReady else { return }
        lastTreeRefreshAt = Date()
        let expandedPaths = captureExpandedPaths()
        let selectedPath = selectedFolderPath()
        let scroll = scrollView.contentView.bounds.origin
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var fresh: [String: [FolderNode]] = [:]
            for path in expandedPaths {
                fresh[path] = FolderNode.readChildren(of: URL(fileURLWithPath: path))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                // Roots first (a card mounting), then each open branch.
                // Nothing here calls reloadData.
                self.syncRootStructure()
                let keep = SidebarTreeDiff.preservedExpansion(expandedPaths, present: Set(fresh.keys).union(expandedPaths))
                for path in keep {
                    guard let node = self.findNode(path: path) else { continue }
                    if let kids = fresh[path] {
                        self.applyDiff(parent: node, desired: self.reused(kids, replacing: node.childrenIfLoaded ?? []),
                                       current: node.childrenIfLoaded ?? []) {
                            node.preloadChildren($0)
                        }
                    }
                    if !self.outlineView.isItemExpanded(node) {
                        self.outlineView.expandItem(node)
                    }
                }
                self.restoreTreePosition(scroll: scroll, selectedPath: selectedPath)
            }
        }
    }

    /// Match freshly read children to the objects already in the outline,
    /// so an expanded row is not replaced by a lookalike.
    private func reused(_ fresh: [FolderNode], replacing existing: [FolderNode]) -> [FolderNode] {
        let byPath = Dictionary(uniqueKeysWithValues: existing.map { ($0.standardizedPath, $0) })
        return fresh.map { byPath[$0.standardizedPath] ?? $0 }
    }

    /// Walk the loaded tree to the node for `path` (nil if a branch on the
    /// way isn't loaded/present). Deepest matching top-level node first,
    /// mirroring reveal().
    private func findNode(path: String) -> FolderNode? {
        var topNodes: [FolderNode] = []
        for group in roots {
            topNodes.append(contentsOf: placesGroupChildren[ObjectIdentifier(group)] ?? [])
        }
        var best: FolderNode?
        for node in topNodes {
            let base = node.url.path
            if path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/") {
                if base.count > (best?.url.path.count ?? -1) { best = node }
            }
        }
        guard var current = best else { return nil }
        var hops = 0
        while current.url.path != path, hops < 64 {
            guard let next = children(of: current).first(where: {
                path == $0.url.path || path.hasPrefix($0.url.path + "/")
            }) else { return nil }
            current = next
            hops += 1
        }
        return current.url.path == path ? current : nil
    }

    @objc private func refreshFolders(_ sender: Any?) { refreshTree() }

    private func buildRoots() {
        syncFavorites()
        syncPlaces()
        syncDrives()
        var desired: [FolderNode] = []
        if !(placesGroupChildren[ObjectIdentifier(favoritesHeader)] ?? []).isEmpty {
            desired.append(favoritesHeader)
        }
        if !(placesGroupChildren[ObjectIdentifier(placesHeader)] ?? []).isEmpty {
            desired.append(placesHeader)
        }
        if !(placesGroupChildren[ObjectIdentifier(drivesHeader)] ?? []).isEmpty {
            desired.append(drivesHeader)
        }
        roots = desired
    }

    private func syncFavorites() {
        let fm = FileManager.default
        let current = placesGroupChildren[ObjectIdentifier(favoritesHeader)] ?? []
        let desired = favoritePaths.filter { fm.fileExists(atPath: $0) }.map { path -> FolderNode in
            let standard = URL(fileURLWithPath: path).standardizedFileURL.path
            return current.first { $0.standardizedPath == standard }
                ?? FolderNode(url: URL(fileURLWithPath: path))
        }
        applyDiff(parent: favoritesHeader, desired: desired, current: current) {
            self.placesGroupChildren[ObjectIdentifier(self.favoritesHeader)] = $0
        }
    }

    private func syncPlaces() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let current = placesGroupChildren[ObjectIdentifier(placesHeader)] ?? []
        var desired: [FolderNode] = []
        for (name, sub) in [("Pictures", "Pictures"), ("Desktop", "Desktop"), ("Downloads", "Downloads")] {
            let url = home.appendingPathComponent(sub, isDirectory: true)
            guard fm.fileExists(atPath: url.path) else { continue }
            let standard = url.standardizedFileURL.path
            desired.append(current.first { $0.standardizedPath == standard }
                           ?? FolderNode(url: url, displayName: name))
        }
        let homePath = home.standardizedFileURL.path
        desired.append(current.first { $0.standardizedPath == homePath }
                       ?? FolderNode(url: home, displayName: "Home"))
        applyDiff(parent: placesHeader, desired: desired, current: current) {
            self.placesGroupChildren[ObjectIdentifier(self.placesHeader)] = $0
        }
    }

    private func syncDrives() {
        let fm = FileManager.default
        let current = placesGroupChildren[ObjectIdentifier(drivesHeader)] ?? []
        var desired: [FolderNode] = []
        if let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey, .volumeIsRemovableKey],
                                              options: [.skipHiddenVolumes]) {
            for vol in volumes {
                let values = try? vol.resourceValues(forKeys: [.volumeNameKey, .volumeIsRemovableKey])
                let standard = vol.standardizedFileURL.path
                if let existing = current.first(where: { $0.standardizedPath == standard }) {
                    existing.displayName = values?.volumeName ?? vol.lastPathComponent
                    desired.append(existing)
                } else {
                    let node = FolderNode(url: vol,
                                          displayName: values?.volumeName ?? vol.lastPathComponent,
                                          isRemovableMedia: values?.volumeIsRemovable ?? false)
                    // Drive rows sit under the header. Warm them so the first
                    // expand doesn't read the directory on the main thread
                    // while the disk wakes.
                    node.prefetchChildren()
                    desired.append(node)
                }
            }
        }
        applyDiff(parent: drivesHeader, desired: desired, current: current) {
            self.placesGroupChildren[ObjectIdentifier(self.drivesHeader)] = $0
        }
    }

    /// Fixed children for section-header rows (so headers don't hit the disk).
    private var placesGroupChildren: [ObjectIdentifier: [FolderNode]] = [:]

    /// Insert, remove, or move rows. The child array the data source reads
    /// is updated before each outline call. A no-op diff leaves scroll alone.
    private func applyDiff(parent: FolderNode?,
                           desired: [FolderNode],
                           current: [FolderNode],
                           store: ([FolderNode]) -> Void) {
        let parentVisible = parent == nil
            || roots.contains(where: { $0 === parent })
            || outlineView.row(forItem: parent!) >= 0
        if !treeReady || !parentVisible {
            store(desired)
            return
        }
        let edits = SidebarTreeDiff.diff(old: current.map(\.identityKey), new: desired.map(\.identityKey))
        if edits.isEmpty {
            store(desired)
            return
        }
        let scroll = scrollView.contentView.bounds.origin
        let selected = selectedFolderPath()
        suppressSelection = true
        defer { suppressSelection = false }
        var byKey = Dictionary(uniqueKeysWithValues: current.map { ($0.identityKey, $0) })
        for node in desired where byKey[node.identityKey] == nil {
            byKey[node.identityKey] = node
        }
        var list = current
        for edit in edits {
            switch edit {
            case .remove(let index):
                guard list.indices.contains(index) else { continue }
                list.remove(at: index)
                store(list)
                outlineView.removeItems(at: IndexSet(integer: index), inParent: parent, withAnimation: [])
            case .insert(let key, let index):
                guard let node = byKey[key] else { continue }
                let at = min(index, list.count)
                list.insert(node, at: at)
                store(list)
                outlineView.insertItems(at: IndexSet(integer: at), inParent: parent, withAnimation: [])
                if !node.isSectionHeader { node.prefetchChildren() }
            case .move(let key, let from, let to):
                guard list.indices.contains(from), list[from].identityKey == key else { continue }
                let node = list.remove(at: from)
                let at = min(to, list.count)
                list.insert(node, at: at)
                store(list)
                outlineView.moveItem(at: from, inParent: parent, to: at, inParent: parent)
            }
        }
        restoreTreePosition(scroll: scroll, selectedPath: selected)
    }

    private func captureExpandedPaths() -> [String] {
        var paths: [String] = []
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? FolderNode,
                  !node.isSectionHeader, outlineView.isItemExpanded(node) else { continue }
            paths.append(node.standardizedPath)
        }
        return paths
    }

    private func selectedFolderPath() -> String? {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FolderNode,
              !node.isSectionHeader else { return nil }
        return node.standardizedPath
    }

    private func restoreTreePosition(scroll: NSPoint, selectedPath: String?) {
        if outlineView.selectedRow < 0, let selectedPath, let node = findNode(path: selectedPath) {
            let row = outlineView.row(forItem: node)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        scrollView.contentView.scroll(to: scroll)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func children(of node: FolderNode) -> [FolderNode] {
        let kids: [FolderNode]
        if node.isSectionHeader {
            kids = placesGroupChildren[ObjectIdentifier(node)] ?? []
        } else {
            kids = node.children
        }
        // Whatever just became visible, warm its own children in the
        // background (bounded - a folder of 200 subfolders shouldn't spawn
        // 200 enumerations). Expansion then never touches the disk on main.
        for child in kids.prefix(30) { child.prefetchChildren() }
        return kids
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FolderNode else { return roots.count }
        return children(of: node).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FolderNode else { return roots[index] }
        return children(of: node)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        // Show the triangle until we KNOW better: stat-ing every visible
        // folder's children up front would crawl network volumes just to
        // draw the sidebar (Finder makes the same trade). But once a folder
        // has been expanded and found empty, drop its triangle.
        guard let node = item as? FolderNode else { return false }
        if node.isSectionHeader { return true }
        if let known = node.childrenIfLoaded { return !known.isEmpty }
        return true
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        // Expanding an empty folder teaches us it's a leaf - repaint the row
        // so its triangle disappears.
        guard let node = notification.userInfo?["NSObject"] as? FolderNode,
              !node.isSectionHeader,
              node.childrenIfLoaded?.isEmpty == true else { return }
        outlineView.reloadItem(node)
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? FolderNode)?.isSectionHeader == true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FolderNode else { return nil }

        let identifier = NSUserInterfaceItemIdentifier(node.isSectionHeader ? "HeaderCell" : "FolderCell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier

            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            cell.addSubview(text)
            cell.textField = text

            if node.isSectionHeader {
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            } else {
                let icon = NSImageView()
                icon.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(icon)
                cell.imageView = icon
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 16),
                    icon.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                    text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
        }

        cell.textField?.stringValue = node.displayName
        if node.isSectionHeader {
            cell.textField?.font = Theme.secondaryStrong
            cell.textField?.textColor = .secondaryLabelColor
        } else {
            cell.textField?.font = Theme.body
            cell.textField?.textColor = .labelColor
            // Monochrome icons: quiet grey symbols instead of the colorful
            // Finder icons - the photos should be the only color on screen.
            let path = node.url.path
            let symbolName: String
            if path == "/" {
                symbolName = "internaldrive"                    // Macintosh HD
            } else if path.hasPrefix("/Volumes/"), node.url.pathComponents.count == 3 {
                // Only true removable MEDIA (SD/CF cards, flash sticks) get
                // the card glyph. `volumeIsRemovable` is the narrow key -
                // external HDDs/SSDs are merely ejectable, not removable, so
                // they correctly get the drive glyph. (isOnRemovableVolume is
                // deliberately broader for gentle-handling and would misfire.)
                symbolName = node.isRemovableMedia ? "sdcard" : "externaldrive"
            } else {
                symbolName = "folder"
            }
            // Fallback to the Finder icon rather than EVER showing no icon.
            cell.imageView?.image = NSImage(systemSymbolName: symbolName,
                                            accessibilityDescription: node.displayName)
                ?? NSWorkspace.shared.icon(forFile: path)
            cell.imageView?.contentTintColor = .secondaryLabelColor
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? FolderNode)?.isSectionHeader == false
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if suppressSelection { return }
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FolderNode, !node.isSectionHeader else { return }
        // A RIGHT-click selects the row to show the context menu - it must
        // NOT also load the folder, or the menu's "Open in New Tab" then
        // sees it already open and dedupes to a no-op. Let the menu decide.
        if let event = NSApp.currentEvent, event.type == .rightMouseDown {
            return
        }
        // A click opens a tab (the previous folder stays put). ⌥-click and
        // keyboard moves (arrows) load into the tab you're already in, so
        // walking the tree doesn't mint a tab per row. ⌘-click is the same
        // as a plain click now; the menu still has both.
        if let event = NSApp.currentEvent,
           event.type == .leftMouseDown || event.type == .leftMouseUp {
            if event.modifierFlags.contains(.option), !event.modifierFlags.contains(.command) {
                onOpenFolderInPlace?(node.url)
            } else if event.modifierFlags.contains(.command) {
                onOpenFolderInNewTab?(node.url)
            } else {
                onSelectFolder?(node.url)
            }
        } else {
            onOpenFolderInPlace?(node.url)
        }
    }

    /// Forget cached listings along the path to `url` - folders created a
    /// moment ago (an ingest's fresh job structure) aren't in the cached
    /// tree, and reveal() would walk right past them. Invalidate every
    /// loaded node that is an ancestor of `url`; the reveal re-reads.
    func refreshBranchContaining(_ url: URL) {
        let parentPath = url.deletingLastPathComponent().standardizedFileURL.path
        if let parent = findNode(path: parentPath) {
            refreshBranch(parent)
            return
        }
        if let node = findNode(path: url.standardizedFileURL.path) {
            refreshBranch(node)
        }
    }

    /// Expand the tree down to `url`, scroll to it, select it - so a folder
    /// opened by ⌘F is also SHOWN in the nav, not just teleported to. The
    /// walk loads at most path-depth directory listings; the prefetch queue
    /// usually has them cached already.
    func reveal(_ url: URL) {
        // Deepest top-level node whose path contains the target.
        var topNodes: [FolderNode] = []
        for group in roots {
            topNodes.append(contentsOf: placesGroupChildren[ObjectIdentifier(group)] ?? [])
        }
        var best: FolderNode?
        for node in topNodes {
            let base = node.url.path
            if url.path == base || url.path.hasPrefix(base.hasSuffix("/") ? base : base + "/") {
                if best == nil || base.count > (best?.url.path.count ?? 0) { best = node }
            }
        }
        guard var current = best else { return }
        var hops = 0
        while current.url.path != url.path, hops < 32 {
            outlineView.expandItem(current)
            guard let next = children(of: current).first(where: {
                url.path == $0.url.path || url.path.hasPrefix($0.url.path + "/")
            }) else { break }
            current = next
            hops += 1
        }
        let row = outlineView.row(forItem: current)
        guard row >= 0 else { return }
        outlineView.scrollRowToVisible(row)
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// Where-you-are is GRAPHITE; brass is reserved for what you chose.
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        GraphiteRowView()
    }

    // MARK: - Drag source (folder rows can be picked up and moved)

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FolderNode, !node.isSectionHeader else { return nil }
        // Drives don't drag - moving /Volumes/X somewhere is nonsense.
        if node.url.path.hasPrefix("/Volumes/"), node.url.pathComponents.count == 3 { return nil }
        return node.url as NSURL
    }

    // MARK: - Drop target (drag photos or folders onto a folder)

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let node = item as? FolderNode, !node.isSectionHeader else { return [] }
        // A folder can't land inside itself or its own subtree.
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            let target = node.url.path.hasSuffix("/") ? node.url.path : node.url.path + "/"
            for url in urls {
                let source = url.path.hasSuffix("/") ? url.path : url.path + "/"
                if target == source || target.hasPrefix(source) { return [] }
            }
        }
        // Always drop ON the folder, never between rows.
        outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        // Finder semantics: plain drag MOVES, ⌥-drag COPIES. Returning .copy
        // gives the drag image its green + badge for free.
        return NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard let node = item as? FolderNode, !node.isSectionHeader else { return false }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        let destination = node.url
        let optionCopy = NSEvent.modifierFlags.contains(.option)
        // A drag out of the SIDEBAR moves folders (tree changes); a drag from
        // the photo grid moves only files (tree identical). Classify by source
        // now - info is only valid synchronously - so a photo drop can SKIP the
        // branch rebuild that would otherwise collapse the sidebar's expansion.
        let fromSidebar = (info.draggingSource as AnyObject?) === outlineView
        let externalDrag = info.draggingSource == nil
        // Off the main thread: dropping 2,000 photos must not beach-ball.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Cards are sacred: a drag whose source sits on removable media
            // (memory card) ALWAYS copies - no gesture may delete from a
            // card. (Safety invariant; the check is one stat per source
            // folder, done off-main.)
            let copying = optionCopy || FileOps.anyOnMemoryCard(urls)
            // Finder semantics for duplicates: ASK (keep both / skip /
            // overwrite) instead of silently minting "Name 2.CR3".
            let collisions = FileOps.collisionCount(urls, in: destination)
            let run: (FileOps.Collision) -> Void = { policy in
                // Big photo drops get a locked progress bar; folder drags are
                // one atomic rename (no bar), and small drops stay instant.
                let showProgress = !fromSidebar   // the time-based panel decides if it actually appears
                let total = urls.count
                let step = max(1, total / 100)
                if showProgress {
                    DispatchQueue.main.async {
                        FileOpProgress.shared.begin(
                            "\(copying ? "Copying" : "Moving") \(total.formatted()) photos", total: total)
                    }
                }
                let progress: ((Int) -> Void)? = showProgress ? { done in
                    if done % step == 0 || done == total {
                        DispatchQueue.main.async { FileOpProgress.shared.update(done: done) }
                    }
                } : nil
                let result = copying
                    ? FileOps.copy(urls, to: destination, onCollision: policy, onProgress: progress)
                    : FileOps.move(urls, to: destination, onCollision: policy, onProgress: progress)
                DispatchQueue.main.async { [weak self] in
                    if showProgress { FileOpProgress.shared.end() }
                    guard let self else { return }
                    FileOpsHistory.push("\(copying ? "copy" : "move") to \(destination.lastPathComponent)",
                                        kind: copying ? .copy : .move, result.records)
                    // Rebuild every affected branch BY URL, never via the
                    // drop-target `node` reference: refreshing the source
                    // parent rebuilds its children into NEW node objects,
                    // orphaning that reference and leaving a moved folder
                    // invisible in a fresh, collapsed parent until relaunch.
                    // Only a FOLDER move changes the tree. Rebuilding a branch
                    // swaps its child nodes for NEW objects and collapses
                    // everything expanded underneath - that was the tree-
                    // collapse-on-photo-drop bug. A photo drop leaves the tree
                    // identical, so skip the rebuild and keep the expansion.
                    // (Grid drops pay no stat; only sidebar/external drags look
                    // for a landed folder.)
                    let landedFolder: URL? = (fromSidebar || externalDrag)
                        ? result.records.first(where: {
                            (try? $0.to.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                          })?.to
                        : nil
                    if fromSidebar || landedFolder != nil {
                        var affected = Set(result.records.map { $0.from.deletingLastPathComponent().path })
                        affected.insert(destination.path)
                        for p in affected {
                            self.refreshBranchContaining(URL(fileURLWithPath: p))
                        }
                        if !copying, let landed = landedFolder {
                            self.reveal(landed)
                        }
                    }
                    self.onFilesMoved?(result.primaries, destination)
                }
            }
            if collisions > 0 {
                DispatchQueue.main.async {
                    guard let policy = CollisionPrompt.ask(collisions: collisions, total: urls.count,
                                                           destination: destination.lastPathComponent) else { return }
                    DispatchQueue.global(qos: .userInitiated).async { run(policy) }
                }
            } else {
                run(.keepBoth)
            }
        }
        return true
    }

    // MARK: - Context menu actions

    private var clickedNode: FolderNode? {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FolderNode, !node.isSectionHeader else { return nil }
        return node
    }

    private func promptForName(title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 230, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func refreshBranch(_ node: FolderNode) {
        guard !node.isSectionHeader else { return }
        let fresh = FolderNode.readChildren(of: node.url)
        let current = node.childrenIfLoaded ?? []
        let desired = reused(fresh, replacing: current)
        let wasExpanded = outlineView.isItemExpanded(node)
        applyDiff(parent: node, desired: desired, current: current) { node.preloadChildren($0) }
        if wasExpanded, !outlineView.isItemExpanded(node) {
            outlineView.expandItem(node)
        }
        // Disclosure triangle: an emptied folder is no longer expandable.
        outlineView.reloadItem(node, reloadChildren: false)
    }

    @objc private func ejectVolume(_ sender: Any?) {
        guard let node = clickedNode else { return }
        let volume = node.url
        Ejector.eject(volumes: [volume]) { result in
            // Success needs no fanfare - the didUnmount observer removes
            // the row and the drive vanishes, exactly like Finder.
            guard !result.succeeded else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            if let culprit = result.holders.first {
                alert.messageText = "“\(node.displayName)” wasn't ejected because “\(culprit)” is using it."
                alert.informativeText = "Close the card there, then eject again."
            } else {
                alert.messageText = "“\(node.displayName)” couldn't be ejected."
                alert.informativeText = result.failureDetail
            }
            alert.runModal()
        }
    }

    @objc private func newFolder(_ sender: Any?) {
        guard let node = clickedNode else { return }
        guard let name = promptForName(title: "New folder inside “\(node.displayName)”", initial: "New Folder") else { return }
        let dest = FileOps.uniqueDestination(for: name, in: node.url)
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            refreshBranch(node)
        } catch {
            NSSound.beep()
        }
    }

    @objc private func renameFolder(_ sender: Any?) {
        guard let node = clickedNode else { return }
        guard let name = promptForName(title: "Rename “\(node.displayName)”", initial: node.displayName),
              name != node.displayName else { return }
        let dest = node.url.deletingLastPathComponent().appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: dest.path) else { NSSound.beep(); return }
        do {
            try FileManager.default.moveItem(at: node.url, to: dest)
            node.retarget(to: dest, name: name)
            outlineView.reloadItem(node, reloadChildren: false)
            if let parent = outlineView.parent(forItem: node) as? FolderNode {
                let current = parent.isSectionHeader
                    ? (placesGroupChildren[ObjectIdentifier(parent)] ?? [])
                    : (parent.childrenIfLoaded ?? [])
                let desired = current.sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
                applyDiff(parent: parent, desired: desired, current: current) { list in
                    if parent.isSectionHeader {
                        self.placesGroupChildren[ObjectIdentifier(parent)] = list
                    } else {
                        parent.preloadChildren(list)
                    }
                }
            }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func revealInFinder(_ sender: Any?) {
        guard let node = clickedNode else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    @objc private func sendFolderToLightroom(_ sender: Any?) {
        guard let node = clickedNode else { return }
        RatingsStore.shared.flushXMPNow()   // sidecars on disk before LR reads
        LightroomBridge.send([node.url]) { ok in
            if !ok { NSSound.beep() }
        }
    }

    @objc private func applyTemplate(_ sender: NSMenuItem) {
        guard let node = clickedNode, let name = sender.representedObject as? String else { return }
        FolderTemplates.apply(name, to: node.url)
        refreshBranch(node)
    }

    @objc private func captureTemplate(_ sender: Any?) {
        guard let node = clickedNode else { return }
        let paths = FolderTemplates.capture(from: node.url)
        guard !paths.isEmpty else { NSSound.beep(); return }
        guard let name = promptForName(
            title: "Save \(paths.count) subfolder\(paths.count == 1 ? "" : "s") of “\(node.displayName)” as template",
            initial: node.displayName
        ) else { return }
        FolderTemplates.save(name: name, paths: paths)
    }

    @objc private func deleteTemplate(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        FolderTemplates.delete(name)
    }

    @objc private func editTemplates(_ sender: Any?) {
        TemplateEditor.show()
    }

    @objc private func volumesChanged(_ notification: Notification) {
        guard treeReady else { return }
        let scroll = scrollView.contentView.bounds.origin
        let selected = selectedFolderPath()
        let hadDrives = roots.contains(where: { $0 === drivesHeader })
        syncDrives()
        var desired = roots.filter { $0 !== drivesHeader }
        if !(placesGroupChildren[ObjectIdentifier(drivesHeader)] ?? []).isEmpty {
            desired.append(drivesHeader)
        }
        applyDiff(parent: nil, desired: desired, current: roots) { self.roots = $0 }
        if !hadDrives, roots.contains(where: { $0 === drivesHeader }) {
            outlineView.expandItem(drivesHeader)
        }
        restoreTreePosition(scroll: scroll, selectedPath: selected)
    }

    @objc private func openInNewTab(_ sender: Any?) {
        guard let node = clickedNode else { return }
        onOpenFolderInNewTab?(node.url)
    }

    @objc private func openInThisTab(_ sender: Any?) {
        guard let node = clickedNode else { return }
        onOpenFolderInPlace?(node.url)
    }

    @objc private func toggleFavorite(_ sender: Any?) {
        guard let node = clickedNode else { return }
        var favs = favoritePaths
        if let existing = favs.firstIndex(of: node.url.path) {
            favs.remove(at: existing)
        } else {
            favs.append(node.url.path)
        }
        favoritePaths = favs
        guard treeReady else { return }
        let scroll = scrollView.contentView.bounds.origin
        let selected = selectedFolderPath()
        let hadFavorites = roots.contains(where: { $0 === favoritesHeader })
        syncFavorites()
        var desired: [FolderNode] = []
        if !(placesGroupChildren[ObjectIdentifier(favoritesHeader)] ?? []).isEmpty {
            desired.append(favoritesHeader)
        }
        if roots.contains(where: { $0 === placesHeader }) { desired.append(placesHeader) }
        if roots.contains(where: { $0 === drivesHeader }) { desired.append(drivesHeader) }
        applyDiff(parent: nil, desired: desired, current: roots) { self.roots = $0 }
        if !hadFavorites, roots.contains(where: { $0 === favoritesHeader }) {
            outlineView.expandItem(favoritesHeader)
        }
        restoreTreePosition(scroll: scroll, selectedPath: selected)
    }
}

// MARK: - Context menu (rebuilt per right-click)

extension FolderSidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = clickedNode else { return }
        let isFavorite = favoritePaths.contains(node.url.path)

        let newTab = NSMenuItem(title: "Open in New Tab",
                                action: #selector(openInNewTab(_:)), keyEquivalent: "")
        newTab.target = self
        menu.addItem(newTab)
        let here = NSMenuItem(title: "Open in This Tab",
                              action: #selector(openInThisTab(_:)), keyEquivalent: "")
        here.target = self
        menu.addItem(here)
        let fav = NSMenuItem(title: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                             action: #selector(toggleFavorite(_:)), keyEquivalent: "")
        fav.target = self
        menu.addItem(fav)

        // Drives get Finder's courtesy: Eject, right where muscle memory
        // expects it. Volume roots only - /Volumes/Name is 3 components.
        if node.url.path.hasPrefix("/Volumes/"), node.url.pathComponents.count == 3 {
            menu.addItem(.separator())
            let eject = NSMenuItem(title: "Eject “\(node.displayName)”",
                                   action: #selector(ejectVolume(_:)), keyEquivalent: "")
            eject.target = self
            menu.addItem(eject)
        }
        menu.addItem(.separator())
        for (title, action) in [
            ("New Folder…", #selector(newFolder(_:))),
            ("Rename…", #selector(renameFolder(_:))),
            ("Refresh Folders", #selector(refreshFolders(_:))),
            ("Reveal in Finder", #selector(revealInFinder(_:)))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        // ── Folder templates ─────────────────────────────────────
        menu.addItem(.separator())

        let applyMenu = NSMenu()
        for name in FolderTemplates.names {
            let count = FolderTemplates.all[name]?.count ?? 0
            let item = NSMenuItem(title: "\(name)  (\(count) folders)",
                                  action: #selector(applyTemplate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            applyMenu.addItem(item)
        }
        if !FolderTemplates.names.isEmpty {
            applyMenu.addItem(.separator())
            let deleteMenu = NSMenu()
            for name in FolderTemplates.names {
                let item = NSMenuItem(title: name, action: #selector(deleteTemplate(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                deleteMenu.addItem(item)
            }
            let deleteRoot = NSMenuItem(title: "Delete Template", action: nil, keyEquivalent: "")
            deleteRoot.submenu = deleteMenu
            applyMenu.addItem(deleteRoot)
        }
        let applyRoot = NSMenuItem(title: "Apply Template", action: nil, keyEquivalent: "")
        applyRoot.submenu = applyMenu
        menu.addItem(applyRoot)

        let capture = NSMenuItem(title: "Save Subfolders as Template…",
                                 action: #selector(captureTemplate(_:)), keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)

        let edit = NSMenuItem(title: "Edit Templates…",
                              action: #selector(editTemplates(_:)), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)

        if LightroomBridge.isAvailable {
            menu.addItem(.separator())
            let lightroom = NSMenuItem(title: "Send Folder to Lightroom",
                                       action: #selector(sendFolderToLightroom(_:)), keyEquivalent: "")
            lightroom.target = self
            menu.addItem(lightroom)
        }
    }
}

/// Finder-style duplicate dialog, shared by the sidebar drop and ⌘V paste.
enum CollisionPrompt {
    /// nil = user cancelled the whole operation.
    static func ask(collisions: Int, total: Int, destination: String) -> FileOps.Collision? {
        let alert = NSAlert()
        alert.messageText = collisions == total
            ? (total == 1 ? "This photo already exists in “\(destination)”"
                          : "All \(total) photos already exist in “\(destination)”")
            : "\(collisions) of \(total) photos already exist in “\(destination)”"
        alert.informativeText = "Keep Both renames the incoming files - RAW+JPEG pairs and sidecars stay together. Overwrite moves the existing files to the Trash first."
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .keepBoth
        case .alertSecondButtonReturn: return .skip
        case .alertThirdButtonReturn: return .overwrite
        default: return nil
        }
    }
}

/// Source-list row that selects in quiet graphite instead of accent blue.
private final class GraphiteRowView: NSTableRowView {
    // Never "emphasized" - that's the vibrant blue path.
    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none, isSelected else { return }
        let rect = bounds.insetBy(dx: 6, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: Theme.panelRadius, yRadius: Theme.panelRadius)
        NSColor(calibratedWhite: 1, alpha: 0.09).setFill()
        path.fill()
    }
}

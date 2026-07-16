import AppKit

/// One node in the lazy directory tree. Children are only read from disk
/// when the user expands the folder — never recursively.
final class FolderNode {
    let url: URL
    let displayName: String
    let isSectionHeader: Bool
    /// True = removable MEDIA (SD/CF card, flash stick) → card glyph.
    /// Resolved ONCE at mount enumeration; the cell renderer must never
    /// stat the volume — statfs on a sleeping drive blocks the main thread
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
    /// drive the first directory read stalls while the volume wakes — paying
    /// that on a background queue means the user's expand/click finds the
    /// children already cached and the main thread never blocks on the disk.
    /// One serial queue for ALL sidebar prefetching: on the concurrent
    /// global queue, one slow volume stalling an enumeration made dispatch
    /// spawn thread after thread (20+ blocked workers in the crash log).
    /// Serial means one directory read at a time — plenty, and bounded.
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

    func invalidateChildren() {
        loadedChildren = nil
    }

    /// Children if already read from disk — nil means "haven't looked yet".
    var childrenIfLoaded: [FolderNode]? { loadedChildren }
}

/// The left column: real folders, real drives. No library, no collections.
final class FolderSidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    var onSelectFolder: ((URL) -> Void)?
    var onOpenFolderInNewTab: ((URL) -> Void)?
    /// Fired after photos are dropped onto a folder (count, destination).
    var onFilesMoved: ((Int, URL) -> Void)?

    private var roots: [FolderNode] = []
    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()

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

        // Right-click: folder management (rebuilt per click — see menuNeedsUpdate)
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        // Drives appear and disappear — keep the tree truthful.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(volumesChanged(_:)),
                              name: NSWorkspace.didMountNotification, object: nil)
        workspace.addObserver(self, selector: #selector(volumesChanged(_:)),
                              name: NSWorkspace.didUnmountNotification, object: nil)

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
        // Pre-expand the Places group so the app doesn't open onto an empty pane.
        for root in roots {
            outlineView.expandItem(root)
        }
    }

    // MARK: - Favorites (persisted; any folder can be pinned as a workspace)

    private var favoritePaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: "QuickCullFavorites") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "QuickCullFavorites") }
    }

    private func rebuildSidebar() {
        roots.removeAll()
        placesGroupChildren.removeAll()
        buildRoots()
        outlineView.reloadData()
        for root in roots { outlineView.expandItem(root) }
    }

    private func buildRoots() {
        let fm = FileManager.default

        // Favorites first — sorted output folders one click away.
        let favorites = favoritePaths
            .filter { fm.fileExists(atPath: $0) }
            .map { FolderNode(url: URL(fileURLWithPath: $0)) }
        if !favorites.isEmpty {
            let favGroup = FolderNode(url: fm.homeDirectoryForCurrentUser, displayName: "FAVORITES", isSectionHeader: true)
            placesGroupChildren[ObjectIdentifier(favGroup)] = favorites
            roots.append(favGroup)
        }

        var places: [FolderNode] = []

        let home = fm.homeDirectoryForCurrentUser
        for (name, sub) in [("Pictures", "Pictures"), ("Desktop", "Desktop"), ("Downloads", "Downloads")] {
            let url = home.appendingPathComponent(sub, isDirectory: true)
            if fm.fileExists(atPath: url.path) {
                places.append(FolderNode(url: url, displayName: name))
            }
        }
        places.append(FolderNode(url: home, displayName: "Home"))

        let placesGroup = FolderNode(url: home, displayName: "PLACES", isSectionHeader: true)
        placesGroupChildren[ObjectIdentifier(placesGroup)] = places
        roots.append(placesGroup)

        // Mounted volumes (external drives, cards, network shares).
        var drives: [FolderNode] = []
        if let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey, .volumeIsRemovableKey], options: [.skipHiddenVolumes]) {
            for vol in volumes {
                let values = try? vol.resourceValues(forKeys: [.volumeNameKey, .volumeIsRemovableKey])
                let node = FolderNode(url: vol,
                                      displayName: values?.volumeName ?? vol.lastPathComponent,
                                      isRemovableMedia: values?.volumeIsRemovable ?? false)
                // Drive rows are ROOTS — they never pass through children(of:),
                // so the visibility-driven prefetch never warms them. Without
                // this, the FIRST expand of a drive read its directory on the
                // main thread while the disk woke. Warm them up front instead.
                node.prefetchChildren()
                drives.append(node)
            }
        }
        if !drives.isEmpty {
            let drivesGroup = FolderNode(url: URL(fileURLWithPath: "/Volumes"), displayName: "DRIVES", isSectionHeader: true)
            placesGroupChildren[ObjectIdentifier(drivesGroup)] = drives
            roots.append(drivesGroup)
        }
    }

    /// Fixed children for section-header rows (so headers don't hit the disk).
    private var placesGroupChildren: [ObjectIdentifier: [FolderNode]] = [:]

    private func children(of node: FolderNode) -> [FolderNode] {
        let kids: [FolderNode]
        if node.isSectionHeader {
            kids = placesGroupChildren[ObjectIdentifier(node)] ?? []
        } else {
            kids = node.children
        }
        // Whatever just became visible, warm its own children in the
        // background (bounded — a folder of 200 subfolders shouldn't spawn
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
        // Expanding an empty folder teaches us it's a leaf — repaint the row
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
            cell.textField?.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = .secondaryLabelColor
        } else {
            cell.textField?.font = NSFont.systemFont(ofSize: 13)
            cell.textField?.textColor = .labelColor
            // Monochrome icons: quiet grey symbols instead of the colorful
            // Finder icons — the photos should be the only color on screen.
            let path = node.url.path
            let symbolName: String
            if path == "/" {
                symbolName = "internaldrive"                    // Macintosh HD
            } else if path.hasPrefix("/Volumes/"), node.url.pathComponents.count == 3 {
                // Only true removable MEDIA (SD/CF cards, flash sticks) get
                // the card glyph. `volumeIsRemovable` is the narrow key —
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
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FolderNode, !node.isSectionHeader else { return }
        // A RIGHT-click selects the row to show the context menu — it must
        // NOT also load the folder, or the menu's "Open in New Tab" then
        // sees it already open and dedupes to a no-op. Let the menu decide.
        if let event = NSApp.currentEvent, event.type == .rightMouseDown {
            return
        }
        // ⌘-click a folder → open it in a new tab (browser convention).
        // Keyboard selection changes (arrows) never spawn tabs.
        if let event = NSApp.currentEvent,
           event.type == .leftMouseDown || event.type == .leftMouseUp,
           event.modifierFlags.contains(.command) {
            onOpenFolderInNewTab?(node.url)
        } else {
            onSelectFolder?(node.url)
        }
    }

    // MARK: - Drop target (drag photos onto a folder to move them)

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let node = item as? FolderNode, !node.isSectionHeader else { return [] }
        // Always drop ON the folder, never between rows.
        outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard let node = item as? FolderNode, !node.isSectionHeader else { return false }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        let destination = node.url
        // Off the main thread: dropping 2,000 photos must not beach-ball.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = FileOps.move(urls, to: destination)
            DispatchQueue.main.async {
                FileOpsHistory.push("move to \(destination.lastPathComponent)", result.records)
                node.invalidateChildren()
                self?.outlineView.reloadItem(node, reloadChildren: true)
                self?.onFilesMoved?(result.primaries, destination)
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
        node.invalidateChildren()
        outlineView.reloadItem(node, reloadChildren: true)
        outlineView.expandItem(node)
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
            if let parent = outlineView.parent(forItem: node) as? FolderNode {
                refreshBranch(parent)
            } else {
                outlineView.reloadData()
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
        rebuildSidebar()
    }

    @objc private func openInNewTab(_ sender: Any?) {
        guard let node = clickedNode else { return }
        onOpenFolderInNewTab?(node.url)
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
        rebuildSidebar()
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
        let fav = NSMenuItem(title: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                             action: #selector(toggleFavorite(_:)), keyEquivalent: "")
        fav.target = self
        menu.addItem(fav)
        menu.addItem(.separator())
        for (title, action) in [
            ("New Folder…", #selector(newFolder(_:))),
            ("Rename…", #selector(renameFolder(_:))),
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

import AppKit
import QuickCullCore

/// ⌘F. Since 0.9.6 this palette has searched the open folder plus folders
/// anywhere (recent places immediately, then Spotlight). Files on other
/// volumes were never in that query; they are now. Current-folder hits stay
/// first, including files a view filter has hidden. Spotlight runs off the
/// main thread and only paints when a batch arrives.
final class SearchPaletteView: NSView, NSTextFieldDelegate {

    // MARK: results

    enum Result {
        case photo(id: String, name: String)
        case folder(url: URL, detail: String)
        case driveFile(url: URL, detail: String)
    }

    var onJumpToPhoto: ((String) -> Void)?
    var onOpenFolder: ((URL, _ newTab: Bool) -> Void)?
    /// A file that is not in the open folder: open its folder, then select it.
    var onOpenFile: ((URL) -> Void)?
    var onDismiss: (() -> Void)?
    /// The active folder's full index. Rebuilt when that folder's file list changes.
    var photoSource: (() -> FolderSearchIndex)?
    var currentFolderPath: (() -> String?)?

    private let panel = NSView()
    private let field = NSTextField()
    private let rowsStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var results: [Result] = []
    private var highlighted = 0
    private var activeQuery = ""
    private var searchGeneration = 0
    private var remoteItems: [DriveSearchMerge.Item] = []
    private var spotlightQuery: NSMetadataQuery?
    private var spotlightDebounce: Timer?
    private var spotlightTokens: [NSObjectProtocol] = []
    private let spotlightQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "quickcull.spotlight"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    // MARK: recents (zero-I/O folder layer)

    private static let mruKey = "FunoFolderMRU"
    static func noteRecent(_ url: URL) {
        var mru = UserDefaults.standard.stringArray(forKey: mruKey) ?? []
        mru.removeAll { $0 == url.path }
        mru.insert(url.path, at: 0)
        if mru.count > 60 { mru.removeLast(mru.count - 60) }
        UserDefaults.standard.set(mru, forKey: mruKey)
    }
    private static func recents() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: mruKey) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: setup

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Dim scrim: click anywhere outside the panel dismisses.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor

        panel.wantsLayer = true
        panel.layer?.backgroundColor = Theme.bg1.cgColor
        panel.layer?.cornerRadius = Theme.panelRadius
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = Theme.line.cgColor
        panel.layer?.shadowColor = NSColor.black.cgColor
        panel.layer?.shadowOpacity = 0.5
        panel.layer?.shadowRadius = 24
        panel.layer?.shadowOffset = CGSize(width: 0, height: -8)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        field.font = Theme.monoInput
        field.textColor = Theme.tx0
        field.placeholderString = "Frame · file · folder"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(field)

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.line.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(divider)

        rowsStack.orientation = .vertical
        rowsStack.spacing = 1
        rowsStack.alignment = .leading
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(rowsStack)

        emptyLabel.font = Theme.secondary
        emptyLabel.textColor = Theme.tx2
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 120),
            panel.widthAnchor.constraint(equalToConstant: 560),

            field.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),

            divider.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            rowsStack.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 6),
            rowsStack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            rowsStack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),

            emptyLabel.topAnchor.constraint(equalTo: rowsStack.bottomAnchor, constant: 4),
            emptyLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18),
            emptyLabel.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -12)
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: lifecycle

    func present(in container: NSView) {
        frame = container.bounds
        autoresizingMask = [.width, .height]
        container.addSubview(self)
        field.stringValue = ""
        refresh(query: "")
        window?.makeFirstResponder(field)
    }

    func dismiss() {
        stopSpotlight()
        removeFromSuperview()
        onDismiss?()
    }

    override func mouseDown(with event: NSEvent) {
        // Outside the panel → dismiss; inside → let rows handle clicks.
        let p = convert(event.locationInWindow, from: nil)
        if !panel.frame.contains(p) { dismiss() }
    }

    // MARK: field events

    func controlTextDidChange(_ obj: Notification) {
        refresh(query: field.stringValue.trimmingCharacters(in: .whitespaces))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss(); return true
        case #selector(NSResponder.moveDown(_:)):
            moveHighlight(1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveHighlight(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            activate(highlighted, newTab: NSEvent.modifierFlags.contains(.command)); return true
        default:
            return false
        }
    }

    // MARK: search

    private func refresh(query: String) {
        let changed = query != activeQuery
        activeQuery = query
        searchGeneration += 1
        if changed {
            highlighted = 0
            remoteItems = []
        }
        if query.isEmpty {
            results.removeAll()
            for url in Self.recents().prefix(6) {
                results.append(.folder(url: url, detail: shortPath(url)))
            }
            emptyLabel.stringValue = ""
            rebuildRows()
            stopSpotlight()
            return
        }
        publish(query: query, spotlightPending: query.count >= 3)
        scheduleSpotlight(query)
    }

    /// Current-folder index is already in memory. Spotlight hits, if any, are merged in.
    private func publish(query: String, spotlightPending: Bool) {
        let index = photoSource?() ?? FolderSearchIndex(photos: [])
        let hits = index.hits(query: query, limit: 8)
        let rows = DriveSearchMerge.rows(
            currentHits: hits,
            currentIDs: Set(index.entries.map(\.id)),
            currentFolderPath: currentFolderPath?() ?? "",
            recents: Self.recents().map(\.path),
            spotlight: remoteItems,
            query: query,
            home: NSHomeDirectory()
        )
        results = rows.map { row in
            switch row.kind {
            case .currentFile(let id):
                return .photo(id: id, name: row.name)
            case .folder:
                return .folder(url: URL(fileURLWithPath: row.path), detail: row.detail)
            case .driveFile:
                return .driveFile(url: URL(fileURLWithPath: row.path), detail: row.detail)
            }
        }
        if results.isEmpty {
            emptyLabel.stringValue = spotlightPending ? "searching…" : "no matches"
        } else {
            emptyLabel.stringValue = ""
        }
        rebuildRows()
    }

    private func scheduleSpotlight(_ query: String) {
        stopSpotlight()
        guard query.count >= 3 else { return }
        let generation = searchGeneration
        spotlightDebounce = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            self?.startSpotlight(query, generation: generation)
        }
    }

    private func startSpotlight(_ query: String, generation: Int) {
        guard generation == searchGeneration else { return }
        let mdq = NSMetadataQuery()
        mdq.predicate = Self.spotlightPredicate(query)
        mdq.searchScopes = Self.localVolumeScopes()
        mdq.operationQueue = spotlightQueue
        let deliver: (Notification) -> Void = { [weak self] note in
            self?.deliverSpotlight(note, generation: generation, finished: note.name == .NSMetadataQueryDidFinishGathering)
        }
        spotlightTokens = [
            NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: mdq, queue: nil, using: deliver),
            NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: mdq, queue: nil, using: deliver)
        ]
        spotlightQuery = mdq
        mdq.start()
    }

    /// Folders anywhere, plus images (including camera RAW) on mounted local volumes.
    private static func spotlightPredicate(_ query: String) -> NSPredicate {
        let extensions = PhotoAsset.rawExtensions
            .union(PhotoAsset.jpegExtensions)
            .union(PhotoAsset.otherImageExtensions)
        let extClause = extensions.map { "kMDItemFSName ENDSWITH[c] '.\($0)'" }.joined(separator: " OR ")
        let format = """
        kMDItemFSName CONTAINS[cd] %@ AND (\
        kMDItemContentType == 'public.folder' OR \
        kMDItemContentTypeTree == 'public.image' OR \
        kMDItemContentTypeTree == 'public.camera-raw-image' OR \
        \(extClause))
        """
        return NSPredicate(format: format, query)
    }

    private static func localVolumeScopes() -> [Any] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let local = urls.filter { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.volumeIsLocal != false && values?.volumeIsBrowsable != false
        }
        return local.isEmpty ? [NSMetadataQueryLocalComputerScope] : local
    }

    private func deliverSpotlight(_ note: Notification, generation: Int, finished: Bool) {
        guard let mdq = note.object as? NSMetadataQuery else { return }
        let items = Self.readSpotlight(mdq, limit: 80)
        if finished { mdq.stop() }
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.searchGeneration else { return }
            self.remoteItems = items
            self.publish(query: self.activeQuery, spotlightPending: !finished)
            if finished { self.spotlightQuery = nil }
        }
    }

    /// Called on the query's operation queue. Do not touch AppKit views here.
    private static func readSpotlight(_ mdq: NSMetadataQuery, limit: Int) -> [DriveSearchMerge.Item] {
        mdq.disableUpdates()
        defer { mdq.enableUpdates() }
        var items: [DriveSearchMerge.Item] = []
        items.reserveCapacity(min(limit, mdq.resultCount))
        for case let item as NSMetadataItem in mdq.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let name = (item.value(forAttribute: NSMetadataItemFSNameKey) as? String)
                ?? (path as NSString).lastPathComponent
            let type = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String ?? ""
            let tree = item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? []
            let isFolder = type == "public.folder" || tree.contains("public.folder")
            items.append(DriveSearchMerge.Item(path: path, name: name, isFolder: isFolder))
            if items.count >= limit { break }
        }
        return items
    }

    private func stopSpotlight() {
        spotlightDebounce?.invalidate()
        spotlightDebounce = nil
        for token in spotlightTokens { NotificationCenter.default.removeObserver(token) }
        spotlightTokens.removeAll()
        if let mdq = spotlightQuery {
            let query = mdq
            spotlightQueue.addOperation { query.stop() }
        }
        spotlightQuery = nil
    }

    // MARK: rows

    private func rebuildRows() {
        rowsStack.arrangedSubviews.forEach { rowsStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        var lastSection: String?
        for (i, result) in results.enumerated() {
            let section = sectionTitle(for: result)
            if section != lastSection {
                lastSection = section
                rowsStack.addArrangedSubview(eyebrow(section))
            }
            let row = makeRow(result, highlighted: i == highlighted, index: i)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
    }

    /// Engraved section label - the FACES-panel convention.
    private func eyebrow(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: Theme.monoEyebrow,
            .foregroundColor: Theme.tx2,
            .kern: 1.4
        ])
        let wrap = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 12),
            label.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -2)
        ])
        return wrap
    }

    private func sectionTitle(for result: Result) -> String {
        switch result {
        case .photo: return "THIS FOLDER"
        case .folder: return "FOLDERS"
        case .driveFile: return "FILES"
        }
    }

    private func makeRow(_ result: Result, highlighted: Bool, index: Int) -> NSView {
        let symbol: String
        let title: String
        let detail: String
        switch result {
        case .photo(_, let name):
            symbol = "photo"; title = name; detail = ""
        case .folder(let url, let d):
            symbol = "folder"; title = url.lastPathComponent; detail = d
        case .driveFile(let url, let d):
            symbol = "photo"; title = url.lastPathComponent; detail = d
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = highlighted ? Theme.accent : Theme.tx2
        let t = NSTextField(labelWithString: title)
        t.font = Theme.monoData
        t.textColor = Theme.tx0
        t.lineBreakMode = .byTruncatingMiddle
        let d = NSTextField(labelWithString: detail)
        d.font = Theme.caption
        d.textColor = Theme.tx2
        d.lineBreakMode = .byTruncatingHead
        let spacer = NSView()
        let stack = NSStackView(views: [icon, t, spacer, d])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        let row = ClickRow()
        row.wantsLayer = true
        row.layer?.cornerRadius = Theme.panelRadius
        row.layer?.backgroundColor = highlighted
            ? Theme.accent.withAlphaComponent(0.16).cgColor
            : NSColor.clear.cgColor
        row.onClick = { [weak self] in self?.activate(index, newTab: false) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            stack.topAnchor.constraint(equalTo: row.topAnchor),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        return row
    }

    private func moveHighlight(_ delta: Int) {
        guard !results.isEmpty else { return }
        highlighted = max(0, min(results.count - 1, highlighted + delta))
        rebuildRows()
    }

    private func activate(_ index: Int, newTab: Bool) {
        guard index < results.count else { return }
        switch results[index] {
        case .photo(let id, _):
            dismiss()
            onJumpToPhoto?(id)
        case .folder(let url, _):
            dismiss()
            onOpenFolder?(url, newTab)
        case .driveFile(let url, _):
            dismiss()
            onOpenFile?(url)
        }
    }

    private func shortPath(_ url: URL) -> String {
        let path = url.deletingLastPathComponent().path
        return path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

/// Minimal clickable container for palette rows.
private final class ClickRow: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

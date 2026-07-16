import AppKit

/// ⌘F — the Spotlight-style palette. No persistent search bar (chrome you
/// aren't using), no catalog (the filesystem stays the only truth). One
/// field, two kinds of answers:
///   · photos in the CURRENT folder — "6954" jumps to MWP36954.CR3 (clients
///     reference gallery frame numbers; suffix digits are the hero match)
///   · folders ANYWHERE — instant hits from places you've been (MRU, tabs),
///     then async hits from Spotlight's own index (NSMetadataQuery — we
///     borrow the OS's index rather than building one).
final class SearchPaletteView: NSView, NSTextFieldDelegate {

    // MARK: results

    enum Result {
        case photo(index: Int, name: String)
        case folder(url: URL, detail: String)
    }

    var onJumpToPhoto: ((Int) -> Void)?
    var onOpenFolder: ((URL, _ newTab: Bool) -> Void)?
    var onDismiss: (() -> Void)?
    /// Supplied by the grid each time the palette opens.
    var photoSource: (() -> [(Int, String)])?

    private let panel = NSView()
    private let field = NSTextField()
    private let rowsStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var results: [Result] = []
    private var highlighted = 0
    private var spotlightQuery: NSMetadataQuery?
    private var spotlightDebounce: Timer?

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
        panel.layer?.cornerRadius = 12
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = Theme.line.cgColor
        panel.layer?.shadowColor = NSColor.black.cgColor
        panel.layer?.shadowOpacity = 0.5
        panel.layer?.shadowRadius = 24
        panel.layer?.shadowOffset = CGSize(width: 0, height: -8)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        field.font = Theme.mono(15)
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

        emptyLabel.font = NSFont.systemFont(ofSize: 11.5)
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
        results.removeAll()
        if query.isEmpty {
            // Blank palette = recent folders, ready to jump.
            for url in Self.recents().prefix(6) {
                results.append(.folder(url: url, detail: shortPath(url)))
            }
            emptyLabel.stringValue = ""
            highlighted = 0
            rebuildRows()
            stopSpotlight()
            return
        }

        // 1. Photos in the current folder — suffix-digit matches first.
        let q = query.lowercased()
        let qIsDigits = !q.isEmpty && q.allSatisfy(\.isNumber)
        var photoHits: [(Int, String, Int)] = []   // (index, name, rank)
        for (index, name) in photoSource?() ?? [] {
            let lower = name.lowercased()
            let stem = (lower as NSString).deletingPathExtension
            if qIsDigits {
                if stem.hasSuffix(q) { photoHits.append((index, name, 0)) }
                else if stem.contains(q) { photoHits.append((index, name, 1)) }
            } else if lower.contains(q) {
                photoHits.append((index, name, stem.hasPrefix(q) ? 0 : 1))
            }
        }
        photoHits.sort { ($0.2, $0.0) < ($1.2, $1.0) }
        for (index, name, _) in photoHits.prefix(5) {
            results.append(.photo(index: index, name: name))
        }

        // 2. Folders you've been to — instant.
        for url in Self.recents() where url.lastPathComponent.lowercased().contains(q) {
            if results.count >= 11 { break }
            results.append(.folder(url: url, detail: shortPath(url)))
        }

        emptyLabel.stringValue = results.isEmpty ? "searching…" : ""
        highlighted = 0
        rebuildRows()

        // 3. Spotlight, debounced — appended as macOS answers.
        scheduleSpotlight(query)
    }

    private func scheduleSpotlight(_ query: String) {
        stopSpotlight()
        guard query.count >= 3, !query.allSatisfy(\.isNumber) else { return }
        spotlightDebounce = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.startSpotlight(query)
        }
    }

    private func startSpotlight(_ query: String) {
        let mdq = NSMetadataQuery()
        mdq.predicate = NSPredicate(format: "kMDItemContentType == 'public.folder' && kMDItemFSName CONTAINS[cd] %@", query)
        mdq.searchScopes = [NSMetadataQueryLocalComputerScope]
        NotificationCenter.default.addObserver(self, selector: #selector(spotlightFinished(_:)),
                                               name: .NSMetadataQueryDidFinishGathering, object: mdq)
        spotlightQuery = mdq
        mdq.start()
    }

    @objc private func spotlightFinished(_ note: Notification) {
        guard let mdq = note.object as? NSMetadataQuery, mdq === spotlightQuery else { return }
        mdq.disableUpdates()
        let known = Set(results.compactMap { if case .folder(let u, _) = $0 { return u.path } else { return nil } })
        var added = 0
        for item in mdq.results.prefix(80) {
            guard added < 6,
                  let path = (item as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !known.contains(path),
                  !path.contains("/Library/") else { continue }
            let url = URL(fileURLWithPath: path)
            results.append(.folder(url: url, detail: shortPath(url)))
            added += 1
        }
        mdq.stop()
        spotlightQuery = nil
        if added > 0 { rebuildRows() }
        if results.isEmpty { emptyLabel.stringValue = "no matches" }
    }

    private func stopSpotlight() {
        spotlightDebounce?.invalidate()
        if let mdq = spotlightQuery {
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: mdq)
            mdq.stop()
        }
        spotlightQuery = nil
    }

    // MARK: rows

    private func rebuildRows() {
        rowsStack.arrangedSubviews.forEach { rowsStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        var lastKind: Bool? = nil   // true = photo section, false = folder
        for (i, result) in results.enumerated() {
            let isPhoto: Bool
            if case .photo = result { isPhoto = true } else { isPhoto = false }
            if isPhoto != lastKind {
                lastKind = isPhoto
                rowsStack.addArrangedSubview(eyebrow(isPhoto ? "FRAMES" : "FOLDERS"))
            }
            let row = makeRow(result, highlighted: i == highlighted, index: i)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
    }

    /// Engraved section label — the FACES-panel convention.
    private func eyebrow(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: Theme.mono(9, .medium),
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

    private func makeRow(_ result: Result, highlighted: Bool, index: Int) -> NSView {
        let symbol: String
        let title: String
        let detail: String
        switch result {
        case .photo(_, let name):
            symbol = "photo"; title = name; detail = ""
        case .folder(let url, let d):
            symbol = "folder"; title = url.lastPathComponent; detail = d
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = highlighted ? Theme.accent : Theme.tx2
        let t = NSTextField(labelWithString: title)
        t.font = Theme.mono(12.5)
        t.textColor = Theme.tx0
        t.lineBreakMode = .byTruncatingMiddle
        let d = NSTextField(labelWithString: detail)
        d.font = NSFont.systemFont(ofSize: 10.5)
        d.textColor = Theme.tx2
        d.lineBreakMode = .byTruncatingHead
        let spacer = NSView()
        let stack = NSStackView(views: [icon, t, spacer, d])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        let row = ClickRow()
        row.wantsLayer = true
        row.layer?.cornerRadius = 6
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
        case .photo(let photoIndex, _):
            dismiss()
            onJumpToPhoto?(photoIndex)
        case .folder(let url, _):
            dismiss()
            onOpenFolder?(url, newTab)
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

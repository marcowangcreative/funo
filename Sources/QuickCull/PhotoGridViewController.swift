import AppKit

/// Item view that reports double-clicks without disturbing the collection
/// view's normal click-to-select machinery.
final class DoubleClickView: NSView {
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDoubleClick?() }
    }
}

/// NSCollectionView's built-in shift-click toggles items individually, which
/// surprises everyone. This subclass gives shift-click Finder semantics:
/// select the whole contiguous range from the anchor. ⌘-click keeps the
/// native toggle-individual behavior.
final class CullCollectionView: NSCollectionView {
    /// Return true if the shift-range selection was handled.
    var shiftRangeHandler: ((Int) -> Bool)?
    /// Build the right-click menu for the item under the cursor (nil = none).
    var contextMenuHandler: ((IndexPath?) -> NSMenu?)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.command) {
            let point = convert(event.locationInWindow, from: nil)
            if let ip = indexPathForItem(at: point), shiftRangeHandler?(ip.item) == true {
                return // handled; don't let the default toggle run
            }
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return contextMenuHandler?(indexPathForItem(at: point)) ?? super.menu(for: event)
    }
}

/// One cell in the contact sheet, styled after the mockup: rounded graphite
/// card, thumbnail, meta row (filename + format badge), amber stars overlay,
/// dimmed + red ✕ when rejected.
/// Grid thumbnail: a plain layer-backed view (contents = cgImage) instead
/// of NSImageView - pure GPU compositing, cheaper on fast scroll. .resizeAspect
/// fits the WHOLE frame (no crop), matching the old scaleProportionallyDown.
private final class GridThumbView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    func setImage(_ image: NSImage?) {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            layer?.contents = nil
            return
        }
        layer?.contents = cg
    }
}

final class PhotoItem: NSCollectionViewItem, NSTextFieldDelegate {

    static let identifier = NSUserInterfaceItemIdentifier("PhotoItem")

    private let thumbView = GridThumbView(frame: .zero)
    private let nameLabel = NSTextField(labelWithString: "")
    private let starsLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let container = NSView()

    private(set) var representedURL: URL?
    var onDoubleClick: (() -> Void)?

    override func loadView() {
        let v = DoubleClickView()
        v.wantsLayer = true
        v.onDoubleClick = { [weak self] in self?.onDoubleClick?() }
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        container.wantsLayer = true
        container.layer?.cornerRadius = 9
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = Theme.bg2.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        thumbView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(thumbView)

        nameLabel.font = Theme.monoCaption
        nameLabel.textColor = Theme.tx1
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.usesSingleLineMode = true
        nameLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.delegate = self
        nameLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(nameClicked(_:))))
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(nameLabel)

        badgeLabel.font = Theme.monoEyebrow
        badgeLabel.textColor = Theme.tx2
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.borderColor = Theme.line.cgColor
        badgeLabel.layer?.borderWidth = 1
        badgeLabel.layer?.cornerRadius = 4
        badgeLabel.alignment = .center
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(badgeLabel)

        // Stars live in the card's top padding - on graphite, never fighting
        // a bright image for contrast.
        starsLabel.font = Theme.secondary
        starsLabel.textColor = Theme.accent
        starsLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(starsLabel)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            starsLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 7),
            starsLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            starsLabel.heightAnchor.constraint(equalToConstant: 15),

            thumbView.topAnchor.constraint(equalTo: container.topAnchor, constant: 25),
            thumbView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            thumbView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            thumbView.bottomAnchor.constraint(equalTo: nameLabel.topAnchor, constant: -3),

            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: badgeLabel.leadingAnchor, constant: -6),
            nameLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            nameLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 13),

            badgeLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            badgeLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 26),

        ])
    }

    func configure(asset: PhotoAsset) {
        if editingBase != nil { endNameEdit() } // cell reused mid-edit
        representedURL = asset.url
        nameLabel.stringValue = asset.filename
        thumbView.setImage(ThumbnailLoader.shared.cachedImage(for: asset.url, maxPixel: ThumbnailLoader.thumbnailPixelSize))
        if asset.hasJPEGPair {
            badgeLabel.stringValue = "R+J"
        } else if asset.isRAW {
            badgeLabel.stringValue = "RAW"
        } else {
            badgeLabel.stringValue = asset.url.pathExtension.uppercased()
        }
        refreshCullState(assetID: asset.id)
    }

    func setThumbnail(_ image: NSImage?, for url: URL) {
        guard representedURL == url else { return } // cell was reused; drop stale pixels
        thumbView.setImage(image)
    }

    func refreshCullState(assetID: String) {
        let rating = RatingsStore.shared.rating(for: assetID)
        let isRejected = RatingsStore.shared.isRejected(assetID)
        container.alphaValue = isRejected ? 0.26 : 1.0
        if isRejected {
            starsLabel.stringValue = "✕"
            starsLabel.textColor = Theme.red
        } else {
            starsLabel.stringValue = rating > 0 ? String(repeating: "★", count: rating) : ""
            starsLabel.textColor = Theme.accent
        }
        // Color label tints the whole card - reads at a glance from across
        // the room, the way Photo Mechanic color classes do.
        let color = RatingsStore.shared.colorLabel(for: assetID)
        if color > 0 {
            let tint = Theme.bg2.blended(withFraction: 0.42, of: Theme.labelColors[color]) ?? Theme.bg2
            container.layer?.backgroundColor = tint.cgColor
        } else {
            container.layer?.backgroundColor = Theme.bg2.cgColor
        }
    }

    override var isSelected: Bool {
        didSet {
            container.layer?.borderWidth = isSelected ? 2.5 : 0
            container.layer?.borderColor = Theme.accent.cgColor
        }
    }

    // MARK: - Click-to-rename (Finder-style, on the filename)

    var onRenameCommitted: ((String) -> Void)?
    private var editingBase: String?
    private var editCancelled = false

    @objc private func nameClicked(_ recognizer: NSClickGestureRecognizer) {
        beginNameEdit()
    }

    private func beginNameEdit() {
        guard editingBase == nil, let url = representedURL else { return }
        let base = url.deletingPathExtension().lastPathComponent
        editingBase = base
        editCancelled = false
        nameLabel.stringValue = base // extension protected - edit the base only
        nameLabel.isEditable = true
        nameLabel.isSelectable = true
        nameLabel.drawsBackground = true
        nameLabel.backgroundColor = Theme.bg1
        view.window?.makeFirstResponder(nameLabel)
        nameLabel.currentEditor()?.selectAll(nil)
    }

    private func endNameEdit() {
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.drawsBackground = false
        if let url = representedURL { nameLabel.stringValue = url.lastPathComponent }
        editingBase = nil
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let original = editingBase else { return }
        let entered = nameLabel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let cancelled = editCancelled
        endNameEdit()
        guard !cancelled, !entered.isEmpty, entered != original else { return }
        onRenameCommitted?(entered)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            editCancelled = true
            view.window?.makeFirstResponder(nil)
            return true
        }
        return false
    }
}

/// The contact sheet: filter toolbar, NSCollectionView grid, status bar.
/// Keyboard input arrives via the app-level key monitor (see handleKey).
final class PhotoGridViewController: NSViewController,
    NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewPrefetching {

    enum SortKey: Int {
        case name, capture
        static let titles = ["Name", "Time"]
    }

    private var allAssets: [PhotoAsset] = []
    private(set) var displayedAssets: [PhotoAsset] = []
    /// Stars filter as a THRESHOLD (click the 3rd star = 3★ & up, like
    /// Lightroom) because ratings are a scale; colors multi-select because
    /// labels are categories. nil / empty = no filter.
    private var starThreshold: Int?
    private var starComparison: RatingComparison = .atLeast
    private var rejectsOnly = false
    private var colorFilter: Set<Int> = []   // 0 = "no label" (grey dot)
    private var sortKey: SortKey = .name
    private var sortAscending = true
    private var captureDates: [String: Date] = [:]
    private var currentFolder: URL?

    private let scrollView = NSScrollView()
    private let collectionView = CullCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    private var selectionAnchor: Int?
    /// The moving end of a shift-arrow range (anchor stays put).
    private var shiftFocus: Int?
    private let filterBar = StarFilterBar()
    private let colorFilterBar = ColorFilterBar()
    private let sortBar = FilterBar(titles: SortKey.titles)
    private let sortDirectionButton = NSButton()
    private let sizeSlider = NSSlider()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let bannerView = NSImageView()
    private let filterStrip = NSButton()
    private var filterStripHeight: NSLayoutConstraint!
    /// View-options cluster (AI faces toggle - global state anyway - and
    /// the size slider) hides when this grid is narrow.
    private var compactHiddenViews: [NSView] = []
    /// The window footer renders our status line - (text, undo visible).
    /// Only the ACTIVE tab pushes; frozen tabs stay quiet.
    var onStatusChanged: ((String, Bool) -> Void)?

    private func pushStatus(_ text: String, undo: Bool = false) {
        guard isActiveTab else { return }
        onStatusChanged?(text, undo)
    }

    private var scanGeneration = 0
    private var firstThumbMS: Double?
    private var scanStartedAt: Date?
    private var scanMS: Double = 0
    private var pairedHidden = 0

    var onOpenPreview: ((Int) -> Void)?
    var onSelectionChanged: ((PhotoAsset?) -> Void)?
    var onOpenSurvey: (([PhotoAsset]) -> Void)?
    /// Fired on every folder load (incl. back/forward) so the tab strip
    /// and window title stay truthful.
    var onFolderChanged: ((URL) -> Void)?
    /// Clickable Undo in the status bar routes here (MainSplit owns undo).
    var onUndoRequested: (() -> Void)?

    // MARK: - Folder history (browser back/forward, per tab)

    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var navigatingHistory = false

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        guard let target = backStack.popLast() else { return }
        if let current = currentFolder { forwardStack.append(current) }
        navigatingHistory = true
        loadFolder(target)
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        if let current = currentFolder { backStack.append(current) }
        navigatingHistory = true
        loadFolder(target)
    }


    // MARK: - Tab lifecycle (tabbed contact sheets)

    /// Background tabs are FROZEN: they keep their folder, selection,
    /// scroll position and filter, but never feed the decode/prefetch/face
    /// pipelines. Only the visible tab spends resources.
    private(set) var isActiveTab = true
    private var reloadPendingWhileInactive = false

    var currentFolderURL: URL? { currentFolder }

    func didBecomeActiveTab() {
        guard !isActiveTab else { return }
        isActiveTab = true
        if reloadPendingWhileInactive {
            // The folder changed on disk while this tab was frozen.
            reloadPendingWhileInactive = false
            reloadCurrentFolderPreservingSelection()
        } else {
            // Ratings/labels may have changed from another tab.
            refreshVisibleCullStates()
            scheduleFocusPass()
            updateStatus()
        }
    }

    func didResignActiveTab() {
        isActiveTab = false
    }

    /// Blank ⌘T tab: say what to do next instead of showing a void.
    func showNewTabPlaceholder() {
        installWelcomeIfNeeded()
        if welcomeOverlay == nil { emptyLabel.stringValue = "Pick a folder in the sidebar" }
        bannerView.isHidden = false
    }

    /// Tab is closing for good - stop watching, stop timers.
    func prepareForClose() {
        folderMonitor?.cancel()
        folderMonitor = nil
        externalReloadTimer?.invalidate()
        externalReloadTimer = nil
    }
    /// A face-analysis result landed (asset id) - lets the preview update live.
    var onFaceResult: ((String) -> Void)?

    // MARK: - View setup

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.bg0.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        layout.itemSize = NSSize(width: 176, height: 170)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true // shift-click ranges, ⌘-click toggles
        applySurround()
        NotificationCenter.default.addObserver(self, selector: #selector(surroundChanged(_:)),
                                               name: Theme.surroundChanged, object: nil)
        collectionView.register(PhotoItem.self, forItemWithIdentifier: PhotoItem.identifier)
        // Drag photos out: to the sidebar (move) or to Finder/other apps (copy).
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.shiftRangeHandler = { [weak self] target in
            self?.selectRange(to: target) ?? false
        }
        collectionView.contextMenuHandler = { [weak self] ip in
            self?.buildContextMenu(for: ip)
        }

        // Face analysis trickles in - restyle the badge on whichever card is
        // visible, refresh the Eyes ✓ filter (throttled), update progress.
        FaceAnalyzer.shared.onResult = { [weak self] id in
            self?.onFaceResult?(id)
        }
        FaceAnalyzer.shared.onProgress = { [weak self] done, total in
            guard let self else { return }
            self.aiDone = done
            self.aiTotal = total
            // Cached folders stream thousands of results in a burst; a full
            // updateStatus (2x O(n) rated/rejected recount + footer relayout)
            // per result stormed the main thread. Coalesce to ~7 Hz.
            self.scheduleStatusUpdate()
        }

        // ── Toolbar ──────────────────────────────────────────────
        let toolbar = NSView()
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = Theme.bg1.cgColor
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)

        let showLabel = Theme.sectionHeader("Show")
        showLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(showLabel)

        filterBar.translatesAutoresizingMaskIntoConstraints = false
        filterBar.onChange = { [weak self] threshold, comparison, rejects in
            self?.starThreshold = threshold
            self?.starComparison = comparison
            self?.rejectsOnly = rejects
            self?.applyFilter(keepSelection: true)
        }
        toolbar.addSubview(filterBar)

        colorFilterBar.translatesAutoresizingMaskIntoConstraints = false
        colorFilterBar.onChange = { [weak self] labels in
            self?.colorFilter = labels
            self?.applyFilter(keepSelection: true)
        }
        toolbar.addSubview(colorFilterBar)

        let sortLabel = Theme.sectionHeader("Sort")
        sortLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(sortLabel)

        sortBar.translatesAutoresizingMaskIntoConstraints = false
        sortBar.onChange = { [weak self] index in
            guard let self, let key = SortKey(rawValue: index) else { return }
            self.sortKey = key
            self.resort(keepSelection: true)
            if key == .capture, self.captureDates.isEmpty, !self.allAssets.isEmpty {
                self.scanCaptureDates(self.allAssets, generation: self.scanGeneration)
            }
        }
        toolbar.addSubview(sortBar)

        sortDirectionButton.title = "↑"
        sortDirectionButton.isBordered = false
        sortDirectionButton.font = Theme.bodyStrong
        sortDirectionButton.contentTintColor = Theme.tx1
        sortDirectionButton.toolTip = "Reverse sort order"
        sortDirectionButton.target = self
        sortDirectionButton.action = #selector(toggleSortDirection(_:))
        sortDirectionButton.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(sortDirectionButton)

        let sizeLabel = Theme.sectionHeader("Size")
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(sizeLabel)

        sizeSlider.minValue = 120
        sizeSlider.maxValue = 320
        sizeSlider.doubleValue = 176
        sizeSlider.controlSize = .small
        sizeSlider.trackFillColor = Theme.accent
        sizeSlider.target = self
        sizeSlider.action = #selector(thumbSizeChanged(_:))
        sizeSlider.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(sizeSlider)

        // Vertical hairlines separating the toolbar's three groups
        // (filter | sort | view options) so it reads as sections, not soup.
        func groupSeparator() -> NSView {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = Theme.line.cgColor
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: 1).isActive = true
            v.heightAnchor.constraint(equalToConstant: 16).isActive = true
            return v
        }
        let sep1 = groupSeparator()
        toolbar.addSubview(sep1)

        let toolbarLine = hairline()
        toolbar.addSubview(toolbarLine)

        // ── Filter escape strip ──────────────────────────────────
        // "My photos disappeared" is always an active filter. When one
        // hides photos, this amber strip says so and one click clears it.
        filterStrip.isBordered = false
        filterStrip.wantsLayer = true
        filterStrip.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.12).cgColor
        filterStrip.target = self
        filterStrip.action = #selector(clearAllFilters(_:))
        filterStrip.isHidden = true
        filterStrip.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(filterStrip)
        filterStripHeight = filterStrip.heightAnchor.constraint(equalToConstant: 0)
        filterStripHeight.isActive = true

        // ── Grid ─────────────────────────────────────────────────
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        // The status line renders in the WINDOW footer (StatusFooterView) -
        // this grid feeds it via onStatusChanged when it's the active tab.
        compactHiddenViews = [sizeLabel, sizeSlider]

        emptyLabel.font = Theme.headline
        emptyLabel.textColor = Theme.tx2
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        // Brand mark on the EMPTY state only - the aperture scale parked at
        // ƒ/1.0. Transparent PNG, so it sits on any surround color. It shows
        // when there's no folder open (launch, blank tab) and vanishes the
        // moment real work is on screen - the brand lives in the pauses.
        if let url = Bundle.module.url(forResource: "banner", withExtension: "png") {
            bannerView.image = NSImage(contentsOf: url)
        }
        bannerView.imageScaling = .scaleProportionallyDown
        bannerView.alphaValue = 0.85
        bannerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bannerView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 42),

            showLabel.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 14),
            showLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            filterBar.leadingAnchor.constraint(equalTo: showLabel.trailingAnchor, constant: 10),
            filterBar.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            colorFilterBar.leadingAnchor.constraint(equalTo: filterBar.trailingAnchor, constant: 12),
            colorFilterBar.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            sep1.leadingAnchor.constraint(equalTo: colorFilterBar.trailingAnchor, constant: 16),
            sep1.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            sortLabel.leadingAnchor.constraint(equalTo: sep1.trailingAnchor, constant: 16),
            sortLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            sortBar.leadingAnchor.constraint(equalTo: sortLabel.trailingAnchor, constant: 10),
            sortBar.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            sortDirectionButton.leadingAnchor.constraint(equalTo: sortBar.trailingAnchor, constant: 6),
            sortDirectionButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            sizeSlider.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -14),
            sizeSlider.widthAnchor.constraint(equalToConstant: 120),
            sizeSlider.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            sizeLabel.trailingAnchor.constraint(equalTo: sizeSlider.leadingAnchor, constant: -8),
            sizeLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            toolbarLine.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            toolbarLine.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            toolbarLine.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),

            filterStrip.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            filterStrip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            filterStrip.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: filterStrip.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            // Anchored to the bottom edge, like an engraving on the body of
            // the instrument - not floating in the void mid-window.
            bannerView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bannerView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -28),
            bannerView.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            bannerView.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.55),
            bannerView.heightAnchor.constraint(equalTo: bannerView.widthAnchor, multiplier: 254.0 / 1600.0)
        ])

        installWelcomeIfNeeded()
    }

    // MARK: - First-open welcome

    private var welcomeOverlay: NSView?

    /// First open is a void - a proper, left-aligned intro that orients a
    /// new photographer. Gone the moment a folder opens; gone for good via
    /// "Don't show again".
    private func installWelcomeIfNeeded() {
        guard currentFolder == nil,
              !UserDefaults.standard.bool(forKey: "QuickCullHideWelcome"),
              welcomeOverlay == nil else { return }

        // The real mark: serif-italic ƒ/ + mono uno (the site lockup), not
        // the squat mono ƒ.
        let mark = NSTextField(labelWithString: "")
        let lockup = NSMutableAttributedString(string: "ƒ/", attributes: [
            .font: NSFont(name: "Georgia-Italic", size: 34) ?? Theme.display,
            .foregroundColor: Theme.accent])
        lockup.append(NSAttributedString(string: "uno", attributes: [
            .font: Theme.monoDisplay, .foregroundColor: Theme.tx0]))
        mark.attributedStringValue = lockup

        let sub = NSTextField(wrappingLabelWithString: "Fast, folder-native culling. No import, no catalog.")
        sub.font = Theme.body
        sub.textColor = Theme.tx1
        sub.preferredMaxLayoutWidth = 376
        sub.isSelectable = false

        // Three left-aligned steps: engraved brass key, plain description.
        func step(_ key: String, _ desc: String) -> NSStackView {
            let k = NSTextField(labelWithString: "")
            k.attributedStringValue = NSAttributedString(string: key.uppercased(), attributes: [
                .font: Theme.monoEyebrow, .foregroundColor: Theme.accent, .kern: 1.2])
            k.translatesAutoresizingMaskIntoConstraints = false
            k.widthAnchor.constraint(equalToConstant: 96).isActive = true
            k.setContentHuggingPriority(.required, for: .horizontal)
            let d = NSTextField(wrappingLabelWithString: desc)
            d.font = Theme.secondary
            d.textColor = Theme.tx1
            d.preferredMaxLayoutWidth = 250
            d.isSelectable = false
            let row = NSStackView(views: [k, d])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 12
            return row
        }
        let steps = NSStackView(views: [
            step("Insert a card", "Ingest opens on its own. Pick who shot it, hit go."),
            step("Open a folder", "Any folder in the sidebar opens instantly."),
            step("\u{2318}F", "Find any frame or folder in a single keystroke.")
        ])
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 11

        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Theme.line.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let dismiss = NSButton(title: "Don't show this again", target: self, action: #selector(dismissWelcome(_:)))
        dismiss.isBordered = false
        dismiss.font = Theme.caption
        dismiss.contentTintColor = .tertiaryLabelColor

        let stack = NSStackView(views: [mark, sub, rule, steps, dismiss])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(10, after: mark)
        stack.setCustomSpacing(20, after: sub)
        stack.setCustomSpacing(18, after: rule)
        stack.setCustomSpacing(20, after: steps)
        stack.edgeInsets = NSEdgeInsets(top: 30, left: 34, bottom: 26, right: 34)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // No card chrome - the redesigned content stands on its own.
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 444),
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rule.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -68)
        ])
        welcomeOverlay = card   // handle for teardown / mutual-exclusion with emptyLabel
        emptyLabel.stringValue = ""   // the card owns the empty screen
    }

    private func removeWelcome() {
        welcomeOverlay?.removeFromSuperview()
        welcomeOverlay = nil
    }

    @objc private func dismissWelcome(_ sender: Any?) {
        UserDefaults.standard.set(true, forKey: "QuickCullHideWelcome")
        removeWelcome()
    }

    private func hairline() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.line.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    @objc private func surroundChanged(_ note: Notification) {
        applySurround()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let compact = view.bounds.width < 900
        for v in compactHiddenViews where v.isHidden != compact {
            v.isHidden = compact
        }
    }

    /// One click out of any filtered view - the "my photos disappeared"
    /// escape hatch.
    @objc private func clearAllFilters(_ sender: Any?) {
        starThreshold = nil
        rejectsOnly = false
        colorFilter = []
        filterBar.clear()
        colorFilterBar.clear()
        applyFilter(keepSelection: true)
    }

    private var isFiltering: Bool {
        rejectsOnly || starThreshold != nil || !colorFilter.isEmpty
    }

    private func updateFilterStrip() {
        let hidden = allAssets.count - displayedAssets.count
        guard isFiltering, hidden > 0 else {
            filterStrip.isHidden = true
            filterStripHeight.constant = 0
            return
        }
        var parts: [String] = []
        if rejectsOnly {
            parts.append("rejects")
        } else if let starThreshold {
            parts.append(starComparison == .exactly
                ? "exactly \(starThreshold)★"
                : "\(starThreshold)★ \(starComparison.label)")
        }
        if !colorFilter.isEmpty {
            let names = colorFilter.sorted().map { $0 == 0 ? "unlabeled" : Theme.labelNames[$0].lowercased() }
            parts.append(names.joined(separator: "/"))
        }
        let text = "Showing \(displayedAssets.count) of \(allAssets.count)  ·  filtered to \(parts.joined(separator: " + "))   -   Show All ✕"
        filterStrip.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: Theme.accent,
            .font: Theme.secondaryStrong
        ])
        filterStrip.isHidden = false
        filterStripHeight.constant = 26
    }

    private func applySurround() {
        let surround = Theme.surround
        collectionView.backgroundColors = [surround.color]
        emptyLabel.textColor = surround == .midGray ? NSColor(white: 0.22, alpha: 1) : Theme.tx2
    }

    @objc private func thumbSizeChanged(_ sender: NSSlider) {
        let w = CGFloat(sender.doubleValue)
        layout.itemSize = NSSize(width: w, height: (w * 0.68).rounded() + 50)
        layout.invalidateLayout()
    }

    /// + / - keys nudge the grid thumbnail size, keeping the dial in sync.
    private func adjustThumbSize(by delta: CGFloat) {
        let lo = CGFloat(sizeSlider.minValue), hi = CGFloat(sizeSlider.maxValue)
        let w = max(lo, min(hi, CGFloat(sizeSlider.doubleValue) + delta))
        guard w != CGFloat(sizeSlider.doubleValue) else { return }
        sizeSlider.doubleValue = Double(w)
        layout.itemSize = NSSize(width: w, height: (w * 0.68).rounded() + 50)
        layout.invalidateLayout()
    }

    // MARK: - Folder loading & filtering

    func loadFolder(_ url: URL) {
        removeWelcome()
        // History: only genuine folder CHANGES push an entry - reloads of
        // the same folder (watcher, undo, rename) never pollute the stack.
        if !navigatingHistory,
           let current = currentFolder,
           current.standardizedFileURL.path != url.standardizedFileURL.path {
            backStack.append(current)
            forwardStack.removeAll()
        }
        navigatingHistory = false
        onFolderChanged?(url)

        currentFolder = url
        bannerView.isHidden = true
        watchFolder(url)
        lastSelfLoadAt = Date()
        scanGeneration += 1
        let generation = scanGeneration
        firstThumbMS = nil
        scanStartedAt = Date()
        pushStatus("Opening \(url.lastPathComponent)…")
        emptyLabel.stringValue = ""

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = FolderScanner.scan(url)
            DispatchQueue.main.async {
                guard let self, self.scanGeneration == generation else { return }
                if self.sortKey == .name {
                    self.allAssets = self.sortAscending ? result.assets : result.assets.reversed()
                } else {
                    self.allAssets = self.sorted(result.assets)
                }
                self.scanMS = result.elapsed * 1000
                self.pairedHidden = result.pairedJPEGCount
                self.captureDates = [:]
                self.applyFilter(keepSelection: false)
                self.scanSidecars(self.allAssets, generation: generation)
                // Capture dates need an EXIF header read PER FILE - thousands
                // of drive reads that fight the thumbnails. The default name
                // sort never uses them, so only pay it when sorting by
                // capture (and lazily on the first switch to it).
                if self.sortKey == .capture {
                    self.scanCaptureDates(result.assets, generation: generation)
                }
                // Face analysis reads a big decode PER photo. On a 5k folder
                // on an external drive it saturates I/O and starves the very
                // thumbnails the user is looking at. Let the thumbnails win
                // the drive first; start faces ~2 s later, and bail if the
                // user has already moved to another folder.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self, self.scanGeneration == generation else { return }
                    FaceAnalyzer.shared.analyzeFolder(self.allAssets)
                }
            }
        }
    }

    /// EXIF capture times + existing XMP sidecars load in the background.
    /// Sidecar ratings/labels from Lightroom/Photo Mechanic are adopted so
    /// culls done elsewhere show up here.
    private func scanCaptureDates(_ assets: [PhotoAsset], generation: Int) {
        // Dates only - sidecar adoption streams separately (scanSidecars).
        // A capture date needs an image-header read, 10–50× the cost of a
        // sidecar; bundling them made Lightroom/PM ratings wait ~2 s behind
        // the EXIF pass on a 2,000-RAW folder.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var dates: [String: Date] = [:]
            for asset in assets {
                if let date = FolderScanner.captureDate(of: asset.url) {
                    dates[asset.id] = date
                }
            }
            DispatchQueue.main.async {
                guard let self, self.scanGeneration == generation else { return }
                self.captureDates = dates
                if self.sortKey == .capture { self.resort(keepSelection: true) }
            }
        }
    }

    /// Foreign sidecar ratings (Lightroom / Photo Mechanic culls) stream in
    /// FAST: tiny .xmp text reads in display order, applied in chunks - the
    /// first chunk is one screenful, so existing culls paint effectively
    /// with the thumbnails instead of seconds later.
    private func scanSidecars(_ assets: [PhotoAsset], generation: Int) {
        let raws = assets.filter { $0.isRAW }
        guard !raws.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var pending: [(String, Int?, Int?)] = []
            var scannedSinceFlush = 0
            var flushedOnce = false
            for (index, asset) in raws.enumerated() {
                let (rating, label) = XMPSidecar.read(for: asset.url)
                if rating != nil || label != nil {
                    pending.append((asset.id, rating, label))
                }
                scannedSinceFlush += 1
                // First flush after ~one screenful; then every 400 files.
                let due = scannedSinceFlush >= (flushedOnce ? 400 : 60)
                if (due || index == raws.count - 1), !pending.isEmpty {
                    flushedOnce = true
                    scannedSinceFlush = 0
                    let batch = pending
                    pending.removeAll()
                    DispatchQueue.main.async {
                        self?.applySidecarBatch(batch, generation: generation)
                    }
                }
            }
        }
    }

    private func applySidecarBatch(_ batch: [(String, Int?, Int?)], generation: Int) {
        guard scanGeneration == generation else { return }
        var adoptedAny = false
        for (id, rating, label) in batch {
            if RatingsStore.shared.adopt(rating: rating, label: label, for: id) {
                adoptedAny = true
            }
        }
        guard adoptedAny else { return }
        // A photo whose adopted value matches the active filter must APPEAR,
        // not just repaint. A full grid reload is a main-thread hit on big
        // folders, so pay it only when a filter could be hiding photos.
        let filterActive = rejectsOnly || starThreshold != nil || !colorFilter.isEmpty
        if filterActive {
            preserveScrollOnNextApply = true
            applyFilter(keepSelection: true)
        }
        refreshVisibleCullStates()
        if let asset = selectedAsset { onSelectionChanged?(asset) }
    }

    // MARK: - Sorting

    private func sorted(_ assets: [PhotoAsset]) -> [PhotoAsset] {
        var result: [PhotoAsset]
        switch sortKey {
        case .name:
            result = assets.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        case .capture:
            result = assets.sorted {
                let a = captureDates[$0.id] ?? $0.modificationDate
                let b = captureDates[$1.id] ?? $1.modificationDate
                if a != b { return a < b }
                return $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
            }
        }
        return sortAscending ? result : result.reversed()
    }

    private func resort(keepSelection: Bool) {
        allAssets = sorted(allAssets)
        applyFilter(keepSelection: keepSelection)
    }

    @objc private func toggleSortDirection(_ sender: Any?) {
        sortAscending.toggle()
        sortDirectionButton.title = sortAscending ? "↑" : "↓"
        resort(keepSelection: true)
    }

    /// Reloads of the SAME folder (watcher refresh, undo, post-trash) keep
    /// the user's scroll position - jumping to the top mid-cull because a
    /// sidecar landed on disk is disorienting. Genuine filter/folder changes
    /// still start at the top.
    private var preserveScrollOnNextApply = false

    private func applyFilter(keepSelection: Bool) {
        let previous = keepSelection ? selectedAsset : nil
        displayedAssets = allAssets.filter { asset in
            let store = RatingsStore.shared
            if rejectsOnly {
                guard store.isRejected(asset.id) else { return false }
            } else if let starThreshold {
                guard !store.isRejected(asset.id) else { return false }
                let rating = store.rating(for: asset.id)
                switch starComparison {
                case .atLeast: guard rating >= starThreshold else { return false }
                case .exactly: guard rating == starThreshold else { return false }
                case .atMost:  guard rating <= starThreshold else { return false }
                }
            }
            if !colorFilter.isEmpty {
                guard colorFilter.contains(store.colorLabel(for: asset.id)) else { return false }
            }
            return true
        }
        let savedOrigin: NSPoint? = preserveScrollOnNextApply
            ? scrollView.contentView.bounds.origin : nil
        preserveScrollOnNextApply = false
        collectionView.reloadData()
        if let savedOrigin {
            scrollView.layoutSubtreeIfNeeded()
            let maxY = max(0, collectionView.frame.height - scrollView.contentView.bounds.height)
            scrollView.contentView.scroll(to: NSPoint(x: savedOrigin.x, y: min(savedOrigin.y, maxY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            collectionView.scroll(NSPoint.zero)
        }
        // The welcome overlay owns the empty screen - never stack
        // "No photos in this folder" on top of it.
        emptyLabel.stringValue = welcomeOverlay != nil ? ""
            : (displayedAssets.isEmpty
                ? (allAssets.isEmpty ? "No photos in this folder" : "Nothing matches this filter")
                : "")

        if let pendingID = pendingSelectionID {
            pendingSelectionID = nil
            pendingSelection = nil
            if let index = displayedAssets.firstIndex(where: { $0.id == pendingID }) {
                select(index: index)
            } else if !displayedAssets.isEmpty {
                select(index: 0)
            } else {
                onSelectionChanged?(nil)
            }
        } else if let pending = pendingSelection {
            pendingSelection = nil
            if !displayedAssets.isEmpty {
                select(index: min(pending, displayedAssets.count - 1))
            } else {
                onSelectionChanged?(nil)
            }
        } else if let previous, let index = displayedAssets.firstIndex(where: { $0.id == previous.id }) {
            select(index: index)
        } else if !displayedAssets.isEmpty {
            select(index: 0)
        } else {
            onSelectionChanged?(nil)
        }
        updateFilterStrip()
        updateStatus()
    }

    func updateStatus() {
        // A flash (esp. an undoable one) owns the status line until it
        // expires - routine stat refreshes must not stomp it.
        guard flashTimer?.isValid != true else { return }
        guard currentFolder != nil else {
            pushStatus("Open a folder to begin. Nothing to import.")
            return
        }
        var parts: [String] = []
        parts.append("\(allAssets.count) photos")
        if isFiltering { parts.append("showing \(displayedAssets.count)") }
        if pairedHidden > 0 { parts.append("+\(pairedHidden) paired JPEGs hidden") }
        parts.append(String(format: "folder read %.0f ms", scanMS))
        if let ms = firstThumbMS { parts.append(String(format: "first thumb %.0f ms", ms)) }
        let rated = allAssets.filter { RatingsStore.shared.rating(for: $0.id) > 0 }.count
        let rejected = allAssets.filter { RatingsStore.shared.isRejected($0.id) }.count
        if rated > 0 || rejected > 0 { parts.append("\(rated) rated · \(rejected) rejected") }
        if aiTotal > 0, aiDone < aiTotal { parts.append("scanning faces \(aiDone)/\(aiTotal)") }
        pushStatus(parts.joined(separator: "   ·   "))
    }

    private var statusUpdateScheduled = false
    /// Collapse a burst of status updates (face/sidecar progress) into one
    /// refresh per ~150 ms - the footer counts don't need per-result fidelity.
    func scheduleStatusUpdate() {
        guard !statusUpdateScheduled else { return }
        statusUpdateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.statusUpdateScheduled = false
            self.updateStatus()
        }
    }

    private func reportFirstThumbIfNeeded() {
        guard firstThumbMS == nil, let started = scanStartedAt else { return }
        firstThumbMS = Date().timeIntervalSince(started) * 1000
        updateStatus()
    }

    // MARK: - NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        displayedAssets.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: PhotoItem.identifier, for: indexPath)
        guard let photoItem = item as? PhotoItem else { return item }
        let asset = displayedAssets[indexPath.item]
        photoItem.configure(asset: asset)
        photoItem.onDoubleClick = { [weak self] in
            self?.onOpenPreview?(indexPath.item)
        }
        photoItem.onRenameCommitted = { [weak self] newBase in
            guard let self else { return }
            let base = self.sanitizeBase(newBase)
            guard !base.isEmpty else { return }
            self.performRenames([(asset, base)])
        }

        if ThumbnailLoader.shared.cachedImage(for: asset.url, maxPixel: ThumbnailLoader.thumbnailPixelSize) == nil {
            let url = asset.url
            ThumbnailLoader.shared.request(url, maxPixel: ThumbnailLoader.thumbnailPixelSize) { [weak self, weak photoItem] image in
                photoItem?.setThumbnail(image, for: url)
                if image != nil { self?.reportFirstThumbIfNeeded() }
            }
            scheduleFocusPass()
        } else {
            reportFirstThumbIfNeeded()
        }
        return item
    }

    /// Coalesced "what's on screen now" report to the loader - keeps the
    /// visible cells at the front of slow-volume decode queues.
    private var focusPassScheduled = false

    private func scheduleFocusPass() {
        guard isActiveTab, !focusPassScheduled else { return }
        focusPassScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.focusPassScheduled = false
            let visibleURLs = self.collectionView.indexPathsForVisibleItems()
                .compactMap { $0.item < self.displayedAssets.count ? self.displayedAssets[$0.item].url : nil }
            ThumbnailLoader.shared.focusVisible(visibleURLs, maxPixel: ThumbnailLoader.thumbnailPixelSize)
        }
    }

    // MARK: - Prefetching

    func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard isActiveTab else { return } // frozen background tab
        for ip in indexPaths where ip.item < displayedAssets.count {
            ThumbnailLoader.shared.prefetch(displayedAssets[ip.item].url, maxPixel: ThumbnailLoader.thumbnailPixelSize)
        }
    }

    func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for ip in indexPaths where ip.item < displayedAssets.count {
            ThumbnailLoader.shared.cancel(displayedAssets[ip.item].url, maxPixel: ThumbnailLoader.thumbnailPixelSize)
        }
    }

    // MARK: - Selection

    var selectedIndex: Int? {
        // selectionIndexPaths is a SET - `.first` on a multi-selection is
        // hash-order roulette (Space on a range opened a random middle
        // photo). The first of the range, deterministically.
        collectionView.selectionIndexPaths.map(\.item).min()
    }

    var selectedAsset: PhotoAsset? {
        guard let i = selectedIndex, i < displayedAssets.count else { return nil }
        return displayedAssets[i]
    }

    var selectedAssets: [PhotoAsset] {
        collectionView.selectionIndexPaths
            .sorted()
            .compactMap { $0.item < displayedAssets.count ? displayedAssets[$0.item] : nil }
    }

    // MARK: - Drag source

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        true
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard indexPath.item < displayedAssets.count else { return nil }
        return displayedAssets[indexPath.item].url as NSURL
    }

    // MARK: - Bulk operations

    func selectAllVisible() {
        collectionView.selectAll(nil)
        if let first = displayedAssets.first { onSelectionChanged?(first) }
        flash("\(displayedAssets.count) selected")
    }

    func deselectAll() {
        collectionView.deselectAll(nil)
        onSelectionChanged?(nil)
        flash("Selection cleared")
    }

    // MARK: - Clipboard (⌘C copy, ⌘X cut, ⌘V paste - files, like Finder
    // wishes it worked)

    /// App-global: cut state survives tab switches. URLs also land on the
    /// system pasteboard, so ⌘V in Finder works too.
    private static var cutPendingPaths: Set<String>?

    func copySelection(cut: Bool) {
        let urls = selectedAssets.map { $0.url }
        guard !urls.isEmpty else {
            flash("Select photos to \(cut ? "cut" : "copy")")
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        Self.cutPendingPaths = cut ? Set(urls.map { $0.path }) : nil
        let n = urls.count
        flash(cut ? "Cut \(n) photo\(n == 1 ? "" : "s") - ⌘V in another folder moves them"
                  : "Copied \(n) photo\(n == 1 ? "" : "s") - ⌘V in a folder pastes them")
    }

    func pasteIntoCurrentFolder() {
        guard let folder = currentFolder else {
            flash("Open a folder to paste into")
            return
        }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
        guard !urls.isEmpty else {
            flash("Nothing to paste")
            return
        }
        let isCut = Self.cutPendingPaths == Set(urls.map { $0.path })
        Self.cutPendingPaths = nil
        flash("\(isCut ? "Moving" : "Copying") \(urls.count) photo\(urls.count == 1 ? "" : "s")…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Cross-folder collisions ask, like Finder. Same-folder ⌘V is
            // excluded from the count - pasting in place means "duplicate",
            // and it keeps both without asking.
            let collisions = FileOps.collisionCount(urls, in: folder)
            let run: (FileOps.Collision) -> Void = { policy in
                let result = isCut ? FileOps.move(urls, to: folder, onCollision: policy)
                                   : FileOps.copy(urls, to: folder, onCollision: policy)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    FileOpsHistory.push("\(isCut ? "move" : "copy") to \(folder.lastPathComponent)",
                                        kind: isCut ? .move : .copy, result.records)
                    let skippedNote = result.skipped > 0 ? " - \(result.skipped) skipped" : ""
                    self.flashUndoable("\(isCut ? "Moved" : "Copied") \(result.primaries) photo\(result.primaries == 1 ? "" : "s") into \(folder.lastPathComponent)\(skippedNote)")
                    self.reloadCurrentFolderPreservingSelection()
                }
            }
            if collisions > 0 {
                DispatchQueue.main.async {
                    guard let policy = CollisionPrompt.ask(collisions: collisions, total: urls.count,
                                                           destination: folder.lastPathComponent) else { return }
                    DispatchQueue.global(qos: .userInitiated).async { run(policy) }
                }
            } else {
                run(.keepBoth)
            }
        }
    }

    /// The Finder "move to trash" sound - the canonical system path
    /// (stable across macOS versions). Silent if it can't be found.
    private static let trashSound: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/empty trash.aif"
        return NSSound(contentsOfFile: path, byReference: true)
    }()

    func trashSelection() {
        let assets = selectedAssets
        guard !assets.isEmpty else { return }
        // Fire the sound ON the gesture, like Finder - playing it after the
        // async trash finished made it feel laggy and detached ("too long").
        Self.trashSound?.stop()
        Self.trashSound?.play()
        let anchor = selectedIndex ?? 0
        let urls = assets.map { $0.url }
        flash("Moving \(urls.count) photo\(urls.count == 1 ? "" : "s") to Trash…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = FileOps.trash(urls)
            DispatchQueue.main.async {
                FileOpsHistory.push("move to Trash", result.records)
                self?.flashUndoable("Moved \(result.primaries) photo\(result.primaries == 1 ? "" : "s") to Trash")
                self?.reloadCurrentFolder(selecting: anchor)
            }
        }
    }

    /// Show a transient status message (public face of flash()).
    func announce(_ message: String) {
        flash(message)
    }

    /// External change (undo, Finder, another app) - reload holding position.
    func noteExternalChange(message: String?) {
        if let message { flash(message) }
        reloadCurrentFolderPreservingSelection()
    }

    /// Called after a drag-move to a sidebar folder completed.
    func noteFilesMoved(count: Int, to destination: URL) {
        let anchor = selectedIndex ?? 0
        flashUndoable("Moved \(count) photo\(count == 1 ? "" : "s") to \(destination.lastPathComponent)")
        reloadCurrentFolder(selecting: anchor)
    }

    func reloadCurrentFolder(selecting index: Int? = nil) {
        guard let folder = currentFolder else { return }
        pendingSelection = index
        preserveScrollOnNextApply = true
        loadFolder(folder)
    }

    private var pendingSelection: Int?
    private var flashTimer: Timer?
    private var aiDone = 0
    private var aiTotal = 0

    // MARK: - Folder watching (kernel events, zero cost until something changes)

    private var folderMonitor: DispatchSourceFileSystemObject?
    private var externalReloadTimer: Timer?
    private var lastSelfLoadAt = Date.distantPast

    /// Our own XMP sidecar flushes tickle the folder watcher - treat them
    /// like self-loads so we don't reload (and re-adopt) our own writes.
    private var xmpFlushObserver: NSObjectProtocol?

    private func observeXMPFlushes() {
        guard xmpFlushObserver == nil else { return }
        xmpFlushObserver = NotificationCenter.default.addObserver(
            forName: RatingsStore.xmpFlushActivity, object: nil, queue: .main
        ) { [weak self] _ in
            self?.lastSelfLoadAt = Date()
        }
    }

    private var watchGeneration = 0
    private var observingMoves = false

    /// Our own drag-moves reload the source grid IMMEDIATELY - the watcher
    /// path is throttled (correctly, for ingests) and left moved photos
    /// lingering on screen for a beat after a drop.
    private func observeFileMoves() {
        guard !observingMoves else { return }
        observingMoves = true
        NotificationCenter.default.addObserver(forName: FileOps.filesMoved, object: nil,
                                               queue: .main) { [weak self] note in
            guard let self,
                  let sources = note.userInfo?["sources"] as? [String],
                  let folder = self.currentFolder,
                  sources.contains(folder.path) else { return }
            // The moved photos are GONE - clear selection before the reload,
            // or the collection view re-applies the old index paths to
            // whatever photos now occupy those positions ("random" highlight).
            self.collectionView.deselectItems(at: self.collectionView.selectionIndexPaths)
            self.preserveScrollOnNextApply = true
            self.loadFolder(folder)
        }
    }

    /// A card is about to be ejected. If this tab is looking at it, drop
    /// the folder watcher - its O_EVTONLY descriptor pins the volume for
    /// as long as the tab lives, even in the background. The watcher comes
    /// back automatically on the next loadFolder.
    func releaseVolumeHold(under volumePaths: [String]) {
        guard let folder = currentFolderURL?.path else { return }
        let mine = folder.hasSuffix("/") ? folder : folder + "/"
        for path in volumePaths {
            let prefix = path.hasSuffix("/") ? path : path + "/"
            if mine.hasPrefix(prefix) {
                watchGeneration += 1        // orphan any in-flight open()
                folderMonitor?.cancel()     // cancel handler closes the fd
                folderMonitor = nil
                return
            }
        }
    }

    private func watchFolder(_ url: URL) {
        observeXMPFlushes()
        observeFileMoves()
        folderMonitor?.cancel()
        folderMonitor = nil
        // open() blocks while a sleeping external drive wakes its USB link -
        // paying that ON THE MAIN THREAD was a visible hitch in the folder
        // click. Open in the background; install the source back on main.
        // The generation token drops a late fd if the user has already
        // clicked elsewhere (or re-clicked), so we never leak a descriptor
        // or attach a watcher for a folder we left.
        watchGeneration += 1
        let generation = watchGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { return }
            DispatchQueue.main.async {
                guard let self, self.watchGeneration == generation else { close(fd); return }
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd,
                    eventMask: [.write, .rename, .delete, .link],
                    queue: .main
                )
                source.setEventHandler { [weak self] in
                    self?.scheduleExternalReload()
                }
                source.setCancelHandler { close(fd) }
                source.resume()
                self.folderMonitor = source
            }
        }
    }

    private var lastExternalReloadAt = Date.distantPast

    private func scheduleExternalReload() {
        // Frozen background tab: remember that the folder changed and do
        // the reload when the tab is next activated - zero work until then.
        guard isActiveTab else {
            reloadPendingWhileInactive = true
            return
        }
        // Our own operations already reload - only react to changes we
        // didn't cause (Finder, another app, an ingest in progress).
        guard Date().timeIntervalSince(lastSelfLoadAt) > 1.0 else { return }
        // THROTTLE, not debounce: during an ingest, events never stop -
        // a debounce that resets per event would wait for quiet that never
        // comes and show nothing until the very end. First event schedules
        // the refresh; the stream doesn't push it back.
        guard externalReloadTimer?.isValid != true else { return }
        externalReloadTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard Date().timeIntervalSince(self.lastSelfLoadAt) > 1.0 else { return }
            // Quiet during sustained streams (ingest); announce one-off changes.
            if Date().timeIntervalSince(self.lastExternalReloadAt) > 5.0 {
                self.flash("Folder refreshed")
            }
            self.lastExternalReloadAt = Date()
            self.reloadCurrentFolderPreservingSelection()
        }
    }

    /// Reload keeping the SAME PHOTO selected (by identity, not index) -
    /// files landing mid-ingest shift indexes constantly.
    private func reloadCurrentFolderPreservingSelection() {
        pendingSelectionID = selectedAsset?.id
        guard let folder = currentFolder else { return }
        preserveScrollOnNextApply = true
        loadFolder(folder)
    }

    private var pendingSelectionID: String?

    private func flash(_ text: String, duration: TimeInterval = 2.5, undoable: Bool = false) {
        pushStatus(text, undo: undoable)
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.updateStatus() // re-renders stats, hides Undo
        }
    }

    /// A flash for reversible file operations: the message plus a clickable
    /// Undo button (5s) - ⌘Z knowledge not required.
    private func flashUndoable(_ text: String) {
        flash(text, duration: 5.0, undoable: true)
    }

    /// Re-select a set of photos by id (display order preserved by the
    /// collection view), focusing/scrolling to one of them - used when
    /// returning from a selection-scoped expanded pass so the working set
    /// survives the round trip.
    func select(ids: [String], focusID: String) {
        let wanted = Set(ids)
        var paths: Set<IndexPath> = []
        var focusPath: IndexPath?
        for (i, asset) in displayedAssets.enumerated() where wanted.contains(asset.id) {
            let ip = IndexPath(item: i, section: 0)
            paths.insert(ip)
            if asset.id == focusID { focusPath = ip }
        }
        guard !paths.isEmpty else { return }
        collectionView.deselectItems(at: collectionView.selectionIndexPaths)
        collectionView.selectItems(at: paths, scrollPosition: [])
        if let fp = focusPath {
            collectionView.scrollToItems(at: [fp], scrollPosition: .nearestHorizontalEdge)
            selectionAnchor = fp.item
        }
        if let asset = selectedAsset { onSelectionChanged?(asset) }
    }

    /// (index, filename) pairs for the ⌘F palette - visible photos only,
    /// so a jump target is always somewhere the grid can actually go.
    func searchablePhotos() -> [(Int, String)] {
        displayedAssets.enumerated().map { ($0.offset, $0.element.filename) }
    }

    func select(index: Int) {
        guard index >= 0, index < displayedAssets.count else { return }
        let ip = IndexPath(item: index, section: 0)
        collectionView.deselectItems(at: collectionView.selectionIndexPaths)
        collectionView.selectItems(at: [ip], scrollPosition: .nearestHorizontalEdge)
        selectionAnchor = index
        shiftFocus = nil
        // Warm the full preview so Space is instant - but not on a memory
        // card, where arrow-scrolling would trigger a multi-MB read per
        // keystroke and starve the thumbnails.
        let url = displayedAssets[index].url
        if !FileOps.isOnRemovableVolume(url) {
            ThumbnailLoader.shared.prefetch(url, maxPixel: ThumbnailLoader.previewPixelSize)
        }
        FaceAnalyzer.shared.prioritize(displayedAssets[index].id)
        onSelectionChanged?(displayedAssets[index])
    }

    /// Finder-style shift-click: select everything between the anchor and
    /// the clicked item.
    private func selectRange(to target: Int) -> Bool {
        guard target >= 0, target < displayedAssets.count else { return false }
        let anchor = selectionAnchor ?? selectedIndex ?? target
        let range = min(anchor, target)...max(anchor, target)
        let ips = Set(range.map { IndexPath(item: $0, section: 0) })
        collectionView.deselectItems(at: collectionView.selectionIndexPaths)
        collectionView.selectItems(at: ips, scrollPosition: [])
        onSelectionChanged?(displayedAssets[target])
        flash("\(ips.count) selected")
        return true
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        if let ip = indexPaths.first, ip.item < displayedAssets.count {
            // Plain and ⌘ clicks move the range anchor (Finder behavior).
            selectionAnchor = ip.item
            let url = displayedAssets[ip.item].url
            if !FileOps.isOnRemovableVolume(url) {
                ThumbnailLoader.shared.prefetch(url, maxPixel: ThumbnailLoader.previewPixelSize)
            }
            onSelectionChanged?(displayedAssets[ip.item])
        }
    }

    private var columnsCount: Int {
        let usable = collectionView.bounds.width - layout.sectionInset.left - layout.sectionInset.right
        let per = layout.itemSize.width + layout.minimumInteritemSpacing
        return max(1, Int((usable + layout.minimumInteritemSpacing) / per))
    }

    /// Arrow keys: plain moves the single selection; ⇧ grows/shrinks a
    /// range from the anchor as you go (Finder semantics).
    private func arrow(_ delta: Int, shift: Bool) -> Bool {
        guard !displayedAssets.isEmpty else { return true }
        guard shift else { shiftFocus = nil; moveSelection(delta); return true }
        if selectionAnchor == nil { selectionAnchor = selectedIndex ?? 0 }
        let base = shiftFocus ?? selectedIndex ?? selectionAnchor ?? 0
        let target = max(0, min(displayedAssets.count - 1, base + delta))
        shiftFocus = target
        _ = selectRange(to: target)     // selects anchor…target, anchor unchanged
        collectionView.scrollToItems(at: [IndexPath(item: target, section: 0)],
                                     scrollPosition: .nearestHorizontalEdge)
        return true
    }

    private func moveSelection(_ delta: Int) {
        guard !displayedAssets.isEmpty else { return }
        // With a multi-selection, arrows anchor on the edge in travel direction
        // and collapse back to a single selection (Finder behavior).
        let items = collectionView.selectionIndexPaths.map { $0.item }
        let current = (delta > 0 ? items.max() : items.min()) ?? 0
        let target = max(0, min(displayedAssets.count - 1, current + delta))
        select(index: target)
    }

    // MARK: - Keyboard (called from the app-level key monitor)

    /// Returns true if the event was consumed.
    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 123: return arrow(-1, shift: event.modifierFlags.contains(.shift))            // ←
        case 124: return arrow(1, shift: event.modifierFlags.contains(.shift))             // →
        case 126: return arrow(-columnsCount, shift: event.modifierFlags.contains(.shift)) // ↑
        case 125: return arrow(columnsCount, shift: event.modifierFlags.contains(.shift))  // ↓
        case 115: select(index: 0); return true             // home
        case 119: select(index: displayedAssets.count - 1); return true // end
        case 49, 36:                                        // space, return
            if let index = selectedIndex { onOpenPreview?(index); return true }
            return false
        default:
            break
        }
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { return false }
        let ctrl = event.modifierFlags.contains(.control)
        // Control is only meaningful as the star/color swap on 0–5; for any
        // other key let it pass so ⌃-combos aren't silently hijacked.
        if ctrl, !["0", "1", "2", "3", "4", "5"].contains(chars) { return false }
        switch chars {
        // No auto-advance in the grid - advancing belongs to the expanded
        // view's rate-and-step rhythm. In a contact sheet you're often
        // rating a multi-selection or judging in place; jumping the
        // selection is disorienting.
        case "1", "2", "3", "4", "5":
            let n = Int(chars)!
            if RatingsStore.shared.digitSetsStar(control: ctrl) {
                applyToSelection(advance: false) { RatingsStore.shared.setRating(n, for: $0) }
            } else {
                applyToSelection(advance: false) { id in
                    RatingsStore.shared.setColorLabel(n, for: id)
                }
            }
            return true
        case "0":
            if RatingsStore.shared.digitSetsStar(control: ctrl) {
                applyToSelection(advance: false) { RatingsStore.shared.setRating(0, for: $0) }
            } else {
                applyToSelection(advance: false) { RatingsStore.shared.setColorLabel(0, for: $0) }
            }
            return true
        case "x":
            applyToSelection(advance: false) { RatingsStore.shared.toggleRejected($0) }
            return true
        case "u":
            // Unlabel - clears the color outright (vs. re-pressing its key).
            applyToSelection(advance: false) { RatingsStore.shared.setColorLabel(0, for: $0) }
            return true
        case "[", "]":
            // Photo Mechanic muscle memory: [ rotates CCW, ] rotates CW.
            rotateSelection(by: chars == "]" ? 90 : -90)
            return true
        case "=", "+":
            adjustThumbSize(by: 24); return true
        case "-", "_":
            adjustThumbSize(by: -24); return true
        case "s":
            // Survey: compare 2–4 selected frames side by side.
            let assets = selectedAssets
            if assets.count < 2 {
                flash("Select 2–4 photos to survey")
            } else if assets.count > 4 {
                flash("Survey compares up to 4 photos (\(assets.count) selected)")
            } else {
                onOpenSurvey?(assets)
            }
            return true
        default:
            return false
        }
    }

    private func rotateSelection(by degrees: Int) {
        let ips = collectionView.selectionIndexPaths.sorted()
        for ip in ips where ip.item < displayedAssets.count {
            RatingsStore.shared.rotate(displayedAssets[ip.item].id, by: degrees)
        }
        refreshThumbnails(at: ips)
        if let last = ips.last, last.item < displayedAssets.count {
            onSelectionChanged?(displayedAssets[last.item]) // inspector re-renders
        }
    }

    // MARK: - Context menu

    private static func dotImage(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    private func buildContextMenu(for ip: IndexPath?) -> NSMenu? {
        guard let ip, ip.item < displayedAssets.count else { return nil }
        // Finder behavior: right-clicking outside the selection retargets it.
        if !collectionView.selectionIndexPaths.contains(ip) {
            select(index: ip.item)
        }
        let menu = NSMenu()

        let ratingMenu = NSMenu()
        for rating in stride(from: 5, through: 0, by: -1) {
            let title = rating == 0 ? "None" : String(repeating: "★", count: rating)
            let item = NSMenuItem(title: title, action: #selector(menuSetRating(_:)), keyEquivalent: "\(rating)")
            item.keyEquivalentModifierMask = []
            item.target = self
            item.tag = rating
            ratingMenu.addItem(item)
        }
        let ratingRoot = NSMenuItem(title: "Rating", action: nil, keyEquivalent: "")
        ratingRoot.submenu = ratingMenu
        menu.addItem(ratingRoot)

        let colorMenu = NSMenu()
        for label in 1...5 {
            let item = NSMenuItem(title: Theme.labelNames[label], action: #selector(menuSetColor(_:)),
                                  keyEquivalent: label <= 4 ? "\(label + 5)" : "")
            item.keyEquivalentModifierMask = []
            item.target = self
            item.tag = label
            item.image = Self.dotImage(Theme.labelColors[label])
            colorMenu.addItem(item)
        }
        colorMenu.addItem(.separator())
        let noColor = NSMenuItem(title: "None", action: #selector(menuSetColor(_:)), keyEquivalent: "")
        noColor.target = self
        noColor.tag = 0
        colorMenu.addItem(noColor)
        let colorRoot = NSMenuItem(title: "Color Label", action: nil, keyEquivalent: "")
        colorRoot.submenu = colorMenu
        menu.addItem(colorRoot)

        let reject = NSMenuItem(title: "Reject", action: #selector(menuToggleReject(_:)), keyEquivalent: "x")
        reject.keyEquivalentModifierMask = []
        reject.target = self
        menu.addItem(reject)

        menu.addItem(.separator())

        let rotateLeft = NSMenuItem(title: "Rotate Left", action: #selector(menuRotateLeft(_:)), keyEquivalent: "[")
        rotateLeft.keyEquivalentModifierMask = []
        rotateLeft.target = self
        menu.addItem(rotateLeft)
        let rotateRight = NSMenuItem(title: "Rotate Right", action: #selector(menuRotateRight(_:)), keyEquivalent: "]")
        rotateRight.keyEquivalentModifierMask = []
        rotateRight.target = self
        menu.addItem(rotateRight)

        menu.addItem(.separator())

        let selectionCount = collectionView.selectionIndexPaths.count
        if selectionCount > 1 {
            let rename = NSMenuItem(title: "Rename \(selectionCount) Photos…",
                                    action: #selector(menuBatchRename(_:)), keyEquivalent: "")
            rename.target = self
            menu.addItem(rename)
        } else {
            let rename = NSMenuItem(title: "Rename…", action: #selector(menuRename(_:)), keyEquivalent: "")
            rename.target = self
            menu.addItem(rename)
        }

        let trash = NSMenuItem(title: "Move to Trash", action: #selector(menuTrash(_:)), keyEquivalent: "")
        trash.target = self
        menu.addItem(trash)
        let reveal = NSMenuItem(title: "Show in Finder", action: #selector(menuReveal(_:)), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        if FaceAnalyzer.shared.isEnabled {
            let rescan = NSMenuItem(title: "Rescan Faces", action: #selector(menuRescanFaces(_:)), keyEquivalent: "")
            rescan.target = self
            menu.addItem(rescan)
        }

        if LightroomBridge.isAvailable || PhotoshopBridge.isAvailable {
            menu.addItem(.separator())
            let count = collectionView.selectionIndexPaths.count
            if LightroomBridge.isAvailable {
                let lightroom = NSMenuItem(title: count > 1 ? "Send \(count) Photos to Lightroom" : "Send to Lightroom",
                                           action: #selector(menuSendToLightroom(_:)), keyEquivalent: "")
                lightroom.target = self
                menu.addItem(lightroom)
            }
            if PhotoshopBridge.isAvailable {
                let photoshop = NSMenuItem(title: count > 1 ? "Edit \(count) Photos in Photoshop" : "Edit in Photoshop",
                                           action: #selector(menuEditInPhotoshop(_:)), keyEquivalent: "")
                photoshop.target = self
                menu.addItem(photoshop)
            }
        }

        return menu
    }

    @objc private func menuSendToLightroom(_ sender: NSMenuItem) { sendSelectionToLightroom() }
    @objc private func menuEditInPhotoshop(_ sender: NSMenuItem) { sendSelectionToPhotoshop() }

    func sendSelectionToLightroom() {
        let urls = selectedAssets.map { $0.url }
        guard !urls.isEmpty else {
            flash("Select photos to send to Lightroom")
            return
        }
        // Sidecars MUST be on disk before Lightroom reads the files.
        RatingsStore.shared.flushXMPNow()
        LightroomBridge.send(urls) { [weak self] ok in
            self?.flash(ok
                ? "Sent \(urls.count) photo\(urls.count == 1 ? "" : "s") to Lightroom - confirm the import there"
                : "Couldn't reach Lightroom")
        }
    }

    func sendSelectionToPhotoshop() {
        let urls = selectedAssets.map { $0.url }
        guard !urls.isEmpty else {
            flash("Select photos to edit in Photoshop")
            return
        }
        RatingsStore.shared.flushXMPNow()
        PhotoshopBridge.send(urls) { [weak self] ok in
            self?.flash(ok
                ? "Opened \(urls.count) photo\(urls.count == 1 ? "" : "s") in Photoshop"
                : "Couldn't reach Photoshop")
        }
    }

    @objc private func menuSetRating(_ sender: NSMenuItem) {
        let rating = sender.tag
        applyToSelection(advance: false) { RatingsStore.shared.setRating(rating, for: $0) }
    }

    @objc private func menuSetColor(_ sender: NSMenuItem) {
        let label = sender.tag
        applyToSelection(advance: false) { RatingsStore.shared.setColorLabel(label, for: $0) }
    }

    @objc private func menuToggleReject(_ sender: NSMenuItem) {
        applyToSelection(advance: false) { RatingsStore.shared.toggleRejected($0) }
    }

    @objc private func menuRotateLeft(_ sender: NSMenuItem) { rotateSelection(by: -90) }
    @objc private func menuRotateRight(_ sender: NSMenuItem) { rotateSelection(by: 90) }
    @objc private func menuTrash(_ sender: NSMenuItem) { trashSelection() }

    // MARK: - Renaming (companions and cull data travel together)

    @objc private func menuRename(_ sender: NSMenuItem) {
        guard let asset = selectedAsset else { return }
        let currentBase = asset.url.deletingPathExtension().lastPathComponent
        let alert = NSAlert()
        alert.messageText = "Rename “\(asset.filename)”"
        alert.informativeText = "The extension stays; paired JPEG and XMP sidecar rename with it."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = currentBase
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let base = sanitizeBase(field.stringValue)
        guard !base.isEmpty, base != currentBase else { return }
        performRenames([(asset, base)])
    }

    @objc private func menuBatchRename(_ sender: NSMenuItem) {
        let assets = selectedAssets
        guard assets.count > 1 else { return }
        let alert = NSAlert()
        alert.messageText = "Rename \(assets.count) photos in sequence"
        alert.informativeText = "Result: BaseName + number (start value sets the padding - “001” gives three digits). Order follows the current sort."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let baseField = NSTextField(frame: .zero)
        baseField.placeholderString = "Chen_Wedding_"
        let startField = NSTextField(frame: .zero)
        startField.stringValue = "001"
        let stack = NSStackView(views: [baseField, startField])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 56)
        baseField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        startField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        alert.accessoryView = stack
        alert.window.initialFirstResponder = baseField
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let base = sanitizeBase(baseField.stringValue)
        let startString = startField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, let start = Int(startString) else { NSSound.beep(); return }
        let padding = startString.count
        let plans = assets.enumerated().map { (index, asset) in
            (asset, base + String(format: "%0\(padding)d", start + index))
        }
        performRenames(plans)
    }

    private func sanitizeBase(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    private func performRenames(_ plans: [(asset: PhotoAsset, newBase: String)]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            var records: [(from: URL, to: URL)] = []
            var migrations: [(String, String)] = []
            var renamed = 0
            var skipped = 0
            var firstNewID: String?

            for (asset, newBase) in plans {
                let parent = asset.url.deletingLastPathComponent()
                let files = [asset.url] + FileOps.companions(of: asset.url)
                let moves: [(URL, URL)] = files.map {
                    ($0, parent.appendingPathComponent(newBase + "." + $0.pathExtension))
                }
                // Collision with anything that isn't the file itself → skip photo.
                if moves.contains(where: { $0.1.path != $0.0.path && fm.fileExists(atPath: $0.1.path) }) {
                    skipped += 1
                    continue
                }
                var okay = true
                for (from, to) in moves where from.path != to.path {
                    do {
                        try fm.moveItem(at: from, to: to)
                        records.append((from, to))
                    } catch {
                        okay = false
                        NSLog("funo: rename failed \(from.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                if okay {
                    renamed += 1
                    let newID = parent.appendingPathComponent(newBase + "." + asset.url.pathExtension).path
                    migrations.append((asset.id, newID))
                    if firstNewID == nil { firstNewID = newID }
                }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                for (old, new) in migrations {
                    RatingsStore.shared.migrate(from: old, to: new)
                }
                FileOpsHistory.push("rename", records)
                var message = "Renamed \(renamed) photo\(renamed == 1 ? "" : "s")"
                if skipped > 0 { message += " · \(skipped) skipped (name in use)" }
                self.flashUndoable(message)
                self.pendingSelectionID = firstNewID
                if let folder = self.currentFolder { self.loadFolder(folder) }
            }
        }
    }

    @objc private func menuReveal(_ sender: NSMenuItem) {
        NSWorkspace.shared.activateFileViewerSelecting(selectedAssets.map { $0.url })
    }

    @objc private func menuRescanFaces(_ sender: NSMenuItem) {
        let assets = selectedAssets
        guard !assets.isEmpty else { return }
        FaceAnalyzer.shared.rescan(assets)
        flash("Rescanning faces on \(assets.count) photo\(assets.count == 1 ? "" : "s")…")
    }

    /// Re-request thumbnails after a rotation (the cache key changed).
    private func refreshThumbnails(at ips: [IndexPath]) {
        for ip in ips {
            guard ip.item < displayedAssets.count,
                  let item = collectionView.item(at: ip) as? PhotoItem else { continue }
            let url = displayedAssets[ip.item].url
            ThumbnailLoader.shared.request(url, maxPixel: ThumbnailLoader.thumbnailPixelSize) { [weak item] image in
                item?.setThumbnail(image, for: url)
            }
        }
    }

    private func applyToSelection(advance: Bool = true, _ change: (String) -> Void) {
        let ips = collectionView.selectionIndexPaths.sorted()
        guard !ips.isEmpty else { return }
        // Rating with a multi-selection rates every selected photo.
        for ip in ips where ip.item < displayedAssets.count {
            let asset = displayedAssets[ip.item]
            change(asset.id)
            (collectionView.item(at: ip) as? PhotoItem)?.refreshCullState(assetID: asset.id)
        }
        updateStatus()
        if let last = ips.last, last.item < displayedAssets.count {
            onSelectionChanged?(displayedAssets[last.item]) // inspector stays in sync
            // Photo Mechanic muscle memory: rate/reject a SINGLE frame advances
            // to the next one. Bulk operations hold position.
            if advance, ips.count == 1 { select(index: last.item + 1) }
        }
    }

    /// Called by the preview when culling happened there, so the grid stays in sync.
    func refreshVisibleCullStates() {
        for ip in collectionView.indexPathsForVisibleItems() {
            guard ip.item < displayedAssets.count,
                  let item = collectionView.item(at: ip) as? PhotoItem else { continue }
            let asset = displayedAssets[ip.item]
            item.refreshCullState(assetID: asset.id)
            // A rotation in the preview invalidates this thumb's cache key.
            if let cached = ThumbnailLoader.shared.cachedImage(for: asset.url, maxPixel: ThumbnailLoader.thumbnailPixelSize) {
                item.setThumbnail(cached, for: asset.url)
            } else {
                ThumbnailLoader.shared.request(asset.url, maxPixel: ThumbnailLoader.thumbnailPixelSize) { [weak item] image in
                    item?.setThumbnail(image, for: asset.url)
                }
            }
        }
        updateStatus()
    }
}

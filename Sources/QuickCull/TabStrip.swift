import AppKit

/// Tabbed contact sheets - the anti-Photo-Mechanic version.
///
/// Philosophy (differs from PM on purpose):
/// - Tabs are bookmarks you place DELIBERATELY (⌘T, ⌘-click a folder),
///   never history that piles up. Plain sidebar clicks replace the active
///   tab, exactly like before tabs existed.
/// - Background tabs are FROZEN: a folder path, scroll position, selection
///   and filter - kilobytes. No decoding, no prefetch, no face priority.
///   Only the visible tab feeds the pipelines. Ten tabs cost what one does.
/// - The strip itself doesn't exist until there are 2+ tabs; single-folder
///   sessions look pixel-identical to the pre-tab app.
final class TabbedContactSheetController: NSViewController {

    private let strip = TabStrip()
    private let container = NSView()
    private var stripHeight: NSLayoutConstraint!

    private(set) var grids: [PhotoGridViewController] = []
    private(set) var activeIndex = 0

    /// MainSplit wires each new grid's callbacks (preview, faces) here.
    var configureGrid: ((PhotoGridViewController) -> Void)?
    /// Fired whenever the active tab (or its folder) changes.
    var onActiveFolderChanged: ((URL?) -> Void)?

    var activeGrid: PhotoGridViewController { grids[activeIndex] }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        strip.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(strip)
        view.addSubview(container)
        stripHeight = strip.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: view.topAnchor),
            strip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stripHeight,
            container.topAnchor.constraint(equalTo: strip.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        strip.onSelect = { [weak self] index in self?.activate(index) }
        strip.onClose = { [weak self] index in
            guard let self else { return }
            // Closing a tab is "close this view," never "quit the app" -
            // ⌘Q and the red button are the quit gestures. Closing the
            // LAST tab resets it to a fresh empty tab; the window stays.
            if !self.closeTab(at: index) { self.resetToEmptyTab() }
        }
        strip.onReorder = { [weak self] from, to in self?.moveTab(from: from, to: to) }
        strip.onNewTab = { [weak self] in self?.newTab() }

        appendGrid()
        mountActive()
        refreshStrip()
    }

    // MARK: - Public operations

    /// Sidebar click / Open Folder / ingest destination.
    ///
    /// ONE FOLDER = ONE TAB: if the folder is already open in any tab, we
    /// switch to that tab instead of opening it twice. Two live views of the
    /// same folder means two watchers reacting to the same disk events and
    /// two selections fighting over one truth - all cost, no workflow.
    func open(_ url: URL, inNewTab: Bool) {
        if grids.isEmpty { _ = view } // force viewDidLoad → first grid
        let path = url.standardizedFileURL.path
        if let existing = grids.firstIndex(where: { $0.currentFolderURL?.standardizedFileURL.path == path }) {
            if existing != activeIndex {
                activate(existing)
                activeGrid.announce("\(url.lastPathComponent) was already open - switched to its tab")
            }
            return
        }
        // Reuse the active tab if it's an empty placeholder - no point
        // spawning a second tab next to an unused blank "New Tab".
        if inNewTab, activeGrid.currentFolderURL != nil {
            appendGrid()
            activate(grids.count - 1, notify: false)
        }
        activeGrid.loadFolder(url)
        refreshStrip()
        onActiveFolderChanged?(url)
    }

    /// ⌘T - a blank tab, browser-style. (It can't duplicate the current
    /// folder anymore: one folder = one tab.)
    func newTab() {
        if grids.isEmpty { _ = view } // force viewDidLoad → first grid
        appendGrid()
        activate(grids.count - 1, notify: false)
        activeGrid.showNewTabPlaceholder()
        refreshStrip()
        onActiveFolderChanged?(nil)
    }

    /// ⌘W - close the active tab. Returns false when it's the last tab
    /// (caller resets it to a fresh empty tab instead of quitting).
    @discardableResult
    func closeActiveTab() -> Bool {
        if closeTab(at: activeIndex) { return true }
        resetToEmptyTab()
        return true
    }

    /// The last tab can't be closed away into nothing - closing it clears
    /// it back to a fresh welcome tab. The app quits only via ⌘Q / red button.
    private func resetToEmptyTab() {
        let stale = activeGrid
        appendGrid()
        activate(grids.count - 1, notify: false)
        // Drop the old grid now that a fresh one is mounted.
        if let staleIndex = grids.firstIndex(where: { $0 === stale }), grids.count > 1 {
            grids.remove(at: staleIndex)
            stale.prepareForClose()
            stale.view.removeFromSuperview()
            stale.removeFromParent()
            if activeIndex >= grids.count { activeIndex = grids.count - 1 }
        }
        mountActive()
        activeGrid.didBecomeActiveTab()
        activeGrid.showNewTabPlaceholder()
        refreshStrip()
        onActiveFolderChanged?(nil)
    }

    func activate(_ index: Int) { activate(index, notify: true) }

    /// ⌘1–⌘8 jump to that tab; ⌘9 jumps to the LAST tab (browser convention).
    func activateNumbered(_ number: Int) {
        guard grids.count > 1 else { return }
        if number == 9 {
            activate(grids.count - 1)
        } else {
            activate(number - 1)
        }
    }

    /// ⌘←/⌘→ (and ⌘⇧[ / ⌘⇧]) - cycle with wraparound, like a browser.
    func activateRelative(_ delta: Int) {
        guard grids.count > 1 else { return }
        let next = (activeIndex + delta + grids.count) % grids.count
        activate(next)
    }

    // MARK: - Internals

    @discardableResult
    private func appendGrid() -> PhotoGridViewController {
        let grid = PhotoGridViewController()
        configureGrid?(grid)
        // Any internal load (history, rename) must keep tab + window titles
        // truthful.
        grid.onFolderChanged = { [weak self, weak grid] url in
            guard let self, let grid else { return }
            self.refreshStrip()
            if grid === self.activeGrid { self.onActiveFolderChanged?(url) }
        }
        addChild(grid)
        grids.append(grid)
        return grid
    }

    private func activate(_ index: Int, notify: Bool) {
        guard grids.indices.contains(index) else { return }
        // Clicking the already-active tab must be a no-op - rebuilding the
        // strip here would break drag gestures and waste a redraw.
        guard index != activeIndex || grids.count == 1 else { return }
        if grids.indices.contains(activeIndex), index != activeIndex {
            grids[activeIndex].didResignActiveTab()
        }
        activeIndex = index
        mountActive()
        activeGrid.didBecomeActiveTab()
        refreshStrip()
        if notify { onActiveFolderChanged?(activeGrid.currentFolderURL) }
    }

    /// Drag-reorder from the strip.
    func moveTab(from: Int, to: Int) {
        guard from != to, grids.indices.contains(from), grids.indices.contains(to) else { return }
        let moving = grids.remove(at: from)
        grids.insert(moving, at: to)
        if activeIndex == from {
            activeIndex = to
        } else if from < activeIndex, to >= activeIndex {
            activeIndex -= 1
        } else if from > activeIndex, to <= activeIndex {
            activeIndex += 1
        }
        refreshStrip()
    }

    private func closeTab(at index: Int) -> Bool {
        guard grids.count > 1, grids.indices.contains(index) else { return false }
        let closing = grids.remove(at: index)
        closing.prepareForClose()
        closing.view.removeFromSuperview()
        closing.removeFromParent()
        if index < activeIndex {
            activeIndex -= 1
        } else if activeIndex >= grids.count {
            activeIndex = grids.count - 1
        }
        mountActive()
        activeGrid.didBecomeActiveTab()
        refreshStrip()
        onActiveFolderChanged?(activeGrid.currentFolderURL)
        return true
    }

    private func mountActive() {
        for sub in container.subviews { sub.removeFromSuperview() }
        let gridView = activeGrid.view
        gridView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(gridView)
        NSLayoutConstraint.activate([
            gridView.topAnchor.constraint(equalTo: container.topAnchor),
            gridView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            gridView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            gridView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    private func refreshStrip() {
        let titles = grids.map { $0.currentFolderURL?.lastPathComponent ?? "New Tab" }
        strip.update(titles: titles, active: activeIndex)
        // Browser-style: the strip is ALWAYS visible - it's how anyone
        // learns tabs exist, it shows a folder breadcrumb, and the "+"
        // gives new-tab a permanent home.
        strip.isHidden = false
        stripHeight.constant = 30
    }
}

/// The slim tab bar: graphite, hairline-separated, amber underline on the
/// active tab, close button appears on hover. Rebuilt on every change -
/// deliberate tabs stay few, so there's nothing to optimize.
final class TabStrip: NSView {

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onReorder: ((Int, Int) -> Void)?
    var onNewTab: (() -> Void)?

    private let stack = NSStackView()
    private let plusButton = NSButton(title: "", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg0.cgColor

        stack.orientation = .horizontal
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // Browser-standard "+" - the permanent new-tab affordance.
        plusButton.attributedTitle = NSAttributedString(string: "+", attributes: [
            .foregroundColor: Theme.tx1,
            .font: NSFont.systemFont(ofSize: 16, weight: .regular)
        ])
        plusButton.isBordered = false
        plusButton.setButtonType(.momentaryChange)
        plusButton.toolTip = "New tab (⌘T)"
        plusButton.target = self
        plusButton.action = #selector(plusTapped(_:))
        plusButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plusButton)

        let bottomLine = NSView()
        bottomLine.wantsLayer = true
        bottomLine.layer?.backgroundColor = Theme.line.cgColor
        bottomLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomLine)

        // NOT required: cell widths are required constants, so a required
        // fit-inside-the-strip constraint becomes unsatisfiable when tabs
        // overflow. At 999 the tabs clip instead of forcing a resize.
        let stackFits = plusButton.leadingAnchor.constraint(greaterThanOrEqualTo: stack.trailingAnchor)
        stackFits.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackFits,
            plusButton.leadingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 4),
            plusButton.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5),
            plusButton.widthAnchor.constraint(equalToConstant: 30),
            plusButton.heightAnchor.constraint(equalToConstant: 24),
            plusButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            bottomLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomLine.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func plusTapped(_ sender: Any?) { onNewTab?() }

    func update(titles: [String], active: Int) {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        for (i, title) in titles.enumerated() {
            let cell = TabCell(title: title, isActive: i == active)
            cell.onSelect = { [weak self] in self?.onSelect?(i) }
            cell.onClose = { [weak self] in self?.onClose?(i) }
            cell.onDragEnded = { [weak self, weak cell] dx in
                guard let self, let cell else { return }
                let landedX = cell.frame.midX + dx
                let cells = self.stack.arrangedSubviews
                let target = cells.lastIndex(where: { landedX >= $0.frame.minX }) ?? 0
                if target != i { self.onReorder?(i, target) }
            }
            stack.addArrangedSubview(cell)
        }
    }
}

/// One tab: close button (hover-revealed) + truncating title + amber
/// underline when active. Fixed measured width so hover states never
/// shift neighbors.
private final class TabCell: NSView {

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    /// Fired on mouse-up after a real horizontal drag, with the x distance
    /// travelled (strip coordinates).
    var onDragEnded: ((CGFloat) -> Void)?

    private var dragStartX: CGFloat?
    private var dragDX: CGFloat = 0

    private let isActive: Bool
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private let underline = NSView()
    private var hovered = false

    init(title: String, isActive: Bool) {
        self.isActive = isActive
        super.init(frame: .zero)
        wantsLayer = true

        label.stringValue = title
        label.font = NSFont.systemFont(ofSize: 11.5, weight: isActive ? .semibold : .medium)  // ramp: secondary(+Strong)
        label.textColor = isActive ? Theme.tx0 : Theme.tx1
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        closeButton.attributedTitle = NSAttributedString(string: "✕", attributes: [
            .foregroundColor: Theme.tx1,
            .font: NSFont.systemFont(ofSize: 9, weight: .bold)
        ])
        closeButton.isBordered = false
        closeButton.setButtonType(.momentaryChange)
        closeButton.target = self
        closeButton.action = #selector(closeTapped(_:))
        closeButton.alphaValue = 0
        closeButton.toolTip = "Close tab (⌘W)"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        underline.wantsLayer = true
        underline.layer?.backgroundColor = Theme.accent.cgColor
        underline.isHidden = !isActive
        underline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(underline)

        // Measured width: title at its widest weight + close/padding chrome,
        // clamped so one long wedding folder name can't eat the strip.
        let font = Theme.secondaryStrong
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        let width = min(190, max(92, titleWidth + 46))

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            underline.leadingAnchor.constraint(equalTo: leadingAnchor),
            underline.trailingAnchor.constraint(equalTo: trailingAnchor),
            underline.bottomAnchor.constraint(equalTo: bottomAnchor),
            underline.heightAnchor.constraint(equalToConstant: 2)
        ])
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func closeTapped(_ sender: Any?) { onClose?() }

    override func mouseDown(with event: NSEvent) {
        // Close button handles its own clicks. Everywhere else we WAIT -
        // selecting on mouse-down rebuilds the strip, which would tear this
        // cell out from under an in-progress drag. Click resolves on
        // mouse-up; drag resolves as reorder.
        let p = convert(event.locationInWindow, from: nil)
        if !closeButton.frame.insetBy(dx: -4, dy: -4).contains(p) {
            dragStartX = event.locationInWindow.x
            dragDX = 0
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartX else { return }
        dragDX = event.locationInWindow.x - dragStartX
        layer?.setAffineTransform(CGAffineTransform(translationX: dragDX, y: 0))
        layer?.zPosition = 10
    }

    override func mouseUp(with event: NSEvent) {
        let dx = dragDX
        let wasTracking = dragStartX != nil
        layer?.setAffineTransform(.identity)
        layer?.zPosition = 0
        dragStartX = nil
        dragDX = 0
        guard wasTracking else { return }
        if abs(dx) > 12 {
            onDragEnded?(dx)
        } else {
            onSelect?()
        }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        restyle()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        restyle()
    }

    private func restyle() {
        layer?.backgroundColor = isActive ? Theme.bg2.cgColor
                               : (hovered ? Theme.bg1.cgColor : NSColor.clear.cgColor)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            closeButton.animator().alphaValue = (isActive || hovered) ? 1 : 0
        }
    }
}

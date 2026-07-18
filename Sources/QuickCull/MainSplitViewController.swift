import AppKit

/// Window layout: folder tree | contact sheet. (The metadata inspector is
/// the third column in the mockup; it joins in milestone 2.)
/// Also owns the full-window preview overlay.
final class MainSplitViewController: NSSplitViewController {

    private let sidebar = FolderSidebarViewController()
    private let tabs = TabbedContactSheetController()
    private var previewOverlay: PreviewOverlayView? { didSet { refreshWindowTitle() } }
    private var surveyOverlay: SurveyOverlay? { didSet { refreshWindowTitle() } }
    private var searchPalette: SearchPaletteView?
    private var shortcutsOverlay: ShortcutsOverlayView?

    func showSearchPalette() {
        guard previewOverlay == nil, surveyOverlay == nil, searchPalette == nil,
              let container = view.window?.contentView else { return }
        let palette = SearchPaletteView(frame: container.bounds)
        palette.photoSource = { [weak self] in self?.grid.searchablePhotos() ?? [] }
        palette.onJumpToPhoto = { [weak self] index in self?.grid.select(index: index) }
        palette.onOpenFolder = { [weak self] url, newTab in
            self?.tabs.open(url, inNewTab: newTab)
            self?.sidebar.reveal(url)   // the tree shows where you landed
        }
        palette.onDismiss = { [weak self] in
            self?.searchPalette = nil
            self?.view.window?.makeFirstResponder(self?.grid.view)
        }
        searchPalette = palette
        palette.present(in: container)
    }

    /// The ? cheat-sheet. Toggles: ? again (or Esc, or a click outside) closes.
    func toggleShortcuts() {
        if let open = shortcutsOverlay { open.onDismiss?(); return }
        guard let container = view.window?.contentView else { return }
        let overlay = ShortcutsOverlayView(frame: container.bounds)
        overlay.onDismiss = { [weak self] in
            self?.shortcutsOverlay?.removeFromSuperview()
            self?.shortcutsOverlay = nil
            self?.view.window?.makeFirstResponder(self?.grid.view)
        }
        shortcutsOverlay = overlay
        overlay.present(in: container)
    }
    private var titleFolderURL: URL?

    /// Lightroom-style title: "Folder - f/uno - Grid|Expanded|Survey".
    /// Centralized so folder changes AND mode changes both repaint it.
    private func refreshWindowTitle() {
        guard let window = view.window else { return }
        let mode = previewOverlay != nil ? "Expanded" : (surveyOverlay != nil ? "Survey" : "Grid")
        window.title = titleFolderURL.map { "\($0.lastPathComponent) - f/uno - \(mode)" } ?? "f/uno"
        window.representedURL = titleFolderURL   // feeds the ⌘-click path menu
    }
    private var keyMonitor: Any?

    /// The window-level status footer (owned by RootViewController).
    weak var footer: StatusFooterView? {
        didSet {
            footer?.onUndo = { [weak self] in self?.undoFileOperation() }
            footer?.onSendLightroom = { [weak self] in self?.grid.sendSelectionToLightroom() }
            footer?.onSendPhotoshop = { [weak self] in self?.grid.sendSelectionToPhotoshop() }
        }
    }

    /// Every grid reference routes through the active tab.
    private var grid: PhotoGridViewController { tabs.activeGrid }

    override func viewDidLoad() {
        super.viewDidLoad()

        // App-level key monitor. Bare `swift run` executables (no app bundle)
        // don't always route key events down the responder chain the way a
        // bundled .app does, so culling keys are intercepted here directly.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = self.view.window,
                  event.window === window,
                  window.attachedSheet == nil,
                  !(window.firstResponder is NSTextView) // don't steal keys from text editing
            else { return event }
            // Cheat-sheet: swallow keys while it's up; ? toggles it (bare
            // key - just "/", no shift, works in every mode).
            if let sc = self.shortcutsOverlay { return sc.handleKey(event) ? nil : event }
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               event.characters == "/" {
                self.toggleShortcuts(); return nil
            }
            // ⌘⇧] / ⌘⇧[ still cycle tabs (Safari/Chrome muscle memory) -
            // the menu shows ⌘→ / ⌘←, so these are handled here directly.
            if event.modifierFlags.contains(.command), event.modifierFlags.contains(.shift),
               event.keyCode == 30 || event.keyCode == 33 { // ] and [
                self.selectAdjacentTab(event.keyCode == 30 ? 1 : -1)
                return nil
            }
            // ⌘F - the search palette (photos here, folders anywhere).
            if event.modifierFlags.intersection([.command, .control, .option]) == .command,
               event.keyCode == 3 {
                self.showSearchPalette()
                return nil
            }
            // Clipboard file ops: ⌘C / ⌘X / ⌘V on photos. Text editing is
            // already excluded above, so these can't steal from a rename.
            if event.modifierFlags.intersection([.command, .control, .option]) == .command,
               self.previewOverlay == nil, self.surveyOverlay == nil,
               let clipKey = event.charactersIgnoringModifiers?.lowercased() {
                switch clipKey {
                case "c": self.grid.copySelection(cut: false); return nil
                case "x": self.grid.copySelection(cut: true); return nil
                case "v": self.grid.pasteIntoCurrentFolder(); return nil
                default: break
                }
            }
            let cullMods = event.modifierFlags.intersection([.command, .control, .option])
            // Backtick toggles color-first rating mode - works in every mode
            // (grid, expanded, survey). Bare key only; text fields are already
            // excluded above, so a rename can still type a backtick.
            if cullMods.isEmpty, event.charactersIgnoringModifiers == "`" {
                RatingsStore.shared.colorFirstRating.toggle()
                return nil
            }
            // Command/Option combos belong to menus and the OS. Bare Control is
            // our secondary cull modifier (⌃1–5 = the other axis), so let it
            // fall through to the handlers instead of passing it to the system.
            if cullMods.contains(.command) || cullMods.contains(.option) {
                return event
            }
            if let overlay = self.previewOverlay {
                return overlay.handleKey(event) ? nil : event
            }
            if let survey = self.surveyOverlay {
                return survey.handleKey(event) ? nil : event
            }
            return self.grid.handleKey(event) ? nil : event
        }

        splitView.autosaveName = "QuickCullSplit"

        // Wire BEFORE the split item loads the tabs view - the first grid is
        // created inside tabs.viewDidLoad and must get its callbacks.
        tabs.configureGrid = { [weak self] grid in
            grid.onOpenPreview = { [weak self] index in
                self?.openPreview(at: index)
            }
            grid.onFaceResult = { [weak self] id in
                self?.previewOverlay?.noteFaceResult(for: id)
            }
            grid.onOpenSurvey = { [weak self] assets in
                self?.openSurvey(assets)
            }
            grid.onUndoRequested = { [weak self] in
                self?.undoFileOperation()
            }
            grid.onStatusChanged = { [weak self] text, undoVisible in
                self?.footer?.setStatus(text, undoVisible: undoVisible)
            }
        }
        // Eject wants the card back: any tab watching a folder on that
        // volume lets go of its descriptor before the unmount fires.
        NotificationCenter.default.addObserver(
            forName: .funoPrepareEject, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let paths = note.userInfo?["paths"] as? [String] else { return }
            for grid in self.tabs.grids { grid.releaseVolumeHold(under: paths) }
        }

        tabs.onActiveFolderChanged = { [weak self] url in
            self?.titleFolderURL = url
            self?.refreshWindowTitle()
            if let url { SearchPaletteView.noteRecent(url) }   // feeds ⌘F
        }

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        addSplitViewItem(sidebarItem)

        let gridItem = NSSplitViewItem(viewController: tabs)
        gridItem.minimumThickness = 400
        addSplitViewItem(gridItem)

        sidebar.onSelectFolder = { [weak self] url in
            self?.tabs.open(url, inNewTab: false)
        }

        sidebar.onOpenFolderInNewTab = { [weak self] url in
            guard let self, self.previewOverlay == nil, self.surveyOverlay == nil else { return }
            self.tabs.open(url, inNewTab: true)
        }

        sidebar.onFilesMoved = { [weak self] count, destination in
            self?.grid.noteFilesMoved(count: count, to: destination)
        }
    }

    // MARK: - Tabs (File menu)

    func newTab() {
        guard previewOverlay == nil, surveyOverlay == nil else { return }
        tabs.newTab()
    }

    /// Bring the welcome screen (and the aperture ring) back: clear the
    /// "don't show" flag and open it on a fresh empty tab.
    func showWelcomeScreen() {
        UserDefaults.standard.set(false, forKey: "QuickCullHideWelcome")
        guard previewOverlay == nil, surveyOverlay == nil else { return }
        tabs.newTab()
    }

    /// ⌘W: close the active tab. The last tab resets to a fresh empty tab
    /// rather than quitting - ⌘Q and the red button are the quit gestures.
    func closeTabOrWindow() {
        guard previewOverlay == nil, surveyOverlay == nil else { return }
        tabs.closeActiveTab()
    }

    /// ⌘[ / ⌘] - folder history of the active tab.
    func goBack() {
        guard previewOverlay == nil, surveyOverlay == nil else { return }
        grid.goBack()
    }

    func goForward() {
        guard previewOverlay == nil, surveyOverlay == nil else { return }
        grid.goForward()
    }

    /// ⌘1–⌘9 (9 = last tab, browser convention).
    func selectTab(numbered number: Int) {
        guard previewOverlay == nil, surveyOverlay == nil else { return }
        tabs.activateNumbered(number)
    }

    /// ⌘⇧] / ⌘⇧[ - cycle tabs with wraparound.
    func selectAdjacentTab(_ delta: Int) {
        guard previewOverlay == nil, surveyOverlay == nil else { return }
        tabs.activateRelative(delta)
    }

    // Called from the Edit menu (AppDelegate).
    func selectAllPhotos() { grid.selectAllVisible() }
    func deselectAllPhotos() { grid.deselectAll() }
    func trashSelection() { grid.trashSelection() }

    func copyPhotos() {
        guard previewOverlay == nil, surveyOverlay == nil else { return }
        grid.copySelection(cut: false)
    }

    func cutPhotos() {
        guard previewOverlay == nil, surveyOverlay == nil else { return }
        grid.copySelection(cut: true)
    }

    func pastePhotos() {
        guard previewOverlay == nil, surveyOverlay == nil else { return }
        grid.pasteIntoCurrentFolder()
    }

    func noteCachesCleared() {
        grid.noteExternalChange(message: "Caches cleared - next load is a true cold start")
    }

    func undoFileOperation() {
        guard let batch = FileOpsHistory.popLatest() else {
            grid.noteExternalChange(message: "Nothing to undo")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let message = FileOpsHistory.undoLatest(batch)
            DispatchQueue.main.async {
                self?.grid.noteExternalChange(message: message)
            }
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func showFolder(_ url: URL) {
        tabs.open(url, inNewTab: false)
    }

    /// Ingest started: open the destination, say so, and make sure the main
    /// window is actually visible behind the ingest panel.
    func showIngestDestination(_ url: URL) {
        showFolder(url)
        // Unfold the tree down to the landing folder - watching files pour
        // into a folder you can SEE beats trusting a path string. (Same
        // reveal the ⌘F palette uses; new folders may need a beat to appear
        // in the prefetched listing, hence the tiny delay.)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sidebar.refreshBranchContaining(url)
            self?.sidebar.reveal(url)
        }
        grid.announce("Ingesting into \(url.lastPathComponent) - photos appear as they land")
        view.window?.orderFront(nil)
    }

    // MARK: - Survey overlay (2–4 frames side by side)

    private func openSurvey(_ assets: [PhotoAsset]) {
        guard surveyOverlay == nil, previewOverlay == nil,
              let container = view.window?.contentView else { return }
        let overlay = SurveyOverlay(frame: container.bounds, assets: assets)
        overlay.autoresizingMask = [.width, .height]
        overlay.onClose = { [weak self] in self?.closeSurvey() }
        overlay.onCullChanged = { [weak self] in
            self?.grid.refreshVisibleCullStates()
        }
        overlay.onOpenFull = { [weak self] asset in
            guard let self else { return }
            self.closeSurvey()
            if let index = self.grid.displayedAssets.firstIndex(where: { $0.id == asset.id }) {
                self.grid.select(index: index)
                self.openPreview(at: index)
            }
        }
        container.addSubview(overlay)
        surveyOverlay = overlay
    }

    private func closeSurvey() {
        surveyOverlay?.removeFromSuperview()
        surveyOverlay = nil
        grid.refreshVisibleCullStates()
    }

    // MARK: - Preview overlay

    private func openPreview(at index: Int) {
        guard previewOverlay == nil, let container = view.window?.contentView else { return }

        // Photo Mechanic-style scoping: opening expanded view from a multi-
        // selection makes THAT SELECTION the working set - the filmstrip and
        // arrows never leave it. A single selection scopes to the whole
        // (filtered) folder as before.
        let all = grid.displayedAssets
        let selected = grid.selectedAssets
        var scope = all
        var start = index
        if selected.count >= 2, index < all.count,
           let pos = selected.firstIndex(where: { $0.id == all[index].id }) {
            scope = selected
            start = pos
        }
        let scoped = scope.count != all.count

        let overlay = PreviewOverlayView(frame: container.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.onClose = { [weak self] lastIndex in
            guard let self else { return }
            // lastIndex is within the SCOPE - map back to a grid index.
            let asset = scope[max(0, min(lastIndex, scope.count - 1))]
            if scoped {
                // Coming back from a scoped pass, the range is still the
                // user's working set - keep it selected, focus the last frame.
                self.closePreview()
                self.grid.select(ids: scope.map { $0.id }, focusID: asset.id)
            } else {
                let gridIndex = self.grid.displayedAssets.firstIndex { $0.id == asset.id } ?? index
                self.closePreview()
                self.grid.select(index: gridIndex)
            }
        }
        overlay.onCullChanged = { [weak self] in
            self?.grid.refreshVisibleCullStates()
        }
        container.addSubview(overlay)
        overlay.present(assets: scope, startIndex: start)
        view.window?.makeFirstResponder(overlay)
        previewOverlay = overlay
    }

    private func closePreview() {
        previewOverlay?.removeFromSuperview()
        previewOverlay = nil
        grid.refreshVisibleCullStates()
        if let window = view.window {
            // Hand keyboard focus back to the grid.
            window.makeFirstResponder(grid.view.subviews.compactMap { $0 as? NSScrollView }.first?.documentView)
        }
    }
}

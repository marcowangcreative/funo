import AppKit
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var window: NSWindow!
    private var mainController: MainSplitViewController!
    /// Sparkle: checks the appcast on a schedule and on demand. Configured
    /// via Info.plist (SUFeedURL + SUPublicEDKey, set by build_app.sh).
    /// Started ONLY inside a real .app bundle — under `swift run` there is
    /// no Info.plist/bundle, and starting the updater throws an alert on
    /// every dev launch ("The updater failed to start… version of debug").
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    private var updaterAvailable: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }
    private weak var colorFirstMenuItem: NSMenuItem?
    private weak var clearCachesMenuItem: NSMenuItem?
    private var titleLabel: NSTextField?
    private var titleObservation: NSKeyValueObservation?
    private let titlePathMenu = PathMenuPresenter()

    /// THE fix: a hard ceiling the window server enforces BELOW autolayout.
    /// Every prior attempt was reactive — let the window grow, then shove it
    /// back with setFrame — which a required constraint just undoes on the
    /// next layout pass (that's why it kept returning). `maxSize` cannot be
    /// overridden by any constraint: the window physically cannot exceed it,
    /// and content compresses instead. Kept current as screens change.
    private func clampWindowToScreen() {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        window.maxSize = visible.size
        if window.frame.width > visible.width || window.frame.height > visible.height {
            var frame = window.frame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
            frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
            window.setFrame(frame, display: true)
        }
    }

    func windowDidChangeScreen(_ notification: Notification) { clampWindowToScreen() }

    func windowWillClose(_ notification: Notification) {
        // Closing the MAIN window must not strand the License window — with
        // it open, the main window isn't "the last window", so the app kept
        // running with a lone activation dialog floating in space. Take it
        // down too; then the last-window-closed rule quits normally.
        // (window.close() skips windowShouldClose, so the expired-gate
        // terminate path can't recurse — and quitting IS what the gate
        // wants anyway.)
        guard (notification.object as? NSWindow) === window else { return }
        LicenseWindowController.shared.window?.close()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if updaterAvailable { updaterController.startUpdater() }
        #if DEBUG
        MainThreadWatchdog.shared.start()
        #endif
        FolderTemplates.ensureDefaults()
        LicenseManager.shared.revalidateInBackground()
        buildMenu()

        // Root = split view + one full-width status footer beneath it.
        let root = RootViewController()
        mainController = root.split

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "f/uno"
        window.backgroundColor = Theme.bg0
        window.contentViewController = root
        // Assigning a contentViewController can shrink the window to the view's
        // fitting size; force the intended size back before showing it.
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.setFrameAutosaveName("QuickCullMainWindow")
        window.minSize = NSSize(width: 900, height: 600)
        window.delegate = self

        // Centered title, Lightroom-style. Modern macOS leading-aligns the
        // system title next to the traffic lights; there is no alignment
        // knob, so we hide it and center our own label in the title bar.
        // The label MIRRORS window.title via KVO — everything else keeps
        // setting window.title normally (Mission Control and accessibility
        // still read it; only the drawing is ours).
        window.titleVisibility = .hidden
        if let titlebar = window.standardWindowButton(.closeButton)?.superview {
            // [folder icon] Folder Name - f/uno, centered as ONE unit —
            // the proxy-icon look, hand-rolled because the system title is
            // leading-aligned on modern macOS and has no centering knob.
            let icon = TitleBarPathIcon()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 16).isActive = true

            let label = TitleBarPathLabel(labelWithString: window.title)
            label.font = NSFont.titleBarFont(ofSize: NSFont.systemFontSize(for: .regular))
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.alignment = .center

            let stack = NSStackView(views: [icon, label])
            stack.orientation = .horizontal
            stack.spacing = 5
            stack.translatesAutoresizingMaskIntoConstraints = false
            titlebar.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: titlebar.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: titlebar.centerYAnchor),
                // Never collide with the traffic lights on long names.
                stack.leadingAnchor.constraint(greaterThanOrEqualTo: titlebar.leadingAnchor, constant: 80),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: titlebar.trailingAnchor, constant: -80)
            ])
            titlePathMenu.urlProvider = { [weak window] in window?.representedURL }
            titlePathMenu.onOpenFolder = { [weak self] url in self?.mainController.showFolder(url) }
            label.pathMenu = titlePathMenu
            icon.pathMenu = titlePathMenu
            titleLabel = label
            titleObservation = window.observe(\.title, options: [.initial, .new]) { [weak label] win, _ in
                label?.stringValue = win.title
            }
            // Our own mark leads the lockup (Lightroom shows ITS icon, not a
            // folder). Static — the app icon doesn't change with the folder.
            let appIcon = NSApp.applicationIconImage ?? NSImage()
            appIcon.size = NSSize(width: 16, height: 16)
            icon.image = appIcon
        }
        window.center()
        // First launch on a small display: 1440×900 is wider than a 13"
        // laptop's usable area. The clamp already exists for screen changes —
        // it just was never applied to the INITIAL frame.
        clampWindowToScreen()
        window.center()
        window.makeKeyAndOrderFront(nil)

        // License gate: silent while licensed or in the early trial; a
        // dismissible reminder in the final week; a hard gate once expired.
        switch LicenseManager.shared.status {
        case .licensed:
            break
        case .trial(let days):
            if days <= 7 { LicenseWindowController.shared.show(gate: false) }
        case .expired:
            LicenseWindowController.shared.show(gate: true)
        }

        // Cap the window to the screen NOW (before any split can grow it)
        // and keep it capped as the window moves between monitors.
        clampWindowToScreen()

        // Photographers' tools live in the dark.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Never lose the last second of culling to the debounce windows.
        RatingsStore.shared.flushForTermination()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About f/uno", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let updatesItem = NSMenuItem(title: "Check for Updates…",
                                     action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                     keyEquivalent: "")
        updatesItem.target = updaterController
        appMenu.addItem(updatesItem)
        let licenseItem = NSMenuItem(title: "License…", action: #selector(showLicense(_:)), keyEquivalent: "")
        licenseItem.target = self
        appMenu.addItem(licenseItem)
        // Diagnostic, not a feature: hold ⌥ while the menu is open and it
        // appears. Testers who need it can be told "Option-click the f/uno
        // menu"; everyone else never sees it.
        let clearCaches = NSMenuItem(title: "Clear Caches (cold-start test)", action: #selector(clearCaches(_:)), keyEquivalent: "")
        clearCaches.target = self
        clearCaches.isHidden = true
        appMenu.addItem(clearCaches)
        clearCachesMenuItem = clearCaches
        appMenu.delegate = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide f/uno", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit f/uno", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open Folder…", action: #selector(openFolder(_:)), keyEquivalent: "o")
        let newTabItem = NSMenuItem(title: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")
        newTabItem.target = self
        fileMenu.addItem(newTabItem)
        let closeTabItem = NSMenuItem(title: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "w")
        closeTabItem.target = self
        fileMenu.addItem(closeTabItem)
        fileMenu.addItem(.separator())
        let ingestItem = NSMenuItem(title: "Ingest Cards…", action: #selector(showIngest(_:)), keyEquivalent: "i")
        ingestItem.target = self
        fileMenu.addItem(ingestItem)
        let trashItem = NSMenuItem(title: "Move to Trash", action: #selector(trashSelection(_:)), keyEquivalent: "\u{08}")
        trashItem.target = self
        fileMenu.addItem(trashItem)
        fileMenu.addItem(.separator())
        let templatesItem = NSMenuItem(title: "Folder Templates…", action: #selector(openTemplates(_:)), keyEquivalent: "")
        templatesItem.target = self
        fileMenu.addItem(templatesItem)
        fileMenuItem.submenu = fileMenu

        // Edit menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        let undoItem = NSMenuItem(title: "Undo File Operation", action: #selector(undoFileOperation(_:)), keyEquivalent: "z")
        undoItem.target = self
        editMenu.addItem(undoItem)
        editMenu.addItem(.separator())
        let findItem = NSMenuItem(title: "Find…", action: #selector(showFind(_:)), keyEquivalent: "f")
        findItem.target = self
        editMenu.addItem(findItem)
        editMenu.addItem(.separator())
        // Clipboard file ops — the key monitor handles the shortcuts; these
        // exist so the commands are discoverable in the menu.
        let cutItem = NSMenuItem(title: "Cut Photos", action: #selector(cutPhotos(_:)), keyEquivalent: "x")
        cutItem.target = self
        editMenu.addItem(cutItem)
        let copyItem = NSMenuItem(title: "Copy Photos", action: #selector(copyPhotos(_:)), keyEquivalent: "c")
        copyItem.target = self
        editMenu.addItem(copyItem)
        let pasteItem = NSMenuItem(title: "Paste Photos", action: #selector(pastePhotos(_:)), keyEquivalent: "v")
        pasteItem.target = self
        editMenu.addItem(pasteItem)
        editMenu.addItem(.separator())
        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(selectAllPhotos(_:)), keyEquivalent: "a")
        selectAllItem.target = self
        editMenu.addItem(selectAllItem)
        let deselectItem = NSMenuItem(title: "Deselect All", action: #selector(deselectAllPhotos(_:)), keyEquivalent: "d")
        deselectItem.target = self
        editMenu.addItem(deselectItem)
        editMenuItem.submenu = editMenu

        // View menu — navigation + photo surround
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        let backItem = NSMenuItem(title: "Back", action: #selector(goBack(_:)), keyEquivalent: "[")
        backItem.target = self
        viewMenu.addItem(backItem)
        let forwardItem = NSMenuItem(title: "Forward", action: #selector(goForward(_:)), keyEquivalent: "]")
        forwardItem.target = self
        viewMenu.addItem(forwardItem)
        viewMenu.addItem(.separator())
        for surround in Surround.allCases {
            let item = NSMenuItem(title: "Surround: \(surround.displayName)",
                                  action: #selector(setSurround(_:)), keyEquivalent: "")
            item.target = self
            item.tag = surround.rawValue
            item.state = Theme.surround == surround ? .on : .off
            viewMenu.addItem(item)
        }
        viewMenu.addItem(.separator())
        // Color-first rating: 1–5 set colors, ⌃1–5 set stars. The backtick
        // toggle is handled in the key monitor (a bare-key menu equivalent
        // would hijack "`" even while renaming), so it's noted in the title.
        let colorFirstItem = NSMenuItem(title: "Color-First Rating  (` toggles)",
                                        action: #selector(toggleColorFirst(_:)), keyEquivalent: "")
        colorFirstItem.target = self
        colorFirstItem.state = RatingsStore.shared.colorFirstRating ? .on : .off
        viewMenu.addItem(colorFirstItem)
        self.colorFirstMenuItem = colorFirstItem
        NotificationCenter.default.addObserver(self, selector: #selector(cullModeDidChange),
                                               name: RatingsStore.cullModeChanged, object: nil)
        viewMenuItem.submenu = viewMenu

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())

        // Tab navigation: ⌘→/⌘← cycle (⌘⇧]/⌘⇧[ also work, handled in the
        // key monitor for browser muscle memory), ⌘1–⌘8 jump, ⌘9 = last.
        let nextTab = NSMenuItem(title: "Show Next Tab", action: #selector(showNextTab(_:)),
                                 keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        nextTab.keyEquivalentModifierMask = [.command]
        nextTab.target = self
        windowMenu.addItem(nextTab)
        let prevTab = NSMenuItem(title: "Show Previous Tab", action: #selector(showPreviousTab(_:)),
                                 keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        prevTab.keyEquivalentModifierMask = [.command]
        prevTab.target = self
        windowMenu.addItem(prevTab)
        windowMenu.addItem(.separator())
        for n in 1...9 {
            let item = NSMenuItem(title: n == 9 ? "Last Tab" : "Tab \(n)",
                                  action: #selector(selectNumberedTab(_:)), keyEquivalent: "\(n)")
            item.target = self
            item.tag = n
            windowMenu.addItem(item)
        }
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func newTab(_ sender: Any?) {
        mainController.newTab()
    }

    @objc private func goBack(_ sender: Any?) {
        mainController.goBack()
    }

    @objc private func goForward(_ sender: Any?) {
        mainController.goForward()
    }

    @objc private func selectNumberedTab(_ sender: NSMenuItem) {
        mainController.selectTab(numbered: sender.tag)
    }

    @objc private func showNextTab(_ sender: Any?) {
        mainController.selectAdjacentTab(1)
    }

    @objc private func showPreviousTab(_ sender: Any?) {
        mainController.selectAdjacentTab(-1)
    }

    @objc private func closeTab(_ sender: Any?) {
        mainController.closeTabOrWindow()
    }

    @objc private func openTemplates(_ sender: Any?) {
        TemplateEditor.show()
    }

    @objc private func undoFileOperation(_ sender: Any?) {
        if let editor = activeTextEditor { editor.undoManager?.undo(); return }
        mainController.undoFileOperation()
    }

    @objc private func clearCaches(_ sender: Any?) {
        CacheDB.shared.clear()
        ThumbnailLoader.shared.clearMemoryCaches()
        FaceAnalyzer.shared.clearResults()
        mainController.noteCachesCleared()
    }

    @objc private func showIngest(_ sender: Any?) {
        let controller = mainController
        IngestController.show(onOpenFolder: { [weak controller] url in
            controller?.showIngestDestination(url)
        })
    }

    @objc private func setSurround(_ sender: NSMenuItem) {
        guard let surround = Surround(rawValue: sender.tag) else { return }
        Theme.surround = surround
        for item in sender.menu?.items ?? [] {
            item.state = item.tag == surround.rawValue ? .on : .off
        }
    }

    @objc private func showFind(_ sender: Any?) {
        mainController.showSearchPalette()
    }

    @objc private func showLicense(_ sender: Any?) {
        LicenseWindowController.shared.show()
    }

    @objc private func toggleColorFirst(_ sender: Any?) {
        RatingsStore.shared.colorFirstRating.toggle()
    }

    /// Keep the menu checkmark in sync however the mode was flipped (menu or
    /// the backtick shortcut in the key monitor).
    @objc private func cullModeDidChange() {
        colorFirstMenuItem?.state = RatingsStore.shared.colorFirstRating ? .on : .off
    }

    /// Menu key equivalents are APP-GLOBAL: "Paste Photos" owns ⌘V even
    /// when the user is typing in a text field (the license key field was
    /// the victim — ⌘V fired photo-paste at the grid instead of pasting
    /// text). When any text editor has focus, these forward to it.
    private var activeTextEditor: NSTextView? {
        NSApp.keyWindow?.firstResponder as? NSTextView
    }

    @objc private func selectAllPhotos(_ sender: Any?) {
        if let editor = activeTextEditor { editor.selectAll(sender); return }
        mainController.selectAllPhotos()
    }

    @objc private func cutPhotos(_ sender: Any?) {
        if let editor = activeTextEditor { editor.cut(sender); return }
        mainController.cutPhotos()
    }

    @objc private func copyPhotos(_ sender: Any?) {
        if let editor = activeTextEditor { editor.copy(sender); return }
        mainController.copyPhotos()
    }

    @objc private func pastePhotos(_ sender: Any?) {
        if let editor = activeTextEditor { editor.paste(sender); return }
        mainController.pastePhotos()
    }

    @objc private func deselectAllPhotos(_ sender: Any?) {
        mainController.deselectAllPhotos()
    }

    @objc private func trashSelection(_ sender: Any?) {
        mainController.trashSelection()
    }

    @objc private func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Browse"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.mainController.showFolder(url)
        }
    }
}

// MARK: - App menu: ⌥ reveals the cache diagnostic
extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        guard let item = clearCachesMenuItem, menu === item.menu else { return }
        item.isHidden = !NSEvent.modifierFlags.contains(.option)
    }
}

/// ⌘-click on the title lockup — the app icon OR the text — pops the folder
/// path hierarchy, Lightroom-style. Because f/uno IS the folder browser,
/// choosing an ancestor opens it here, not in Finder.
final class PathMenuPresenter: NSObject {
    var urlProvider: (() -> URL?)?
    var onOpenFolder: ((URL) -> Void)?

    func popUp(from view: NSView) {
        guard let url = urlProvider?() else { return }
        let menu = NSMenu()
        var current: URL? = url
        while let u = current {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: u.path),
                                  action: #selector(openPathComponent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = u
            let icon = NSWorkspace.shared.icon(forFile: u.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
            let parent = u.deletingLastPathComponent()
            current = parent.path != u.path ? parent : nil
            if u.path == "/" { current = nil }
        }
        menu.popUp(positioning: menu.items.first,
                   at: NSPoint(x: view.bounds.midX, y: view.bounds.minY - 4), in: view)
    }

    @objc private func openPathComponent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return }
        onOpenFolder?(url)
    }
}

final class TitleBarPathLabel: NSTextField {
    var pathMenu: PathMenuPresenter?
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let pathMenu {
            pathMenu.popUp(from: self)
        } else {
            super.mouseDown(with: event)
        }
    }
}

final class TitleBarPathIcon: NSImageView {
    var pathMenu: PathMenuPresenter?
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let pathMenu {
            pathMenu.popUp(from: self)
        } else {
            super.mouseDown(with: event)
        }
    }
}

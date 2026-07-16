import AppKit

/// The anti-Photo-Mechanic ingest dialog: cards are auto-detected, you name
/// the job, pick a template, press Start. The grid opens on the destination
/// immediately — the folder watcher pours thumbnails in as files land, so
/// culling starts on file #1 while file #800 is still copying.
final class IngestController: NSWindowController, NSWindowDelegate {

    private static var current: IngestController?

    static func show(onOpenFolder: @escaping (URL) -> Void) {
        let controller = current ?? IngestController()
        current = controller
        controller.onOpenFolder = onOpenFolder
        controller.refreshCards()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var onOpenFolder: ((URL) -> Void)?
    private struct CardRow {
        let master: NSButton
        var sections: [(button: NSButton, folder: URL)]
    }
    private var cardRows: [CardRow] = []
    private var job: IngestJob?

    private let cardsStack = NSStackView()
    private let noCardsLabel = NSTextField(labelWithString: "No cards detected")
    private let destinationLabel = NSTextField(labelWithString: "")
    private let jobField = NSTextField()
    private let templatePopup = NSPopUpButton()
    private let copyIntoPopup = NSPopUpButton()
    private let startButton = NSButton()
    private let cancelButton = NSButton()
    private let progressBar = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let errorsButton = NSButton()
    private var lastErrors: [String] = []

    private var destination: URL {
        get {
            if let saved = UserDefaults.standard.string(forKey: "QuickCullIngestDest") {
                return URL(fileURLWithPath: saved)
            }
            return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: "QuickCullIngestDest")
            destinationLabel.stringValue = newValue.path
        }
    }

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ingest Cards"
        window.center()
        self.init(window: window)
        window.delegate = self
        buildUI()
    }

    func windowWillClose(_ notification: Notification) {
        job?.cancel()
        Self.current = nil
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        func header(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text.uppercased())
            label.font = .systemFont(ofSize: 10, weight: .bold)
            label.textColor = .secondaryLabelColor
            return label
        }

        let cardsHeader = header("Cards")
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshTapped(_:)))
        refresh.controlSize = .small
        let cardsRow = NSStackView(views: [cardsHeader, NSView(), refresh])
        cardsRow.orientation = .horizontal

        cardsStack.orientation = .vertical
        cardsStack.alignment = .leading
        cardsStack.spacing = 6

        noCardsLabel.font = .systemFont(ofSize: 12)
        noCardsLabel.textColor = .tertiaryLabelColor

        let destHeader = header("Destination")
        destinationLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        destinationLabel.textColor = .secondaryLabelColor
        destinationLabel.lineBreakMode = .byTruncatingMiddle
        destinationLabel.stringValue = destination.path
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseDestination(_:)))
        choose.controlSize = .small
        let destRow = NSStackView(views: [destinationLabel, choose])
        destRow.orientation = .horizontal

        let jobHeader = header("Job Name  (becomes the folder)")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        jobField.stringValue = formatter.string(from: Date()) + " "
        jobField.placeholderString = "2026-07-12 Chen Wedding"

        let templateHeader = header("Folder Template")
        templatePopup.removeAllItems()
        templatePopup.addItem(withTitle: "None")
        templatePopup.addItems(withTitles: FolderTemplates.names)
        templatePopup.target = self
        templatePopup.action = #selector(templateChanged(_:))

        let copyIntoHeader = header("Copy Files Into")
        rebuildCopyInto()

        startButton.title = "Start Ingest"
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.target = self
        startButton.action = #selector(startTapped(_:))

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped(_:))
        cancelButton.isHidden = true

        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.isHidden = true

        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle

        errorsButton.title = "Show Failures…"
        errorsButton.bezelStyle = .rounded
        errorsButton.controlSize = .small
        errorsButton.contentTintColor = .systemRed
        errorsButton.target = self
        errorsButton.action = #selector(showErrors(_:))
        errorsButton.isHidden = true

        let stack = NSStackView(views: [
            cardsRow, cardsStack, noCardsLabel,
            destHeader, destRow,
            jobHeader, jobField,
            templateHeader, templatePopup,
            copyIntoHeader, copyIntoPopup,
            progressBar, statusLabel, errorsButton,
            NSStackView(views: [NSView(), cancelButton, startButton])
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: cardsStack)
        stack.setCustomSpacing(16, after: destRow)
        stack.setCustomSpacing(16, after: jobField)
        stack.setCustomSpacing(16, after: templatePopup)
        stack.setCustomSpacing(18, after: copyIntoPopup)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            destRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            jobField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cardsRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressBar.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        if let last = stack.views.last as? NSStackView {
            last.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    // MARK: - Cards

    private var cardScanGeneration = 0

    private func refreshCards() {
        for view in cardsStack.arrangedSubviews {
            cardsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        cardRows.removeAll()
        noCardsLabel.isHidden = true

        // Card detection stats EVERY mounted volume (fileExists on <vol>/DCIM)
        // and lists each card's DCIM — on main that woke every sleeping drive
        // SERIALLY with the sheet frozen. Detect in the background; build the
        // checkboxes when the answers land. The generation token drops a
        // stale scan if the user hit Refresh (or a volume mounted) meanwhile.
        cardScanGeneration += 1
        let generation = cardScanGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found: [(card: URL, name: String, sections: [URL])] = IngestJob.detectCards().map { card in
                (card,
                 (try? card.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? card.lastPathComponent,
                 IngestJob.sections(of: card))
            }
            DispatchQueue.main.async {
                guard let self, self.cardScanGeneration == generation else { return }
                self.buildCardRows(found)
            }
        }
    }

    private func buildCardRows(_ found: [(card: URL, name: String, sections: [URL])]) {
        noCardsLabel.isHidden = !found.isEmpty

        for (_, name, sections) in found {
            let master = NSButton(checkboxWithTitle: name, target: self, action: #selector(masterToggled(_:)))
            master.state = .on
            master.font = .systemFont(ofSize: 13, weight: .semibold)
            cardsStack.addArrangedSubview(master)

            var row = CardRow(master: master, sections: [])
            // Not everyone wants the whole card: each DCIM subfolder is
            // individually selectable.
            for section in sections {
                let label = section.lastPathComponent == "DCIM" ? "All files" : section.lastPathComponent
                let check = NSButton(checkboxWithTitle: "\(label)  (counting…)", target: nil, action: nil)
                check.state = .on
                check.controlSize = .small
                let indent = NSStackView(views: [check])
                indent.orientation = .horizontal
                indent.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
                cardsStack.addArrangedSubview(indent)
                row.sections.append((check, section))

                DispatchQueue.global(qos: .utility).async { [weak check] in
                    let files = IngestJob.mediaFiles(under: section)
                    let bytes = files.reduce(Int64(0)) {
                        $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    }
                    let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                    DispatchQueue.main.async {
                        check?.title = "\(label)  —  \(files.count) files, \(size)"
                    }
                }
            }
            cardRows.append(row)
        }
        window?.layoutIfNeeded()
    }

    @objc private func masterToggled(_ sender: NSButton) {
        guard let row = cardRows.first(where: { $0.master === sender }) else { return }
        for (button, _) in row.sections { button.state = sender.state }
    }

    @objc private func refreshTapped(_ sender: Any?) {
        refreshCards()
    }

    @objc private func templateChanged(_ sender: Any?) {
        rebuildCopyInto()
    }

    /// "Copy Files Into" options: job folder root, or a top-level folder of
    /// the chosen template — ceremony card straight into "02 Ceremony".
    private func rebuildCopyInto() {
        let previous = copyIntoPopup.titleOfSelectedItem
        copyIntoPopup.removeAllItems()
        copyIntoPopup.addItem(withTitle: "Job folder")
        if let template = templatePopup.titleOfSelectedItem, template != "None",
           let paths = FolderTemplates.all[template] {
            let topLevel = paths.filter { !$0.contains("/") }
            copyIntoPopup.addItems(withTitles: topLevel)
        }
        if let previous, copyIntoPopup.itemTitles.contains(previous) {
            copyIntoPopup.selectItem(withTitle: previous)
        }
    }

    @objc private func chooseDestination(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = destination
        panel.prompt = "Set Destination"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.destination = url
        }
    }

    // MARK: - Run

    @objc private func startTapped(_ sender: Any?) {
        let sources = cardRows.flatMap { row in
            row.sections.filter { $0.button.state == .on }.map { $0.folder }
        }
        guard !sources.isEmpty else { NSSound.beep(); return }
        let jobName = jobField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jobName.isEmpty else {
            NSSound.beep()
            window?.makeFirstResponder(jobField)
            return
        }

        let jobFolder = destination.appendingPathComponent(jobName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: jobFolder, withIntermediateDirectories: true)
        } catch {
            statusLabel.stringValue = "Couldn't create job folder: \(error.localizedDescription)"
            return
        }
        if let template = templatePopup.titleOfSelectedItem, template != "None" {
            FolderTemplates.apply(template, to: jobFolder)
        }

        // Files land in the job folder or directly inside a template folder.
        var target = jobFolder
        if let into = copyIntoPopup.titleOfSelectedItem, into != "Job folder" {
            target = jobFolder.appendingPathComponent(into, isDirectory: true)
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        }

        // Open the grid on the destination NOW — thumbnails pour in live.
        onOpenFolder?(target)

        startButton.isEnabled = false
        cancelButton.isHidden = false
        progressBar.isHidden = false
        statusLabel.stringValue = "Starting…"

        let job = IngestJob()
        self.job = job
        job.onProgress = { [weak self] progress in
            guard let self else { return }
            if progress.bytesTotal > 0 {
                self.progressBar.doubleValue = Double(progress.bytesDone) / Double(progress.bytesTotal)
            }
            let done = ByteCountFormatter.string(fromByteCount: progress.bytesDone, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: progress.bytesTotal, countStyle: .file)
            var line = "\(progress.filesDone)/\(progress.filesTotal) files · \(done) of \(total)"
            if progress.skipped > 0 { line += " · \(progress.skipped) already there" }
            self.statusLabel.stringValue = line
        }
        job.onComplete = { [weak self] copied, skipped, errors in
            guard let self else { return }
            self.progressBar.doubleValue = 1
            self.startButton.isEnabled = true
            self.startButton.title = "Ingest Again"
            self.cancelButton.isHidden = true
            self.lastErrors = errors
            self.errorsButton.isHidden = errors.isEmpty
            self.errorsButton.title = "Show \(errors.count) Failure\(errors.count == 1 ? "" : "s")…"
            var line = "Done — \(copied) copied"
            if skipped > 0 { line += ", \(skipped) skipped" }
            if !errors.isEmpty {
                line = "⚠ Done with FAILURES — \(copied) copied, \(errors.count) failed. Do NOT format the card."
                self.statusLabel.textColor = .systemRed
            } else {
                self.statusLabel.textColor = .secondaryLabelColor
            }
            self.statusLabel.stringValue = line
            for error in errors { NSLog("funo ingest error: \(error)") }
            self.job = nil
        }
        job.start(sources: sources, destination: target)
    }

    @objc private func cancelTapped(_ sender: Any?) {
        job?.cancel()
        statusLabel.stringValue = "Cancelling…"
    }

    @objc private func showErrors(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(lastErrors.count) file\(lastErrors.count == 1 ? "" : "s") failed to copy"
        alert.informativeText = "These files are still on the card — do not format it. "
            + "Re-running the same ingest retries only what's missing.\n\n"
            + lastErrors.prefix(25).joined(separator: "\n")
            + (lastErrors.count > 25 ? "\n…and \(lastErrors.count - 25) more" : "")
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

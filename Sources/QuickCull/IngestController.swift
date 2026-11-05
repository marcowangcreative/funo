import AppKit
import QuickCullCore

/// One ingest window. Every setting is on the surface: source, destination,
/// folder pattern, naming, options, and a live original → new name → path
/// table. Rename stays off until the checkbox is on, even if a pattern was
/// saved earlier inside the old hidden drawer.
final class IngestController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    private static var current: IngestController?

    static func show(onOpenFolder: @escaping (URL) -> Void) {
        let controller = current ?? IngestController()
        current = controller
        controller.onOpenFolder = onOpenFolder
        controller.reloadSources()
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func closeIfOpen() {
        current?.window?.close()
    }

    private var onOpenFolder: ((URL) -> Void)?
    private var job: IngestJob?

    private struct SourceItem {
        var url: URL
        var title: String
        var isGroup: Bool
        var checked: Bool
    }

    private struct Planned {
        var source: URL
        var row: IngestPreviewRow
    }

    private var sources: [SourceItem] = []
    private var inventory: [String: [IngestSourceFile]] = [:]
    private var planned: [Planned] = []
    private var scanGeneration = 0
    private var previewGeneration = 0
    private var previewWork: DispatchWorkItem?

    private let sourceTable = NSTableView()
    private let previewTable = NSTableView()
    private let jobField = NSTextField()
    private let destLabel = NSTextField(labelWithString: "No destination yet")
    private let templatePopup = NSPopUpButton()
    private let pathField = NSTextField()
    private let pathExample = NSTextField(labelWithString: "")
    private let subfolderLabel = NSTextField(labelWithString: "")
    private let preserveCheck = NSButton(checkboxWithTitle: "Keep card folders", target: nil, action: nil)
    private let renameCheck = NSButton(checkboxWithTitle: "Rename files", target: nil, action: nil)
    private let nameField = NSTextField()
    private let nameNote = NSTextField(labelWithString: "")
    private let backupCheck = NSButton(checkboxWithTitle: "Second copy", target: nil, action: nil)
    private let backupLabel = NSTextField(labelWithString: "No backup folder")
    private let skipCheck = NSButton(checkboxWithTitle: "Skip duplicates (same name and size)", target: nil, action: nil)
    private let ejectCheck = NSButton(checkboxWithTitle: "Eject card when finished", target: nil, action: nil)
    private let metadataCheck = NSButton(checkboxWithTitle: "Write a job-name sidecar", target: nil, action: nil)
    private let summaryLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let errorView = NSTextView()
    private let startButton = NSButton(title: "Copy & Start Culling", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let ejectButton = NSButton(title: "Eject", target: nil, action: nil)

    private var destination: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: "QuickCullIngestDest") else { return nil }
            return URL(fileURLWithPath: path)
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: "QuickCullIngestDest") }
    }
    private var backupDestination: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: "QuickCullBackupDest") else { return nil }
            return URL(fileURLWithPath: path)
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: "QuickCullBackupDest") }
    }

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ingest"
        window.backgroundColor = Theme.bg0
        window.minSize = NSSize(width: 860, height: 640)
        window.center()
        self.init(window: window)
        window.delegate = self
        buildUI()
        loadDefaults()
    }

    func windowWillClose(_ notification: Notification) {
        job?.cancel()
        previewWork?.cancel()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        reloadTemplatePopup()
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.bg0.cgColor

        let sourceLabel = heading("Source")
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(reloadSources))
        let addFolder = NSButton(title: "Add Folder…", target: self, action: #selector(addFolder(_:)))
        configure(sourceTable)
        sourceTable.tag = 1
        let sourceScroll = scroll(sourceTable)
        sourceScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true

        let destHeading = heading("Destination")
        destLabel.font = Theme.monoData
        destLabel.textColor = Theme.tx0
        destLabel.lineBreakMode = .byTruncatingMiddle
        let chooseDest = NSButton(title: "Choose…", target: self, action: #selector(chooseDestination(_:)))
        jobField.placeholderString = "Job name"
        jobField.font = Theme.monoData
        jobField.delegate = self
        jobField.stringValue = UserDefaults.standard.string(forKey: "QuickCullLastJob") ?? ""

        templatePopup.target = self
        templatePopup.action = #selector(templatePicked(_:))
        pathField.font = Theme.monoData
        pathField.delegate = self
        pathField.placeholderString = "{Job}/{YYYY}/{MM}/{DD}"
        pathExample.font = Theme.monoCaption
        pathExample.textColor = Theme.tx2
        subfolderLabel.font = Theme.monoCaption
        subfolderLabel.textColor = Theme.tx2
        subfolderLabel.maximumNumberOfLines = 2
        preserveCheck.target = self
        preserveCheck.action = #selector(optionChanged(_:))

        let nameHeading = heading("File naming")
        renameCheck.target = self
        renameCheck.action = #selector(renameToggled(_:))
        nameField.font = Theme.monoData
        nameField.delegate = self
        nameField.placeholderString = "{name}"
        nameNote.font = Theme.monoCaption
        nameNote.textColor = Theme.tx2
        nameNote.maximumNumberOfLines = 2

        backupCheck.target = self
        backupCheck.action = #selector(backupToggled(_:))
        backupLabel.font = Theme.monoCaption
        backupLabel.textColor = Theme.tx1
        backupLabel.lineBreakMode = .byTruncatingMiddle
        let chooseBackup = NSButton(title: "Backup…", target: self, action: #selector(chooseBackup(_:)))
        skipCheck.target = self
        skipCheck.action = #selector(optionChanged(_:))
        ejectCheck.target = self
        ejectCheck.action = #selector(optionChanged(_:))
        metadataCheck.target = self
        metadataCheck.action = #selector(optionChanged(_:))

        let previewHeading = heading("Preview")
        configure(previewTable)
        previewTable.tag = 2
        addColumn(previewTable, id: "original", title: "Original", width: 180)
        addColumn(previewTable, id: "new", title: "New name", width: 180)
        addColumn(previewTable, id: "dest", title: "Destination", width: 280)
        addColumn(previewTable, id: "note", title: "Note", width: 140)
        let previewScroll = scroll(previewTable)
        previewScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        summaryLabel.font = Theme.monoData
        summaryLabel.textColor = Theme.tx0
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        statusLabel.font = Theme.monoCaption
        statusLabel.textColor = Theme.tx1
        errorView.isEditable = false
        errorView.font = Theme.monoCaption
        errorView.textColor = Theme.tx1
        errorView.drawsBackground = false
        errorView.string = ""
        let errorScroll = NSScrollView()
        errorScroll.hasVerticalScroller = true
        errorScroll.drawsBackground = false
        errorScroll.documentView = errorView
        errorScroll.translatesAutoresizingMaskIntoConstraints = false
        errorScroll.heightAnchor.constraint(equalToConstant: 56).isActive = true

        startButton.target = self
        startButton.action = #selector(startTapped(_:))
        startButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.isEnabled = false
        ejectButton.target = self
        ejectButton.action = #selector(ejectTapped(_:))

        let sourceButtons = NSStackView(views: [sourceLabel, NSView(), refresh, addFolder])
        sourceButtons.orientation = .horizontal
        let destButtons = NSStackView(views: [destLabel, chooseDest])
        destButtons.orientation = .horizontal
        let pathTokens = tokenRow(["{Job}", "{YYYY}", "{MM}", "{DD}", "{YYYYMMDD}", "{Camera}", "{Card}"], action: #selector(insertPathToken(_:)))
        let nameTokens = tokenRow(["{name}", "{seq}", "{iseq}", "{date}", "{job}"], action: #selector(insertNameToken(_:)))
        let options = NSStackView(views: [skipCheck, ejectCheck, metadataCheck])
        options.orientation = .horizontal
        options.spacing = 16
        let backupRow = NSStackView(views: [backupCheck, backupLabel, chooseBackup])
        backupRow.orientation = .horizontal
        let buttons = NSStackView(views: [ejectButton, NSView(), cancelButton, startButton])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [
            sourceButtons, sourceScroll,
            destHeading, jobField, destButtons,
            heading("Folder structure"), templatePopup, pathField, pathTokens, pathExample, subfolderLabel, preserveCheck,
            nameHeading, renameCheck, nameField, nameTokens, nameNote,
            heading("Options"), backupRow, options,
            previewHeading, previewScroll, summaryLabel, progressBar, statusLabel, errorScroll, buttons
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sourceScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            jobField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            pathField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            previewScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            progressBar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            errorScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            destButtons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            backupRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36)
        ])
        for column in previewTable.tableColumns {
            column.width = column.minWidth
        }
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: Theme.monoEyebrow, .foregroundColor: Theme.tx2, .kern: 1.2
        ])
        return label
    }

    private func configure(_ table: NSTableView) {
        table.headerView = table === previewTable ? NSTableHeaderView() : nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 20
        table.backgroundColor = Theme.bg1
        table.usesAlternatingRowBackgroundColors = false
        if table === sourceTable {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
            column.title = "Source"
            table.addTableColumn(column)
        }
    }

    private func addColumn(_ table: NSTableView, id: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.minWidth = width
        column.width = width
        table.addTableColumn(column)
    }

    private func scroll(_ table: NSTableView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    private func tokenRow(_ tokens: [String], action: Selector) -> NSStackView {
        let buttons = tokens.map { token -> NSButton in
            let button = NSButton(title: token, target: self, action: action)
            button.isBordered = false
            button.wantsLayer = true
            button.font = Theme.monoCaption
            button.attributedTitle = NSAttributedString(string: token, attributes: [
                .font: Theme.monoCaption,
                .foregroundColor: Theme.tx1
            ])
            button.layer?.backgroundColor = Theme.bg3.cgColor
            button.layer?.borderColor = Theme.line.cgColor
            button.layer?.borderWidth = 1
            button.layer?.cornerRadius = Theme.controlRadius
            button.setButtonType(.momentaryPushIn)
            button.translatesAutoresizingMaskIntoConstraints = false
            let titleWidth = (token as NSString).size(withAttributes: [.font: Theme.monoCaption]).width
            button.widthAnchor.constraint(equalToConstant: ceil(titleWidth) + 14).isActive = true
            button.heightAnchor.constraint(equalToConstant: 20).isActive = true
            return button
        }
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    private func loadDefaults() {
        let defaults = UserDefaults.standard
        // A pattern saved from the old drawer must not rename by itself.
        let renameOn = defaults.object(forKey: "QuickCullIngestRenameEnabled") as? Bool ?? false
        renameCheck.state = renameOn ? .on : .off
        nameField.stringValue = defaults.string(forKey: "QuickCullCopyAsPattern") ?? "{name}"
        nameField.isEnabled = renameOn
        pathField.stringValue = defaults.string(forKey: "QuickCullIngestPathPattern") ?? "{Job}/{YYYY}/{MM}/{DD}"
        preserveCheck.state = defaults.bool(forKey: "QuickCullPreserveFolders") ? .on : .off
        skipCheck.state = (defaults.object(forKey: "QuickCullSkipExisting") == nil
                           || defaults.bool(forKey: "QuickCullSkipExisting")) ? .on : .off
        ejectCheck.state = defaults.bool(forKey: "QuickCullEjectWhenDone") ? .on : .off
        metadataCheck.state = defaults.bool(forKey: "QuickCullIngestWriteMetadata") ? .on : .off
        backupCheck.state = defaults.bool(forKey: "QuickCullIngestBackupEnabled") ? .on : .off
        if let destination {
            destLabel.stringValue = destination.path
        }
        if let backupDestination {
            backupLabel.stringValue = backupDestination.path
        }
        reloadTemplatePopup()
        refreshNamingNote()
        refreshPathExample()
    }

    // MARK: - Templates and path

    private func reloadTemplatePopup() {
        let current = templatePopup.titleOfSelectedItem
        templatePopup.removeAllItems()
        templatePopup.addItem(withTitle: "Custom")
        templatePopup.addItems(withTitles: FolderTemplates.unified().map(\.name))
        if let current, templatePopup.itemTitles.contains(current) {
            templatePopup.selectItem(withTitle: current)
        }
        refreshSubfolders()
    }

    @objc private func templatePicked(_ sender: Any?) {
        guard let name = templatePopup.titleOfSelectedItem, name != "Custom",
              let template = FolderTemplates.unified().first(where: { $0.name == name }) else {
            refreshSubfolders()
            refreshPathExample()
            schedulePreview()
            return
        }
        pathField.stringValue = template.pathPattern
        UserDefaults.standard.set(pathField.stringValue, forKey: "QuickCullIngestPathPattern")
        refreshSubfolders()
        refreshPathExample()
        schedulePreview()
    }

    private func selectedSubfolders() -> [String] {
        guard let name = templatePopup.titleOfSelectedItem, name != "Custom" else { return [] }
        return FolderTemplates.unified().first { $0.name == name }?.subfolders ?? []
    }

    private func refreshSubfolders() {
        let folders = selectedSubfolders()
        subfolderLabel.stringValue = folders.isEmpty
            ? "No extra folders."
            : "Also creates: " + folders.joined(separator: ", ")
    }

    private func refreshPathExample() {
        let path = IngestTemplates.render(
            pattern: pathField.stringValue,
            job: jobNameOrSample(),
            camera: "EOS R5",
            card: sources.first?.url.lastPathComponent ?? "Card"
        )
        pathExample.stringValue = "Example: " + (destination?.path ?? "Pictures") + "/" + path
    }

    private func renderedRoot() -> URL? {
        guard let destination else { return nil }
        let relative = IngestTemplates.render(
            pattern: pathField.stringValue,
            job: jobField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            camera: "",
            card: sources.first(where: \.checked)?.url.lastPathComponent ?? ""
        )
        return destination.appendingPathComponent(relative, isDirectory: true)
    }

    private func jobNameOrSample() -> String {
        let job = jobField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return job.isEmpty ? "Chen Wedding" : job
    }

    // MARK: - Naming note

    private func refreshNamingNote() {
        if renameCheck.state == .on {
            nameNote.stringValue = "On. The table shows every file’s new name before anything is copied."
        } else if !(UserDefaults.standard.string(forKey: "QuickCullCopyAsPattern") ?? "").isEmpty {
            nameNote.stringValue = "Off. Files keep the names on the card. A pattern is saved below and does nothing until Rename files is on."
        } else {
            nameNote.stringValue = "Off. Files keep the names on the card."
        }
    }

    @objc private func renameToggled(_ sender: Any?) {
        let on = renameCheck.state == .on
        UserDefaults.standard.set(on, forKey: "QuickCullIngestRenameEnabled")
        nameField.isEnabled = on
        refreshNamingNote()
        schedulePreview()
    }

    @objc private func optionChanged(_ sender: Any?) {
        let defaults = UserDefaults.standard
        defaults.set(preserveCheck.state == .on, forKey: "QuickCullPreserveFolders")
        defaults.set(skipCheck.state == .on, forKey: "QuickCullSkipExisting")
        defaults.set(ejectCheck.state == .on, forKey: "QuickCullEjectWhenDone")
        defaults.set(metadataCheck.state == .on, forKey: "QuickCullIngestWriteMetadata")
        schedulePreview()
    }

    @objc private func insertPathToken(_ sender: NSButton) {
        pathField.stringValue += sender.title
        UserDefaults.standard.set(pathField.stringValue, forKey: "QuickCullIngestPathPattern")
        templatePopup.selectItem(at: 0)
        refreshPathExample()
        schedulePreview()
    }

    @objc private func insertNameToken(_ sender: NSButton) {
        guard renameCheck.state == .on else { NSSound.beep(); return }
        nameField.stringValue += sender.title
        UserDefaults.standard.set(nameField.stringValue, forKey: "QuickCullCopyAsPattern")
        schedulePreview()
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === pathField {
            UserDefaults.standard.set(pathField.stringValue, forKey: "QuickCullIngestPathPattern")
            templatePopup.selectItem(at: 0)
            refreshPathExample()
        } else if (obj.object as? NSTextField) === nameField {
            UserDefaults.standard.set(nameField.stringValue, forKey: "QuickCullCopyAsPattern")
        } else if (obj.object as? NSTextField) === jobField {
            UserDefaults.standard.set(jobField.stringValue, forKey: "QuickCullLastJob")
            refreshPathExample()
        }
        schedulePreview()
    }

    // MARK: - Sources

    @objc private func reloadSources() {
        scanGeneration += 1
        let generation = scanGeneration
        statusLabel.stringValue = "Looking for cards…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cards = IngestJob.detectCards()
            var items: [SourceItem] = []
            var found: [String: [IngestSourceFile]] = [:]
            for card in cards {
                let name = (try? card.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? card.lastPathComponent
                items.append(SourceItem(url: card, title: name, isGroup: true, checked: true))
                let sections = IngestJob.sections(of: card)
                for section in sections {
                    let files = IngestJob.inventory(under: section)
                    found[section.path] = files
                    let bytes = files.reduce(Int64(0)) { $0 + $1.size }
                    let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                    items.append(SourceItem(
                        url: section,
                        title: "    \(section.lastPathComponent)   \(files.count) files   \(size)",
                        isGroup: false,
                        checked: true
                    ))
                }
            }
            DispatchQueue.main.async {
                guard let self, self.scanGeneration == generation else { return }
                let added = self.sources.filter { item in
                    !item.isGroup && cards.allSatisfy { !item.url.path.hasPrefix($0.path) }
                }
                self.inventory = found
                self.sources = items + added
                self.sourceTable.reloadData()
                self.statusLabel.stringValue = items.isEmpty ? "No card detected. Add a folder or insert a card." : ""
                self.schedulePreview()
            }
        }
    }

    @objc private func addFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sources.append(SourceItem(url: url, title: url.path, isGroup: false, checked: true))
        sourceTable.reloadData()
        scanGeneration += 1
        let generation = scanGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let files = IngestJob.inventory(under: url)
            DispatchQueue.main.async {
                guard let self, self.scanGeneration == generation else { return }
                self.inventory[url.path] = files
                self.schedulePreview()
            }
        }
    }

    @objc private func sourceToggled(_ sender: NSButton) {
        let row = sender.tag
        guard sources.indices.contains(row) else { return }
        sources[row].checked = sender.state == .on
        if sources[row].isGroup {
            let prefix = sources[row].url.path
            for index in sources.indices where !sources[index].isGroup && sources[index].url.path.hasPrefix(prefix) {
                sources[index].checked = sender.state == .on
            }
            sourceTable.reloadData()
        }
        schedulePreview()
    }

    @objc private func chooseDestination(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url
        destLabel.stringValue = url.path
        refreshPathExample()
        schedulePreview()
    }

    @objc private func chooseBackup(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backupDestination = url
        backupLabel.stringValue = url.path
        backupCheck.state = .on
        UserDefaults.standard.set(true, forKey: "QuickCullIngestBackupEnabled")
    }

    @objc private func backupToggled(_ sender: Any?) {
        UserDefaults.standard.set(backupCheck.state == .on, forKey: "QuickCullIngestBackupEnabled")
    }

    // MARK: - Preview

    private func schedulePreview() {
        previewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.buildPreview() }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func buildPreview() {
        previewGeneration += 1
        let generation = previewGeneration
        let selected = sources.filter { $0.checked && !$0.isGroup }.map(\.url)
        let cached = inventory
        let rename = renameCheck.state == .on
        let pattern = nameField.stringValue
        let preserve = preserveCheck.state == .on
        let skip = skipCheck.state == .on
        let job = jobField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = renderedRoot()
        let ingestNumber = max(1, UserDefaults.standard.integer(forKey: "QuickCullIngestSeq"))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var resolved: [(URL, IngestSourceFile)] = []
            var nextID = 0
            for url in selected {
                let listed = IngestJob.mediaFiles(under: url)
                for fileURL in listed {
                    let known = cached[url.path]?.first {
                        $0.originalName == fileURL.lastPathComponent
                            && $0.folderName == fileURL.deletingLastPathComponent().lastPathComponent
                    }
                    let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    var file = known ?? IngestSourceFile(
                        originalName: fileURL.lastPathComponent,
                        stem: fileURL.deletingPathExtension().lastPathComponent,
                        ext: fileURL.pathExtension,
                        size: Int64(values?.fileSize ?? 0),
                        folderName: fileURL.deletingLastPathComponent().lastPathComponent,
                        modified: values?.contentModificationDate ?? Date()
                    )
                    if known != nil {
                        file = IngestSourceFile(
                            originalName: file.originalName, stem: file.stem, ext: file.ext,
                            size: file.size, folderName: file.folderName, modified: file.modified, id: nextID
                        )
                    } else {
                        file.id = nextID
                    }
                    nextID += 1
                    resolved.append((fileURL, file))
                }
            }
            let sourceFiles = resolved.map(\.1)
            var existing: [IngestExisting] = []
            if let root {
                if preserve {
                    let folders = Set(sourceFiles.map(\.folderName))
                    for folder in folders {
                        let sub = root.appendingPathComponent(folder, isDirectory: true)
                        existing.append(contentsOf: IngestJob.existingFiles(in: sub).map {
                            IngestExisting(folder: folder, name: $0.name, size: $0.size)
                        })
                    }
                } else {
                    existing = IngestJob.existingFiles(in: root).map {
                        IngestExisting(folder: "", name: $0.name, size: $0.size)
                    }
                }
            }
            let rows = IngestPlanner.rows(
                files: sourceFiles,
                renameEnabled: rename,
                pattern: pattern,
                ingestNumber: ingestNumber,
                preserveFolders: preserve,
                skipDuplicates: skip,
                existing: existing,
                job: job
            )
            let sorted = resolved.sorted { $0.1.id < $1.1.id }
            let paired = zip(sorted, rows).map { Planned(source: $0.0.0, row: $0.1) }
            let summary = IngestPlanner.summary(rows)
            DispatchQueue.main.async {
                guard let self, self.previewGeneration == generation else { return }
                self.planned = paired
                self.previewTable.reloadData()
                let size = ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)
                self.summaryLabel.stringValue = "\(summary.copying) will copy (\(size)) · \(summary.renamed) renamed · \(summary.numbered) numbered so nothing is overwritten · \(summary.skipping) skipped. The card is not changed."
            }
        }
    }

    // MARK: - Run

    @objc private func startTapped(_ sender: Any?) {
        guard job == nil else { return }
        let jobName = jobField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jobName.isEmpty else {
            NSSound.beep()
            window?.makeFirstResponder(jobField)
            return
        }
        guard let root = renderedRoot() else {
            NSSound.beep()
            chooseDestination(nil)
            return
        }
        guard !planned.isEmpty else {
            statusLabel.stringValue = "Nothing selected to copy."
            NSSound.beep()
            return
        }
        let copying = planned.filter { $0.row.note != .skipDuplicate }
        guard !copying.isEmpty else {
            statusLabel.stringValue = "Every selected file is already at the destination."
            return
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for sub in selectedSubfolders() where IngestTemplates.isSafeRelative(sub) {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
            }
        } catch {
            statusLabel.stringValue = "Couldn't create the folder: \(error.localizedDescription)"
            return
        }
        var backupRoot: URL?
        if backupCheck.state == .on, let backupDestination {
            let relative = IngestTemplates.render(pattern: pathField.stringValue, job: jobName, card: "")
            backupRoot = backupDestination.appendingPathComponent(relative, isDirectory: true)
            try? FileManager.default.createDirectory(at: backupRoot!, withIntermediateDirectories: true)
        }
        let copies = planned.map {
            IngestJob.Copy(source: $0.source, relativePath: $0.row.relativePath, skip: $0.row.note == .skipDuplicate, sourceSize: $0.row.size)
        }
        let newJob = IngestJob()
        newJob.logFolder = root
        newJob.skipExisting = skipCheck.state == .on
        newJob.onProgress = { [weak self] progress in
            guard let self else { return }
            if progress.bytesTotal > 0 {
                self.progressBar.doubleValue = Double(progress.bytesDone) / Double(max(progress.bytesTotal, 1))
            }
            let done = ByteCountFormatter.string(fromByteCount: progress.bytesDone, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: progress.bytesTotal, countStyle: .file)
            self.statusLabel.stringValue = "\(progress.currentFile)   \(progress.filesDone)/\(progress.filesTotal) · \(done) of \(total)"
        }
        newJob.onComplete = { [weak self] copied, skipped, errors in
            guard let self else { return }
            self.job = nil
            self.startButton.isEnabled = true
            self.cancelButton.isEnabled = false
            self.progressBar.doubleValue = 1
            self.errorView.string = errors.joined(separator: "\n")
            if errors.isEmpty {
                self.statusLabel.stringValue = "Done. \(copied) copied, \(skipped) skipped. Card unchanged. Log: Ingest Log.txt"
                self.onOpenFolder?(root)
                if self.ejectCheck.state == .on { self.ejectTapped(nil) }
            } else {
                self.statusLabel.stringValue = "Finished with \(errors.count) problem\(errors.count == 1 ? "" : "s"). \(copied) copied. Do not format the card."
                self.statusLabel.textColor = Theme.red
            }
            let next = max(1, UserDefaults.standard.integer(forKey: "QuickCullIngestSeq")) + 1
            UserDefaults.standard.set(next, forKey: "QuickCullIngestSeq")
        }
        let next = max(1, UserDefaults.standard.integer(forKey: "QuickCullIngestSeq"))
        if next == 0 { UserDefaults.standard.set(1, forKey: "QuickCullIngestSeq") }
        statusLabel.textColor = Theme.tx1
        statusLabel.stringValue = "Copying \(copying.count) files. The card will not be changed."
        errorView.string = ""
        startButton.isEnabled = false
        cancelButton.isEnabled = true
        progressBar.doubleValue = 0
        job = newJob
        newJob.start(copies: copies, destination: root, backupRoot: backupRoot,
                     jobName: jobName, writeMetadata: metadataCheck.state == .on)
    }

    @objc private func cancelTapped(_ sender: Any?) {
        job?.cancel()
        statusLabel.stringValue = "Cancelling… already-copied files stay. The card is not changed."
    }

    @objc private func ejectTapped(_ sender: Any?) {
        guard job == nil else { NSSound.beep(); return }
        let volumes = selectedVolumes()
        guard !volumes.isEmpty else { return }
        statusLabel.stringValue = "Ejecting…"
        Ejector.eject(volumes: volumes) { [weak self] result in
            guard let self else { return }
            self.statusLabel.stringValue = result.succeeded ? "Card ejected." : result.failureMessage
            if result.succeeded { self.reloadSources() }
        }
    }

    private func selectedVolumes() -> [URL] {
        var seen: [URL] = []
        for item in sources where item.checked {
            let volume = (try? item.url.resourceValues(forKeys: [.volumeURLKey]))?.volume
            if let volume, !seen.contains(where: { $0.path == volume.path }) {
                seen.append(volume)
            }
        }
        return seen
    }

    // MARK: - Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === sourceTable ? sources.count : planned.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === sourceTable {
            guard sources.indices.contains(row) else { return nil }
            let item = sources[row]
            let button = NSButton(checkboxWithTitle: item.title, target: self, action: #selector(sourceToggled(_:)))
            button.state = item.checked ? .on : .off
            button.tag = row
            button.font = item.isGroup ? Theme.bodyStrong : Theme.monoCaption
            return button
        }
        guard planned.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return nil }
        let item = planned[row].row
        let text: String
        switch id {
        case "original": text = item.originalName
        case "new": text = item.newName
        case "dest": text = item.relativePath
        default:
            switch item.note {
            case .copy: text = "keep name"
            case .renamed: text = "rename"
            case .skipDuplicate: text = "skip, same size"
            case .numbered: text = "numbered, no overwrite"
            }
        }
        let label = NSTextField(labelWithString: text)
        label.font = Theme.monoCaption
        label.textColor = Theme.tx1
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }
}

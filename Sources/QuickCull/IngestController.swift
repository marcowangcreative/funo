import AppKit
import QuickCullCore

/// Photo Mechanic's stacked ingest dialog, drawn in the graphite theme.
/// Every setting is on the surface. Rename stays off until its checkbox is
/// on, even if a pattern was saved earlier.
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
    private let backupCheck = NSButton(checkboxWithTitle: "Second copy", target: nil, action: nil)
    private let backupLabel = NSTextField(labelWithString: "No backup folder")
    private let skipCheck = NSButton(checkboxWithTitle: "Ingest only new/unique", target: nil, action: nil)
    private let incrementalCheck = NSButton(checkboxWithTitle: "Incremental ingest", target: nil, action: nil)
    private let backupPattern = NSTextField()
    private let backupExample = NSTextField(labelWithString: "")
    private let renamePreview = NSTextField(labelWithString: "")
    private let ejectCheck = NSButton(checkboxWithTitle: "Eject after ingest", target: nil, action: nil)
    private let deleteCheck = NSButton(checkboxWithTitle: "Delete originals after copy", target: nil, action: nil)
    private let copyOnlyCheck = NSButton(checkboxWithTitle: "Copy only (no conversion)", target: nil, action: nil)
    private let openCheck = NSButton(checkboxWithTitle: "Open in contact sheet when done", target: nil, action: nil)
    private let rawCheck = NSButton(checkboxWithTitle: "RAW", target: nil, action: nil)
    private let jpegCheck = NSButton(checkboxWithTitle: "JPEG", target: nil, action: nil)
    private let otherCheck = NSButton(checkboxWithTitle: "Other", target: nil, action: nil)
    private let metadataCheck = NSButton(checkboxWithTitle: "Apply IPTC/metadata template", target: nil, action: nil)
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
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ingest Photos"
        window.backgroundColor = Theme.bg0
        window.minSize = NSSize(width: 720, height: 560)
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

        let refresh = NSButton(title: "Refresh", target: self, action: #selector(reloadSources))
        let addFolder = NSButton(title: "Add Folder…", target: self, action: #selector(addFolder(_:)))
        configure(sourceTable)
        sourceTable.tag = 1
        let sourceScroll = scroll(sourceTable)
        sourceScroll.heightAnchor.constraint(equalToConstant: 132).isActive = true

        stylePath(destLabel)
        destLabel.lineBreakMode = .byTruncatingMiddle
        let chooseDest = NSButton(title: "Choose…", target: self, action: #selector(chooseDestination(_:)))
        jobField.placeholderString = "Job name"
        styleField(jobField)
        jobField.delegate = self
        jobField.stringValue = UserDefaults.standard.string(forKey: "QuickCullLastJob") ?? ""

        templatePopup.target = self
        templatePopup.action = #selector(templatePicked(_:))
        styleField(pathField)
        pathField.delegate = self
        pathField.placeholderString = "{Job}/{YYYY}/{MM}/{DD}"
        pathExample.font = Theme.monoCaption
        pathExample.textColor = Theme.tx2
        pathExample.lineBreakMode = .byTruncatingMiddle
        subfolderLabel.font = Theme.monoCaption
        subfolderLabel.textColor = Theme.tx2
        subfolderLabel.maximumNumberOfLines = 2
        preserveCheck.target = self
        preserveCheck.action = #selector(optionChanged(_:))

        renameCheck.title = "Rename photos as they are ingested"
        renameCheck.target = self
        renameCheck.action = #selector(renameToggled(_:))
        styleField(nameField)
        nameField.delegate = self
        nameField.placeholderString = "{name}"
        renamePreview.font = Theme.monoData
        renamePreview.textColor = Theme.tx0
        renamePreview.lineBreakMode = .byTruncatingMiddle

        backupCheck.title = "Secondary destination (backup copy)"
        backupCheck.target = self
        backupCheck.action = #selector(backupToggled(_:))
        stylePath(backupLabel)
        backupLabel.lineBreakMode = .byTruncatingMiddle
        let chooseBackup = NSButton(title: "Choose…", target: self, action: #selector(chooseBackup(_:)))
        styleField(backupPattern)
        backupPattern.delegate = self
        backupPattern.placeholderString = "{Job}/{YYYY}/{MM}/{DD}"
        backupExample.font = Theme.monoCaption
        backupExample.textColor = Theme.tx2
        backupExample.lineBreakMode = .byTruncatingMiddle

        for box in [skipCheck, incrementalCheck, ejectCheck, deleteCheck, openCheck, rawCheck, jpegCheck, otherCheck, metadataCheck] {
            box.target = self
            box.action = #selector(optionChanged(_:))
        }
        copyOnlyCheck.state = .on
        copyOnlyCheck.isEnabled = false
        copyOnlyCheck.toolTip = "Ingest copies the files. It does not convert them."

        summaryLabel.font = Theme.monoData
        summaryLabel.textColor = Theme.tx0
        summaryLabel.lineBreakMode = .byTruncatingMiddle
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        statusLabel.font = Theme.monoCaption
        statusLabel.textColor = Theme.tx1
        statusLabel.lineBreakMode = .byTruncatingMiddle
        errorView.isEditable = false
        errorView.font = Theme.monoCaption
        errorView.textColor = Theme.tx1
        errorView.drawsBackground = false
        errorView.string = ""
        let errorScroll = GraphiteScrollView()
        errorScroll.hasVerticalScroller = true
        errorScroll.drawsBackground = false
        errorScroll.documentView = errorView
        errorScroll.translatesAutoresizingMaskIntoConstraints = false
        errorScroll.heightAnchor.constraint(equalToConstant: 36).isActive = true

        startButton.title = "Ingest"
        startButton.target = self
        startButton.action = #selector(startTapped(_:))
        startButton.isBordered = false
        startButton.wantsLayer = true
        startButton.layer?.backgroundColor = Theme.accent.cgColor
        startButton.layer?.cornerRadius = Theme.controlRadius
        startButton.attributedTitle = NSAttributedString(string: "Ingest", attributes: [
            .font: Theme.bodyStrong, .foregroundColor: Theme.accentText
        ])
        startButton.translatesAutoresizingMaskIntoConstraints = false
        startButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 108).isActive = true
        startButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        startButton.focusRingType = .none
        startButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped(_:))
        cancelButton.keyEquivalent = "\u{1b}"

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let sourceOptions = NSStackView(views: [skipCheck, incrementalCheck, spacer, refresh, addFolder])
        sourceOptions.orientation = .horizontal
        sourceOptions.spacing = 16
        let sourceBody = NSStackView(views: [sourceScroll, sourceOptions, preserveCheck])
        sourceBody.orientation = .vertical
        sourceBody.alignment = .leading
        sourceBody.spacing = 8

        let pathTokens = tokenRow(["{Job}", "{YYYY}", "{MM}", "{DD}", "{YYYYMMDD}", "{Camera}", "{Card}"], action: #selector(insertPathToken(_:)))
        let primaryBody = NSStackView(views: [
            fieldRow("Job", jobField),
            fieldRow("Folder", destLabel, chooseDest),
            fieldRow("Saved", templatePopup),
            fieldRow("Template", pathField),
            pathTokens,
            pathExample,
            subfolderLabel
        ])
        primaryBody.orientation = .vertical
        primaryBody.alignment = .leading
        primaryBody.spacing = 8

        let backupTokens = tokenRow(["{Job}", "{YYYY}", "{MM}", "{DD}", "{Camera}", "{Card}"], action: #selector(insertBackupToken(_:)))
        let secondaryBody = NSStackView(views: [
            backupCheck,
            fieldRow("Folder", backupLabel, chooseBackup),
            fieldRow("Template", backupPattern),
            backupTokens,
            backupExample
        ])
        secondaryBody.orientation = .vertical
        secondaryBody.alignment = .leading
        secondaryBody.spacing = 8

        let nameTokens = tokenRow(["{name}", "{seq}", "{iseq}", "{date}", "{job}"], action: #selector(insertNameToken(_:)))
        let renameBody = NSStackView(views: [renameCheck, fieldRow("Template", nameField), nameTokens, renamePreview])
        renameBody.orientation = .vertical
        renameBody.alignment = .leading
        renameBody.spacing = 8

        let types = NSStackView(views: [rawCheck, jpegCheck, otherCheck])
        types.orientation = .horizontal
        types.spacing = 16
        let optionsBody = NSStackView(views: [
            ejectCheck, deleteCheck, copyOnlyCheck, openCheck,
            caption("Ingest only selected file types"), types
        ])
        optionsBody.orientation = .vertical
        optionsBody.alignment = .leading
        optionsBody.spacing = 6

        let form = NSStackView(views: [
            section("Source", sourceBody),
            section("Primary destination", primaryBody),
            section("Secondary destination", secondaryBody),
            section("Rename", renameBody),
            section("Metadata", metadataCheck),
            section("Options", optionsBody)
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 18
        form.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 18, right: 22)
        form.translatesAutoresizingMaskIntoConstraints = false

        let scroller = GraphiteScrollView()
        scroller.drawsBackground = false
        scroller.hasVerticalScroller = true
        scroller.documentView = form
        scroller.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroller)

        let barRule = NSView()
        barRule.wantsLayer = true
        barRule.layer?.backgroundColor = Theme.line.cgColor
        barRule.translatesAutoresizingMaskIntoConstraints = false
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = Theme.bg1.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)
        bar.addSubview(barRule)
        let buttons = NSStackView(views: [cancelButton, startButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let barText = NSStackView(views: [summaryLabel, statusLabel, progressBar])
        barText.orientation = .vertical
        barText.alignment = .leading
        barText.spacing = 2
        let barSpacer = NSView()
        barSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        buttons.setContentHuggingPriority(.required, for: .horizontal)
        barText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let barRow = NSStackView(views: [barText, barSpacer, buttons])
        barRow.orientation = .horizontal
        barRow.alignment = .centerY
        barRow.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(barRow)
        bar.addSubview(errorScroll)

        NSLayoutConstraint.activate([
            scroller.topAnchor.constraint(equalTo: content.topAnchor),
            scroller.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroller.bottomAnchor.constraint(equalTo: bar.topAnchor),

            form.topAnchor.constraint(equalTo: scroller.contentView.topAnchor),
            form.leadingAnchor.constraint(equalTo: scroller.contentView.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: scroller.contentView.trailingAnchor),
            form.widthAnchor.constraint(equalTo: scroller.contentView.widthAnchor),

            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            barRule.topAnchor.constraint(equalTo: bar.topAnchor),
            barRule.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            barRule.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            barRule.heightAnchor.constraint(equalToConstant: 1),

            barRow.topAnchor.constraint(equalTo: barRule.bottomAnchor, constant: 10),
            barRow.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 18),
            barRow.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -18),
            errorScroll.topAnchor.constraint(equalTo: barRow.bottomAnchor, constant: 4),
            errorScroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 18),
            errorScroll.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -18),
            errorScroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -10),
            progressBar.widthAnchor.constraint(equalToConstant: 220)
        ])
        for sectionView in form.arrangedSubviews {
            sectionView.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -44).isActive = true
        }
        for body in [sourceBody, primaryBody, secondaryBody, renameBody, optionsBody] {
            fill(body)
        }
        configure(previewTable)
    }

    private func fill(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func section(_ title: String, _ body: NSView) -> NSView {
        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Theme.line.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let stack = NSStackView(views: [heading(title), rule, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        rule.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func fieldRow(_ title: String, _ field: NSView, _ extra: NSView? = nil) -> NSView {
        let label = caption(title)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 88).isActive = true
        var views = [label, field]
        if let extra { views.append(extra) }
        label.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        extra?.setContentHuggingPriority(.required, for: .horizontal)
        extra?.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Theme.caption
        label.textColor = Theme.tx1
        return label
    }

    private func styleField(_ field: NSTextField) {
        field.font = Theme.monoData
        field.textColor = Theme.tx0
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
    }

    private func stylePath(_ field: NSTextField) {
        field.font = Theme.monoData
        field.textColor = Theme.tx0
        field.drawsBackground = true
        field.backgroundColor = Theme.bg2
        field.isBezeled = false
        field.wantsLayer = true
        field.layer?.backgroundColor = Theme.bg2.cgColor
        field.layer?.cornerRadius = Theme.controlRadius
        field.layer?.borderWidth = 1
        field.layer?.borderColor = Theme.line.cgColor
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
        let scroll = GraphiteScrollView()
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
        incrementalCheck.state = defaults.bool(forKey: "QuickCullIngestIncremental") ? .on : .off
        ejectCheck.state = defaults.bool(forKey: "QuickCullEjectWhenDone") ? .on : .off
        deleteCheck.state = defaults.bool(forKey: "QuickCullIngestDeleteOriginals") ? .on : .off
        let openWhenDone = (defaults.object(forKey: "QuickCullIngestOpenWhenDone") as? Bool) ?? true
        let allowRaw = (defaults.object(forKey: "QuickCullIngestAllowRAW") as? Bool) ?? true
        let allowJPEG = (defaults.object(forKey: "QuickCullIngestAllowJPEG") as? Bool) ?? true
        let allowOther = (defaults.object(forKey: "QuickCullIngestAllowOther") as? Bool) ?? true
        openCheck.state = openWhenDone ? .on : .off
        rawCheck.state = allowRaw ? .on : .off
        jpegCheck.state = allowJPEG ? .on : .off
        otherCheck.state = allowOther ? .on : .off
        metadataCheck.state = defaults.bool(forKey: "QuickCullIngestWriteMetadata") ? .on : .off
        backupCheck.state = defaults.bool(forKey: "QuickCullIngestBackupEnabled") ? .on : .off
        backupPattern.stringValue = defaults.string(forKey: "QuickCullIngestBackupPattern")
            ?? defaults.string(forKey: "QuickCullIngestPathPattern")
            ?? "{Job}/{YYYY}/{MM}/{DD}"
        setBackupEnabled(backupCheck.state == .on)
        if let destination {
            destLabel.stringValue = destination.path
        }
        if let backupDestination {
            backupLabel.stringValue = backupDestination.path
        }
        reloadTemplatePopup()
        refreshRenamePreview()
        refreshPathExample()
        refreshBackupExample()
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
        let root = destination?.path ?? "Pictures"
        pathExample.stringValue = root + "/" + path
    }

    private func refreshBackupExample() {
        let path = IngestTemplates.render(
            pattern: backupPattern.stringValue,
            job: jobNameOrSample(),
            camera: "EOS R5",
            card: sources.first?.url.lastPathComponent ?? "Card"
        )
        let root = backupDestination?.path ?? "Backup"
        backupExample.stringValue = root + "/" + path
    }

    private func renderedBackupRoot(job: String) -> URL? {
        guard backupCheck.state == .on, let backupDestination else { return nil }
        let relative = IngestTemplates.render(
            pattern: backupPattern.stringValue,
            job: job,
            card: sources.first(where: \.checked)?.url.lastPathComponent ?? ""
        )
        return backupDestination.appendingPathComponent(relative, isDirectory: true)
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

    private func refreshRenamePreview() {
        let original = planned.first?.row.originalName ?? "IMG_1234.CR3"
        renamePreview.stringValue = IngestRenamePreview.line(
            original: original,
            enabled: renameCheck.state == .on,
            pattern: nameField.stringValue,
            job: jobField.stringValue
        )
    }

    @objc private func renameToggled(_ sender: Any?) {
        let on = renameCheck.state == .on
        UserDefaults.standard.set(on, forKey: "QuickCullIngestRenameEnabled")
        nameField.isEnabled = on
        refreshRenamePreview()
        schedulePreview()
    }

    @objc private func optionChanged(_ sender: Any?) {
        let defaults = UserDefaults.standard
        defaults.set(preserveCheck.state == .on, forKey: "QuickCullPreserveFolders")
        defaults.set(skipCheck.state == .on, forKey: "QuickCullSkipExisting")
        defaults.set(incrementalCheck.state == .on, forKey: "QuickCullIngestIncremental")
        defaults.set(ejectCheck.state == .on, forKey: "QuickCullEjectWhenDone")
        defaults.set(deleteCheck.state == .on, forKey: "QuickCullIngestDeleteOriginals")
        defaults.set(openCheck.state == .on, forKey: "QuickCullIngestOpenWhenDone")
        defaults.set(rawCheck.state == .on, forKey: "QuickCullIngestAllowRAW")
        defaults.set(jpegCheck.state == .on, forKey: "QuickCullIngestAllowJPEG")
        defaults.set(otherCheck.state == .on, forKey: "QuickCullIngestAllowOther")
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
        refreshRenamePreview()
        schedulePreview()
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === pathField {
            UserDefaults.standard.set(pathField.stringValue, forKey: "QuickCullIngestPathPattern")
            templatePopup.selectItem(at: 0)
            refreshPathExample()
        } else if (obj.object as? NSTextField) === nameField {
            UserDefaults.standard.set(nameField.stringValue, forKey: "QuickCullCopyAsPattern")
            refreshRenamePreview()
        } else if (obj.object as? NSTextField) === jobField {
            UserDefaults.standard.set(jobField.stringValue, forKey: "QuickCullLastJob")
            refreshPathExample()
            refreshBackupExample()
            refreshRenamePreview()
        } else if (obj.object as? NSTextField) === backupPattern {
            UserDefaults.standard.set(backupPattern.stringValue, forKey: "QuickCullIngestBackupPattern")
            refreshBackupExample()
        }
        schedulePreview()
    }

    // MARK: - Sources

    @objc private func reloadSources() {
        scanGeneration += 1
        let generation = scanGeneration
        statusLabel.stringValue = "Looking for cards…"
        let checkedPaths = Set(sources.filter(\.checked).map(\.url.path))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cards = IngestJob.detectCards()
            var items: [SourceItem] = []
            var found: [String: [IngestSourceFile]] = [:]
            let volumeKeys: Set<URLResourceKey> = [
                .volumeNameKey, .volumeIsLocalKey, .volumeIsInternalKey,
                .volumeIsRemovableKey, .volumeIsEjectableKey
            ]
            let volumes = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: Array(volumeKeys),
                options: [.skipHiddenVolumes]
            ) ?? []
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
            for volume in volumes where !cards.contains(where: { $0.path == volume.path }) {
                let values = try? volume.resourceValues(forKeys: volumeKeys)
                let local = values?.volumeIsLocal ?? false
                let removable = (values?.volumeIsRemovable ?? false) || (values?.volumeIsEjectable ?? false)
                let external = values?.volumeIsInternal == false
                guard local, removable || external else { continue }
                let name = values?.volumeName ?? volume.lastPathComponent
                items.append(SourceItem(url: volume, title: name, isGroup: false, checked: checkedPaths.contains(volume.path)))
            }
            DispatchQueue.main.async {
                guard let self, self.scanGeneration == generation else { return }
                let added = self.sources.filter { item in
                    !item.isGroup
                        && !items.contains(where: { $0.url.path == item.url.path })
                        && cards.allSatisfy { !item.url.path.hasPrefix($0.path) }
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
        setBackupEnabled(true)
        refreshBackupExample()
    }

    @objc private func backupToggled(_ sender: Any?) {
        let on = backupCheck.state == .on
        UserDefaults.standard.set(on, forKey: "QuickCullIngestBackupEnabled")
        setBackupEnabled(on)
    }

    private func setBackupEnabled(_ on: Bool) {
        backupPattern.isEnabled = true
        backupLabel.textColor = on ? Theme.tx0 : Theme.tx2
        backupExample.textColor = on ? Theme.tx2 : Theme.tx2.withAlphaComponent(0.45)
    }

    @objc private func insertBackupToken(_ sender: NSButton) {
        backupPattern.stringValue += sender.title
        UserDefaults.standard.set(backupPattern.stringValue, forKey: "QuickCullIngestBackupPattern")
        refreshBackupExample()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            startTapped(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelTapped(nil)
            return true
        }
        return false
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
        let incremental = incrementalCheck.state == .on
        let allowRaw = rawCheck.state == .on
        let allowJPEG = jpegCheck.state == .on
        let allowOther = otherCheck.state == .on
        let job = jobField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = renderedRoot()
        let ingestNumber = max(1, UserDefaults.standard.integer(forKey: "QuickCullIngestSeq"))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var resolved: [(URL, IngestSourceFile)] = []
            var nextID = 0
            for url in selected {
                let listed = IngestJob.mediaFiles(under: url)
                for fileURL in listed {
                    guard IngestFileKinds.allows(extension: fileURL.pathExtension,
                                                 raw: allowRaw, jpeg: allowJPEG, other: allowOther) else { continue }
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
                job: job,
                incremental: incremental
            )
            let sorted = resolved.sorted { $0.1.id < $1.1.id }
            let paired = zip(sorted, rows).map { Planned(source: $0.0.0, row: $0.1) }
            let summary = IngestPlanner.summary(rows)
            DispatchQueue.main.async {
                guard let self, self.previewGeneration == generation else { return }
                self.planned = paired
                if let first = paired.first(where: { $0.row.note != .skipDuplicate }) ?? paired.first {
                    self.renamePreview.stringValue = "\(first.row.originalName) → \(first.row.newName)"
                } else {
                    self.refreshRenamePreview()
                }
                let size = ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)
                let free = self.freeSpaceText()
                var line = "\(summary.copying) files · \(size)"
                if summary.skipping > 0 { line += " · \(summary.skipping) skipped" }
                if let free { line += " · \(free) free" }
                self.summaryLabel.stringValue = line
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
        let backupRoot = renderedBackupRoot(job: jobName)
        if let backupRoot {
            try? FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        }
        let copies = planned.map {
            IngestJob.Copy(source: $0.source, relativePath: $0.row.relativePath, skip: $0.row.note == .skipDuplicate, sourceSize: $0.row.size)
        }
        let newJob = IngestJob()
        newJob.logFolder = root
        newJob.skipExisting = skipCheck.state == .on
        newJob.removeVerifiedSource = deleteCheck.state == .on
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
            self.progressBar.doubleValue = 1
            self.errorView.string = errors.joined(separator: "\n")
            if errors.isEmpty {
                let originals = self.deleteCheck.state == .on ? "Originals removed after verify." : "Originals kept."
                self.statusLabel.stringValue = "Done. \(copied) copied, \(skipped) skipped. \(originals)"
                if self.openCheck.state == .on { self.onOpenFolder?(root) }
                if self.ejectCheck.state == .on { self.ejectTapped(nil) }
            } else {
                self.statusLabel.stringValue = "Finished with \(errors.count) problem\(errors.count == 1 ? "" : "s"). \(copied) copied. Check Ingest Log.txt before formatting the card."
                self.statusLabel.textColor = Theme.red
            }
            let next = max(1, UserDefaults.standard.integer(forKey: "QuickCullIngestSeq")) + 1
            UserDefaults.standard.set(next, forKey: "QuickCullIngestSeq")
        }
        let next = max(1, UserDefaults.standard.integer(forKey: "QuickCullIngestSeq"))
        if next == 0 { UserDefaults.standard.set(1, forKey: "QuickCullIngestSeq") }
        statusLabel.textColor = Theme.tx1
        let originals = deleteCheck.state == .on ? "Checked files will be deleted after they verify." : "Originals stay on the card."
        statusLabel.stringValue = "Copying \(copying.count) files. \(originals)"
        errorView.string = ""
        startButton.isEnabled = false
        progressBar.doubleValue = 0
        job = newJob
        newJob.start(copies: copies, destination: root, backupRoot: backupRoot,
                     jobName: jobName, writeMetadata: metadataCheck.state == .on)
    }

    @objc private func cancelTapped(_ sender: Any?) {
        if job != nil {
            job?.cancel()
            statusLabel.stringValue = deleteCheck.state == .on
                ? "Cancelling… a file is removed only if its copy already verified."
                : "Cancelling… originals stay on the card."
        } else {
            window?.close()
        }
    }

    private func freeSpaceText() -> String? {
        guard var url = destination else { return nil }
        let fm = FileManager.default
        while !fm.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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

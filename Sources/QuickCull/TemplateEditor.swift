import AppKit

/// A small editor window for folder templates: pick a template, edit its
/// name and folder list (one per line, "/" nests), save or delete.
final class TemplateEditor: NSWindowController, NSWindowDelegate {

    private static var current: TemplateEditor?

    static func show() {
        let editor = current ?? TemplateEditor()
        current = editor
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private let popup = NSPopUpButton()
    private let nameField = NSTextField()
    private let textView = NSTextView()
    private var editingName: String? // nil = creating a new template

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Folder Templates"
        window.minSize = NSSize(width: 380, height: 360)
        window.center()
        self.init(window: window)
        window.delegate = self
        buildUI()
        reload(selecting: FolderTemplates.names.first)
    }

    func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        popup.target = self
        popup.action = #selector(popupChanged(_:))
        popup.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(popup)

        let newButton = NSButton(title: "New", target: self, action: #selector(newTapped(_:)))
        newButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(newButton)

        let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteTapped(_:)))
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(deleteButton)

        let nameLabel = NSTextField(labelWithString: "Name")
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(nameLabel)

        nameField.placeholderString = "Template name"
        nameField.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(nameField)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.isRichText = false
        textView.font = Theme.monoData
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 6, height: 8)
        scroll.documentView = textView
        content.addSubview(scroll)

        let hint = NSTextField(labelWithString: "One folder per line · use / to nest (e.g. Reception/Speeches)")
        hint.font = Theme.caption
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hint)

        let saveButton = NSButton(title: "Save Template", target: self, action: #selector(saveTapped(_:)))
        saveButton.keyEquivalent = "\r"
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(saveButton)

        NSLayoutConstraint.activate([
            popup.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            popup.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            deleteButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 15),
            deleteButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            newButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 15),
            newButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
            popup.trailingAnchor.constraint(lessThanOrEqualTo: newButton.leadingAnchor, constant: -12),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),

            nameLabel.topAnchor.constraint(equalTo: popup.bottomAnchor, constant: 18),
            nameLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            nameField.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 10),
            nameField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -10),

            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            saveButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            saveButton.centerYAnchor.constraint(equalTo: hint.centerYAnchor)
        ])
    }

    // MARK: - Data

    private func reload(selecting name: String?) {
        popup.removeAllItems()
        popup.addItems(withTitles: FolderTemplates.names)
        if let name, FolderTemplates.names.contains(name) {
            popup.selectItem(withTitle: name)
            load(name)
        } else if let first = FolderTemplates.names.first {
            popup.selectItem(withTitle: first)
            load(first)
        } else {
            startNew()
        }
    }

    private func load(_ name: String) {
        editingName = name
        nameField.stringValue = name
        textView.string = (FolderTemplates.all[name] ?? []).joined(separator: "\n")
    }

    private func startNew() {
        editingName = nil
        nameField.stringValue = ""
        textView.string = ""
        popup.select(nil)
        window?.makeFirstResponder(nameField)
    }

    // MARK: - Actions

    @objc private func popupChanged(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem else { return }
        load(title)
    }

    @objc private func newTapped(_ sender: Any?) {
        startNew()
    }

    @objc private func deleteTapped(_ sender: Any?) {
        guard let name = editingName else { startNew(); return }
        FolderTemplates.delete(name)
        reload(selecting: nil)
    }

    @objc private func saveTapped(_ sender: Any?) {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { NSSound.beep(); return }
        let paths = textView.string
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !paths.isEmpty else { NSSound.beep(); return }
        if let old = editingName, old != name {
            FolderTemplates.delete(old) // renamed
        }
        FolderTemplates.save(name: name, paths: paths)
        reload(selecting: name)
    }
}

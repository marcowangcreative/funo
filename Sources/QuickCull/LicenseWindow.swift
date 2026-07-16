import AppKit

/// Activation window — status, a field for the key, Activate, and a link to
/// buy. In trial it's dismissible; once expired, closing it quits the app
/// (the gate). Same graphite/brass language as everything else.
final class LicenseWindowController: NSWindowController, NSWindowDelegate {

    static let shared = LicenseWindowController()

    private let statusLabel = NSTextField(labelWithString: "")
    private let keyField = NSTextField()
    private let feedback = NSTextField(labelWithString: "")
    private var enforceGate = false

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 250),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "License f/uno"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.bg1.cgColor

        let mark = NSTextField(labelWithString: "ƒ/")
        mark.font = NSFont(name: "Georgia-Italic", size: 30) ?? NSFont.systemFont(ofSize: 30)
        mark.textColor = Theme.accent

        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = Theme.tx0

        let hint = NSTextField(labelWithString: "Paste your license key (starts with FUNO.)")
        hint.font = NSFont.systemFont(ofSize: 11.5)
        hint.textColor = Theme.tx2

        keyField.font = Theme.mono(11)
        keyField.placeholderString = "FUNO.…"
        keyField.lineBreakMode = .byTruncatingMiddle

        feedback.font = NSFont.systemFont(ofSize: 11.5)
        feedback.textColor = Theme.red

        let activate = NSButton(title: "Activate", target: self, action: #selector(activateTapped))
        activate.bezelStyle = .rounded
        activate.keyEquivalent = "\r"

        let buy = NSButton(title: "Get a license…", target: self, action: #selector(buyTapped))
        buy.bezelStyle = .rounded

        let row = NSStackView(views: [buy, NSView(), activate])
        row.orientation = .horizontal

        let stack = NSStackView(views: [mark, statusLabel, hint, keyField, feedback, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            keyField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    /// Show the window. `gate: true` (expired) makes closing it quit.
    func show(gate: Bool = false) {
        enforceGate = gate
        refresh()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refresh() {
        switch LicenseManager.shared.status {
        case .licensed(let email):
            statusLabel.stringValue = "Licensed to \(email). Thank you."
            feedback.stringValue = ""
            enforceGate = false
        case .trial(let days):
            statusLabel.stringValue = "Trial — \(days) day\(days == 1 ? "" : "s") remaining."
        case .expired:
            statusLabel.stringValue = "Trial ended. Enter a license to keep culling."
        }
    }

    @objc private func activateTapped() {
        if let email = LicenseManager.shared.activate(keyField.stringValue) {
            feedback.textColor = Theme.labelColors[3]
            feedback.stringValue = "Activated — licensed to \(email)."
            enforceGate = false
            refresh()
        } else {
            feedback.textColor = Theme.red
            feedback.stringValue = "That key didn't validate. Check for missing characters."
        }
    }

    @objc private func buyTapped() {
        NSWorkspace.shared.open(URL(string: "https://funophoto.com")!)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if enforceGate, !LicenseManager.shared.isUsable {
            NSApp.terminate(nil)
        }
        return true
    }
}

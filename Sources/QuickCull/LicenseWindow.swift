import AppKit

/// Activation window - the first thing a PAYING customer sees, so it gets
/// the full graphite/brass treatment: centered lockup, styled key field,
/// one confident brass button. In trial it's dismissible; once expired,
/// closing it quits the app (the gate).
final class LicenseWindowController: NSWindowController, NSWindowDelegate {

    static let shared = LicenseWindowController()

    private let statusLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let keyField = NSTextField()
    private let fieldWrap = NSView()
    private let feedback = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "Paste the license key from your receipt")
    private var activateButton: BrassButton!
    private var buyButton: NSButton!
    private var enforceGate = false

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "License"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = Theme.bg0
        super.init(window: window)
        window.delegate = self
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.bg0.cgColor

        // Brand lockup: the serif italic ƒ/ with mono "uno" - the site's mark.
        let mark = NSTextField(labelWithString: "")
        let lockup = NSMutableAttributedString(string: "ƒ/", attributes: [
            .font: NSFont(name: "Georgia-Italic", size: 34) ?? Theme.display,
            .foregroundColor: Theme.accent
        ])
        lockup.append(NSAttributedString(string: "uno", attributes: [
            .font: Theme.monoDisplay,
            .foregroundColor: Theme.tx0
        ]))
        mark.attributedStringValue = lockup
        mark.alignment = .center

        statusLabel.font = Theme.headline
        statusLabel.textColor = Theme.tx0
        statusLabel.alignment = .center

        subLabel.font = Theme.secondary
        subLabel.textColor = Theme.tx2
        subLabel.alignment = .center

        hint.font = Theme.caption
        hint.textColor = Theme.tx2
        hint.alignment = .center

        // Key field in a dark inset well.
        fieldWrap.wantsLayer = true
        fieldWrap.layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1).cgColor
        fieldWrap.layer?.cornerRadius = 8
        fieldWrap.layer?.borderWidth = 1
        fieldWrap.layer?.borderColor = Theme.line.cgColor
        keyField.font = Theme.monoData
        keyField.textColor = Theme.tx0
        keyField.placeholderString = "FUNO-…"
        keyField.isBordered = false
        keyField.drawsBackground = false
        keyField.focusRingType = .none
        keyField.lineBreakMode = .byTruncatingMiddle
        keyField.translatesAutoresizingMaskIntoConstraints = false
        fieldWrap.addSubview(keyField)
        NSLayoutConstraint.activate([
            keyField.leadingAnchor.constraint(equalTo: fieldWrap.leadingAnchor, constant: 12),
            keyField.trailingAnchor.constraint(equalTo: fieldWrap.trailingAnchor, constant: -12),
            keyField.centerYAnchor.constraint(equalTo: fieldWrap.centerYAnchor),
            fieldWrap.heightAnchor.constraint(equalToConstant: 36)
        ])

        feedback.font = Theme.secondary
        feedback.textColor = Theme.red
        feedback.alignment = .center
        feedback.lineBreakMode = .byWordWrapping
        feedback.maximumNumberOfLines = 2

        activateButton = BrassButton(title: "Activate", target: self, action: #selector(activateTapped))
        activateButton.keyEquivalent = "\r"

        buyButton = NSButton(title: "", target: self, action: #selector(buyTapped))
        buyButton.attributedTitle = NSAttributedString(string: "Get a license - $99", attributes: [
            .foregroundColor: Theme.accent,
            .font: Theme.secondary,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ])
        buyButton.isBordered = false
        buyButton.setButtonType(.momentaryChange)

        let buttonRow = NSStackView(views: [buyButton, NSView(), activateButton])
        buttonRow.orientation = .horizontal

        let stack = NSStackView(views: [mark, statusLabel, subLabel, fieldWrap, hint, feedback, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(18, after: mark)
        stack.setCustomSpacing(4, after: statusLabel)
        stack.setCustomSpacing(20, after: subLabel)
        stack.setCustomSpacing(6, after: fieldWrap)
        stack.setCustomSpacing(16, after: feedback)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 36),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            fieldWrap.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
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
        let formVisible: Bool
        switch LicenseManager.shared.status {
        case .licensed(let email):
            statusLabel.stringValue = "Licensed to \(email)"
            subLabel.stringValue = "Thank you for supporting f/uno."
            feedback.stringValue = ""
            enforceGate = false
            formVisible = false
        case .trial(let days):
            statusLabel.stringValue = "Trial - \(days) day\(days == 1 ? "" : "s") remaining"
            subLabel.stringValue = "Full features. One purchase, yours forever, 2 Macs."
            formVisible = true
        case .expired:
            statusLabel.stringValue = "Your trial has ended"
            subLabel.stringValue = "Enter a license to keep culling - everything you rated is safe in your folders."
            formVisible = true
        }
        fieldWrap.isHidden = !formVisible
        hint.isHidden = !formVisible
        activateButton.isHidden = !formVisible
        buyButton.isHidden = !formVisible
    }

    @objc private func activateTapped() {
        activateButton.isEnabled = false
        feedback.textColor = Theme.tx2
        feedback.stringValue = "Validating…"
        LicenseManager.shared.activate(keyField.stringValue) { [weak self] display, error in
            guard let self else { return }
            self.activateButton.isEnabled = true
            if let display {
                self.feedback.textColor = Theme.labelColors[3]
                self.feedback.stringValue = "Activated - licensed to \(display)."
                self.enforceGate = false
                self.refresh()
                // Let the confirmation register, then get out of the way.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    self?.window?.close()
                }
            } else {
                self.feedback.textColor = Theme.red
                self.feedback.stringValue = error ?? "That key didn't validate."
            }
        }
    }

    @objc private func buyTapped() {
        // Polar checkout (merchant of record): pays, mints the FUNO- key,
        // emails the receipt. The key comes back through activate().
        NSWorkspace.shared.open(URL(string: "https://buy.polar.sh/polar_cl_O0eXJ8iEFujhZ4nLtWRQzS20yI5W7XVPl4MBx2nJsVz")!)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if enforceGate, !LicenseManager.shared.isUsable {
            NSApp.terminate(nil)
        }
        return true
    }
}

/// Filled brass button - the site's .btn, in AppKit.
final class BrassButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }
    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = Theme.accent.cgColor
        layer?.cornerRadius = 7
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Theme.bodyStrong,
            .foregroundColor: NSColor(calibratedRed: 0.09, green: 0.075, blue: 0.06, alpha: 1)
        ])
        setButtonType(.momentaryChange)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        s.width += 36; s.height += 12
        return s
    }
    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1.0 : 0.5 }
    }
}

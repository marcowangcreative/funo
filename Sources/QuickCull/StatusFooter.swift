import AppKit

/// Window root: the split view (sidebar | tabs) fills the window with ONE
/// full-width status footer beneath both — the sidebar terminates at the
/// footer, and the status text lives in the window's true bottom-left.
final class RootViewController: NSViewController {

    let split = MainSplitViewController()
    let footer = StatusFooterView()

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(split)
        let splitView = split.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splitView)
        view.addSubview(footer)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            footer.topAnchor.constraint(equalTo: splitView.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 28)
        ])
        split.footer = footer
    }
}

/// The single status footer: status text + clickable Undo on the left,
/// keyboard hints and the → Lightroom / → Photoshop hand-offs on the right.
/// The ACTIVE tab's grid feeds it; it renders.
final class StatusFooterView: NSView {

    var onUndo: (() -> Void)?
    var onSendLightroom: (() -> Void)?
    var onSendPhotoshop: (() -> Void)?

    private let statusLabel = NSTextField(labelWithString: "Open a folder to begin. Nothing to import.")
    private let undoButton = NSButton(title: "", target: nil, action: nil)
    private let hints = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg1.cgColor

        let topLine = NSView()
        topLine.wantsLayer = true
        topLine.layer?.backgroundColor = Theme.line.cgColor
        topLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topLine)

        statusLabel.font = Theme.mono(10.5)
        statusLabel.textColor = Theme.tx1
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        // Gmail-style clickable Undo, shown next to undoable flashes.
        undoButton.attributedTitle = NSAttributedString(string: "Undo", attributes: [
            .foregroundColor: Theme.accent,
            .font: NSFont.systemFont(ofSize: 10.5, weight: .bold)
        ])
        undoButton.isBordered = false
        undoButton.setButtonType(.momentaryChange)
        undoButton.target = self
        undoButton.action = #selector(undoTapped(_:))
        undoButton.isHidden = true
        undoButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(undoButton)

        hints.orientation = .horizontal
        hints.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hints)
        NotificationCenter.default.addObserver(self, selector: #selector(cullModeDidChange),
                                               name: RatingsStore.cullModeChanged, object: nil)
        refreshHints()

        // Hand-off is the END of every cull — visible buttons, not buried
        // context-menu items. Only installed apps appear.
        // The hand-off buttons wear the REAL app icons, fetched at runtime
        // from the installed apps via NSWorkspace (never bundled — that's
        // Adobe's artwork; asking the system for an app's icon is how the
        // Dock and Finder do it). Title stays for clarity; icon leads.
        func handoffButton(_ title: String, _ action: Selector, tip: String,
                           appURL: URL?) -> NSButton {
            let b = NSButton(title: "", target: self, action: action)
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: Theme.accent,
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            ])
            if let appURL {
                let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                icon.size = NSSize(width: 16, height: 16)
                b.image = icon
                b.imagePosition = .imageLeading
                b.imageHugsTitle = true
            }
            b.isBordered = false
            b.setButtonType(.momentaryChange)
            b.toolTip = tip
            b.translatesAutoresizingMaskIntoConstraints = false
            addSubview(b)
            return b
        }
        var handoffButtons: [NSButton] = []
        if PhotoshopBridge.isAvailable {
            handoffButtons.append(handoffButton("Photoshop", #selector(sendPS(_:)),
                                                tip: "Open the selected photos in Photoshop (Camera Raw)",
                                                appURL: PhotoshopBridge.appURL()))
        }
        if LightroomBridge.isAvailable {
            handoffButtons.append(handoffButton("Lightroom", #selector(sendLR(_:)),
                                                tip: "Send the selected photos to Lightroom's import",
                                                appURL: LightroomBridge.appURL()))
        }

        NSLayoutConstraint.activate([
            topLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            topLine.topAnchor.constraint(equalTo: topAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1),

            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: hints.leadingAnchor, constant: -60),

            undoButton.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 10),
            undoButton.trailingAnchor.constraint(lessThanOrEqualTo: hints.leadingAnchor, constant: -12),
            undoButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            hints.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        var trailing = trailingAnchor
        var pad: CGFloat = 14
        for b in handoffButtons {
            b.trailingAnchor.constraint(equalTo: trailing, constant: -pad).isActive = true
            b.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
            trailing = b.leadingAnchor
            pad = 16
        }
        hints.trailingAnchor.constraint(equalTo: trailing,
                                        constant: handoffButtons.isEmpty ? -14 : -22).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func cullModeDidChange() { refreshHints() }

    private func refreshHints() {
        hints.arrangedSubviews.forEach { hints.removeArrangedSubview($0); $0.removeFromSuperview() }
        let colorFirst = RatingsStore.shared.colorFirstRating
        hints.addArrangedSubview(Theme.hintRow([
            ("1–5", colorFirst ? "color" : "rate"),
            ("⌃1–5", colorFirst ? "rate" : "color"),
            ("X", "reject"), ("Space", "preview"), ("S", "survey")
        ]))
    }

    func setStatus(_ text: String, undoVisible: Bool) {
        statusLabel.stringValue = text
        undoButton.isHidden = !undoVisible
    }

    @objc private func undoTapped(_ sender: Any?) {
        undoButton.isHidden = true
        onUndo?()
    }

    @objc private func sendLR(_ sender: Any?) { onSendLightroom?() }
    @objc private func sendPS(_ sender: Any?) { onSendPhotoshop?() }
}

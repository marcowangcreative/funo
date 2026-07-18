import AppKit

/// The keyboard cheat-sheet: press / (or Help ▸ Keyboard Shortcuts) for a
/// quick panel of every cull key, drawn with the same keycap chips the rest
/// of the app uses. Dismiss with Escape, /, or a click outside.
///
/// One straight-down column, docked to the right edge of the window. A single
/// column means there is no cross-column alignment to get wrong: every row is
/// just a keycap followed by its label.
final class ShortcutsOverlayView: NSView {

    var onDismiss: (() -> Void)?
    private let panel = NSView()
    private var dismissing = false

    private struct Group { let title: String; let rows: [(String, String)] }

    /// Built per-present so the 1–5 rows reflect the CURRENT cull mode.
    private var groups: [Group] {
        let colorFirst = RatingsStore.shared.colorFirstRating
        let rate: [(String, String)] = colorFirst
            ? [("1–5", "set color label"), ("⌃1–5", "set star rating")]
            : [("1–5", "set star rating"), ("⌃1–5", "set color label")]
        return [
            Group(title: "RATE & LABEL", rows: rate + [
                ("0", "clear rating"), ("X", "reject"), ("U", "unlabel"), ("`", "swap stars / colors")]),
            Group(title: "LOOK", rows: [
                ("Space", "expand / collapse"), ("S", "survey compare"),
                ("Z", "100% zoom"), ("[  ]", "rotate"), ("+  −", "thumbnail size")]),
            Group(title: "MOVE", rows: [
                ("← → ↑ ↓", "move selection"), ("⇧", "+ arrows to extend"), ("Home  End", "first / last")]),
            Group(title: "FIND & TABS", rows: [
                ("⌘F", "find frames + folders"), ("⌘T", "new tab"), ("⌘W", "close tab"),
                ("⌘1–9", "jump to tab"), ("⌘←  ⌘→", "cycle tabs")]),
            Group(title: "FILES", rows: [
                ("⌘C ⌘X ⌘V", "copy / cut / paste"), ("⌘⌫", "move to Trash"),
                ("⌘Z", "undo"), ("⌘O", "open folder"), ("⌘I", "ingest cards")]),
        ]
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor   // no scrim: a light popup, not a modal dim
        build()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)) { animateAway() }
    }

    private func build() {
        panel.wantsLayer = true
        panel.layer?.backgroundColor = Theme.bg1.cgColor
        panel.layer?.cornerRadius = 14
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = Theme.line.cgColor
        panel.layer?.shadowColor = NSColor.black.cgColor
        panel.layer?.shadowOpacity = 0.4
        panel.layer?.shadowRadius = 40
        panel.layer?.shadowOffset = NSSize(width: 0, height: -10)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        let title = NSTextField(labelWithString: "")
        title.attributedStringValue = NSAttributedString(string: "KEYBOARD SHORTCUTS", attributes: [
            .font: Theme.monoEyebrow, .foregroundColor: Theme.accent, .kern: 2.0])

        let hint = NSTextField(labelWithString: "Press / or Esc to close")
        hint.font = Theme.caption
        hint.textColor = .tertiaryLabelColor

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.edgeInsets = NSEdgeInsets(top: 28, left: 0, bottom: 24, right: 0)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(title)
        content.setCustomSpacing(22, after: title)
        var last: NSView = title
        for group in groups {
            let gv = groupView(group)
            content.addArrangedSubview(gv)
            last = gv
        }
        content.setCustomSpacing(22, after: last)
        content.addArrangedSubview(hint)
        panel.addSubview(content)

        let margin: CGFloat = 40
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: panel.topAnchor),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: margin),
            panel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: margin),
            // Docked to the RIGHT edge, vertically centered.
            trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: 24),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func groupView(_ group: Group) -> NSStackView {
        let header = NSTextField(labelWithString: "")
        header.attributedStringValue = NSAttributedString(string: group.title, attributes: [
            .font: Theme.monoEyebrow, .foregroundColor: Theme.tx2, .kern: 1.4])
        let stack = NSStackView(views: [header])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.setCustomSpacing(10, after: header)
        for (key, action) in group.rows {
            // Key left-aligned at natural width, label a tight fixed gap after.
            let word = NSTextField(labelWithString: action)
            word.font = Theme.secondary
            word.textColor = Theme.tx1
            let row = NSStackView(views: [Theme.keycap(key, font: Theme.monoCaption), word])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            stack.addArrangedSubview(row)
        }
        return stack
    }

    func present(in container: NSView) {
        frame = container.bounds
        autoresizingMask = [.width, .height]
        container.addSubview(self)
        window?.makeFirstResponder(self)
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.13
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    /// Fade out, then hand off to the dismiss handler (which removes us).
    private func animateAway() {
        guard !dismissing else { return }
        dismissing = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.11
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.onDismiss?() })
    }

    /// Escape or / closes. Returns true (always consumes while up).
    func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 || event.characters == "/" { animateAway() }
        return true
    }
}

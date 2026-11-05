import AppKit

/// A brass progress track: a graphite groove with a brass fill whose width is
/// the fraction done. NSProgressIndicator won't tint cleanly to a custom
/// color, so we draw our own - and because the width is a constraint we set,
/// it can never overrun the panel.
private final class BrassBar: NSView {
    private let fill = NSView()
    private var fillWidth: NSLayoutConstraint!
    let trackWidth: CGFloat

    init(width: CGFloat) {
        self.trackWidth = width
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg3.cgColor
        layer?.cornerRadius = Theme.controlRadius
        translatesAutoresizingMaskIntoConstraints = false
        fill.wantsLayer = true
        fill.layer?.backgroundColor = Theme.accent.cgColor
        fill.layer?.cornerRadius = Theme.controlRadius
        fill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fill)
        fillWidth = fill.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: trackWidth),
            heightAnchor.constraint(equalToConstant: 8),
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.topAnchor.constraint(equalTo: topAnchor),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor),
            fillWidth,
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func setFraction(_ f: CGFloat) {
        fillWidth.constant = trackWidth * max(0, min(1, f))
    }
}

/// A modal progress panel for big file moves/copies. It dims the window,
/// shows a brass bar with a running count, and - sitting over the whole
/// content view swallowing mouse and key events - LOCKS folder switching until
/// the operation finishes, so the user can't wander off mid move. Small ops
/// skip it (see the caller threshold); it only appears for real work.
final class FileOpProgressOverlayView: NSView {

    private let panel = NSView()
    private let bar = BrassBar(width: 300)
    private let detail = NSTextField(labelWithString: "")
    private let total: Int

    init(title: String, total: Int) {
        self.total = total
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        build(title: title)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {}        // swallow: no click-through
    override func keyDown(with event: NSEvent) {}          // swallow: no nav keys

    private func build(title: String) {
        panel.wantsLayer = true
        panel.layer?.backgroundColor = Theme.bg1.cgColor
        panel.layer?.cornerRadius = Theme.panelRadius
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = Theme.line.cgColor
        panel.layer?.shadowColor = NSColor.black.cgColor
        panel.layer?.shadowOpacity = 0.4
        panel.layer?.shadowRadius = 30
        panel.layer?.shadowOffset = NSSize(width: 0, height: -8)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Theme.body
        titleLabel.textColor = Theme.tx0

        detail.font = Theme.monoCaption
        detail.textColor = Theme.tx2
        detail.stringValue = "0 of \(total.formatted())"

        let content = NSStackView(views: [titleLabel, bar, detail])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(content)

        // Fixed, centered panel: the bar is 300 wide, so a 364-wide panel
        // leaves an even 32 margin each side and can never clip on the window.
        NSLayoutConstraint.activate([
            panel.widthAnchor.constraint(equalToConstant: Theme.Panel.width),
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: 26),
            panel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: 22),
            content.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func present(in container: NSView) {
        frame = container.bounds
        autoresizingMask = [.width, .height]
        container.addSubview(self)
        window?.makeFirstResponder(self)
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Panel.fadeIn
            animator().alphaValue = 1
        }
    }

    func update(done: Int) {
        bar.setFraction(CGFloat(done) / CGFloat(max(total, 1)))
        detail.stringValue = "\(done.formatted()) of \(total.formatted())"
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.removeFromSuperview() })
    }
}

/// Shared driver so any file-op call site can raise the same progress lock.
/// All methods are main-thread only; background workers dispatch to main.
///
/// The panel is TIME-based, not count-based: begin() only schedules it, and it
/// appears if the operation is still running after `showDelay`. A fast machine
/// (or a small op, or a warm cache) finishes first and never flashes it; a slow
/// drive shows it. So there's no magic photo-count threshold to tune - it self-
/// adjusts to how long the work actually takes. The nav lock (isActive) engages
/// only once the panel is really on screen.
final class FileOpProgress {
    static let shared = FileOpProgress()
    private var overlay: FileOpProgressOverlayView?
    private var pending: DispatchWorkItem?
    private var title = ""
    private var total = 0
    private var lastDone = 0

    /// How long an op must run before the panel appears.
    private let showDelay: TimeInterval = 0.3

    /// True only while the panel is actually on screen - navigation checks this.
    var isActive: Bool { overlay != nil }

    func begin(_ title: String, total: Int) {
        cancel()
        self.title = title; self.total = total; self.lastDone = 0
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pending != nil,
                  let content = NSApp.keyWindow?.contentView else { return }
            let o = FileOpProgressOverlayView(title: self.title, total: self.total)
            o.present(in: content)
            o.update(done: self.lastDone)
            self.overlay = o
            self.pending = nil
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
    }

    func update(done: Int) {
        lastDone = done
        overlay?.update(done: done)
    }

    func end() { cancel() }

    private func cancel() {
        pending?.cancel(); pending = nil
        overlay?.dismiss(); overlay = nil
    }
}

/// A small "Finishing up…" panel shown during the quit-time sidecar/JSON drain
/// (see AppDelegate.applicationShouldTerminate). A big rating leaves a backlog
/// of sidecar writes; rather than a silent main-thread freeze on quit, we say
/// what's happening and drain in the background while this renders. It swallows
/// input so nothing changes mid-drain. Indeterminate spinner - we only need to
/// communicate "working", not per-file progress.
final class QuitFlushOverlayView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {}
}

enum QuitFlushOverlay {
    private static var view: NSView?

    static func show() {
        guard view == nil, let content = NSApp.keyWindow?.contentView else { return }
        let overlay = QuitFlushOverlayView(frame: content.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor

        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = Theme.bg1.cgColor
        panel.layer?.cornerRadius = Theme.panelRadius
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = Theme.line.cgColor
        panel.layer?.shadowColor = NSColor.black.cgColor
        panel.layer?.shadowOpacity = 0.4
        panel.layer?.shadowRadius = 30
        panel.layer?.shadowOffset = NSSize(width: 0, height: -8)
        panel.translatesAutoresizingMaskIntoConstraints = false

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: "Finishing up, saving your ratings…")
        label.font = Theme.body
        label.textColor = Theme.tx0

        let row = NSStackView(views: [spinner, label])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(row)
        overlay.addSubview(panel)
        content.addSubview(overlay)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: panel.topAnchor, constant: 20),
            row.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -20),
            row.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 24),
            row.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -24),
            panel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])
        overlay.window?.makeFirstResponder(overlay)
        view = overlay
    }

    static func hide() {
        view?.removeFromSuperview()
        view = nil
    }
}

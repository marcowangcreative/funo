import AppKit
import QuickCullCore

/// Hidden. Option-Command-J. Live jobs, so a stuck walk is visible without
/// Instruments.
final class WorkDebugWindow {
    static let shared = WorkDebugWindow()
    private var panel: NSPanel?
    private var text: NSTextField?
    private var timer: Timer?

    func toggle() {
        if panel?.isVisible == true {
            timer?.invalidate()
            timer = nil
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        refresh()
        panel.orderFront(nil)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Background work"
        panel.isFloatingPanel = true
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = Theme.monoCaption
        label.textColor = Theme.tx0
        label.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(label)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
                label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
            ])
        }
        text = label
        return panel
    }

    private func refresh() {
        let now = Date().timeIntervalSinceReferenceDate
        let jobs = WorkRunner.shared.scheduler.live()
        if jobs.isEmpty {
            text?.stringValue = "No live jobs."
            return
        }
        text?.stringValue = jobs.map { job in
            let age = now - (job.startedAt ?? job.enqueuedAt)
            return String(format: "%@  %@  %.0fs  %@  %@", job.lane.label, job.stateLabel, age, job.volume, job.name)
        }.joined(separator: "\n")
    }
}

private extension WorkState {
    var stateLabel: String {
        switch self {
        case .queued: return "queued"
        case .running: return "running"
        case .finished: return "finished"
        case .cancelled: return "cancelled"
        case .timedOut: return "timed out"
        }
    }
}

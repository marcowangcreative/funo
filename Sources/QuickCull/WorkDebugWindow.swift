import AppKit
import QuickCullCore

/// Visible grid cells that still have no thumbnail, and why.
final class ThumbWatch {
    static let shared = ThumbWatch()
    private(set) var lines: [String] = []

    func setMissing(_ rows: [(String, String)]) {
        lines = rows.map { "\($0.0)  \($0.1)" }
    }

    var summary: String {
        if lines.isEmpty { return "Visible cells missing a thumbnail: 0" }
        return "Visible cells missing a thumbnail: \(lines.count)\n" + lines.joined(separator: "\n")
    }
}

/// One line per folder open: listing size, time to the grid, time to the
/// first screen of thumbnails, where those pixels came from, and time to
/// the last capture date. The debug window shows the latest one.
final class FolderMetrics {
    static let shared = FolderMetrics()
    private(set) var summary = "No folder opened yet."
    private var files = 0
    private var gridMS: Double?
    private var screenMS: Double?
    private var datesMS: Double?
    private var cache = 0
    private var embedded = 0
    private var full = 0

    func noteGrid(files: Int, gridMS: Double) {
        self.files = files
        self.gridMS = gridMS
        screenMS = nil
        datesMS = nil
        cache = 0
        embedded = 0
        full = 0
        publish("grid")
    }

    func noteScreen(ms: Double, cache: Int, embedded: Int, full: Int) {
        screenMS = ms
        self.cache = cache
        self.embedded = embedded
        self.full = full
        publish("first screen")
    }

    func noteDates(files: Int, ms: Double, cache: Int, embedded: Int, full: Int) {
        self.files = files
        datesMS = ms
        self.cache = cache
        self.embedded = embedded
        self.full = full
        publish("dates")
    }

    private func publish(_ when: String) {
        var parts: [String] = ["\(files) files"]
        if let gridMS { parts.append(String(format: "grid %.0f ms", gridMS)) }
        if let screenMS { parts.append(String(format: "first screen %.0f ms", screenMS)) }
        parts.append("cache \(cache)")
        parts.append("embedded \(embedded)")
        parts.append("full \(full)")
        if let datesMS { parts.append(String(format: "dates %.0f ms", datesMS)) }
        summary = parts.joined(separator: ", ")
        FunoLog.write("funo folder (\(when)): \(summary)")
    }
}

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
        let header = FolderMetrics.shared.summary
        let missing = ThumbWatch.shared.summary
        let jobLines: String
        if jobs.isEmpty {
            jobLines = "No live jobs."
        } else {
            jobLines = jobs.map { job in
                let age = now - (job.startedAt ?? job.enqueuedAt)
                return String(format: "%@  %@  %.0fs  %@  %@", job.lane.label, job.state.stateLabel, age, job.volume, job.name)
            }.joined(separator: "\n")
        }
        text?.stringValue = header + "\n\n" + missing + "\n\n" + jobLines
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

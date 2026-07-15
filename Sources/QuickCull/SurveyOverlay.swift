import AppKit

/// Survey mode: 2–4 selected photos side by side, BIG, for the one
/// comparison culling actually needs — "which of these frames wins?"
///
/// S opens it from a 2–4 photo selection. Amber ring = focused frame;
/// click or arrows move focus; 1–5/0 rate, ⌃1–5 color, X reject the
/// focused frame; Space opens it full screen; Esc or S returns to the grid.
/// Z / scroll ZOOM ALL FRAMES TOGETHER to the same spot — the point of
/// survey is comparing the same detail (focus, eyes) across near-dupes.
final class SurveyOverlay: NSView {

    var onClose: (() -> Void)?
    var onCullChanged: (() -> Void)?
    var onOpenFull: ((PhotoAsset) -> Void)?

    private var assets: [PhotoAsset] = []
    private var cells: [SurveyCell] = []
    private var focusedIndex = 0
    private var sharpness: [Int: Double] = [:]

    // Synced zoom shared by every frame.
    private var zoomScale: CGFloat = 1
    private var zoomCenter = CGPoint(x: 0.5, y: 0.5)

    private let footerBar = NSView()
    private let hintLabel = NSStackView()
    private let zoomLabel = NSTextField(labelWithString: "FIT")

    init(frame frameRect: NSRect, assets: [PhotoAsset]) {
        super.init(frame: frameRect)
        self.assets = Array(assets.prefix(4))
        wantsLayer = true
        layer?.backgroundColor = Theme.surround.color.cgColor

        for (i, asset) in self.assets.enumerated() {
            let cell = SurveyCell(asset: asset)
            cell.onClick = { [weak self] in self?.focus(i) }
            cell.onDoubleClick = { [weak self] in
                guard let self else { return }
                self.onOpenFull?(self.assets[i])
            }
            cell.onScroll = { [weak self] dy in self?.zoomBy(dy) }
            cell.onPan = { [weak self] dx, dy in self?.panBy(dx, dy) }
            addSubview(cell)
            cells.append(cell)
        }
        focus(0)

        // Footer bar — hints + zoom readout, matching the expanded view.
        footerBar.wantsLayer = true
        footerBar.layer?.backgroundColor = Theme.bg1.cgColor
        footerBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footerBar)
        let topLine = NSView()
        topLine.wantsLayer = true
        topLine.layer?.backgroundColor = Theme.line.cgColor
        topLine.translatesAutoresizingMaskIntoConstraints = false
        footerBar.addSubview(topLine)
        zoomLabel.font = Theme.mono(11)
        zoomLabel.textColor = Theme.tx2
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        footerBar.addSubview(zoomLabel)
        hintLabel.orientation = .horizontal
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        footerBar.addSubview(hintLabel)
        NotificationCenter.default.addObserver(self, selector: #selector(cullModeDidChange),
                                               name: RatingsStore.cullModeChanged, object: nil)
        refreshHint()
        NSLayoutConstraint.activate([
            footerBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            footerBar.heightAnchor.constraint(equalToConstant: 28),
            topLine.leadingAnchor.constraint(equalTo: footerBar.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: footerBar.trailingAnchor),
            topLine.topAnchor.constraint(equalTo: footerBar.topAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1),
            hintLabel.leadingAnchor.constraint(equalTo: footerBar.leadingAnchor, constant: 14),
            hintLabel.centerYAnchor.constraint(equalTo: footerBar.centerYAnchor),
            zoomLabel.trailingAnchor.constraint(equalTo: footerBar.trailingAnchor, constant: -14),
            zoomLabel.centerYAnchor.constraint(equalTo: footerBar.centerYAnchor)
        ])

        // Photos load at preview quality; score focus once each lands.
        for (i, cell) in cells.enumerated() {
            let asset = cell.asset
            ThumbnailLoader.shared.request(asset.url, maxPixel: ThumbnailLoader.previewPixelSize) { [weak self, weak cell] image in
                cell?.setImage(image)
                SharpnessAnalyzer.shared.score(for: asset) { acutance in
                    guard let self, let acutance else { return }
                    self.sharpness[i] = acutance
                    cell?.setFocus(fraction: SharpnessAnalyzer.focusFraction(acutance))
                    self.updateSharpestCrown()
                }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var acceptsFirstResponder: Bool { true }

    @objc private func cullModeDidChange() { refreshHint() }

    private func refreshHint() {
        hintLabel.arrangedSubviews.forEach { hintLabel.removeArrangedSubview($0); $0.removeFromSuperview() }
        let colorFirst = RatingsStore.shared.colorFirstRating
        hintLabel.addArrangedSubview(Theme.hintRow([
            ("← →", "focus"),
            ("1–5", colorFirst ? "color" : "rate"),
            ("⌃1–5", colorFirst ? "rate" : "color"),
            ("X", "reject"), ("Z", "zoom"), ("Space", "full"), ("⎋", "grid")
        ]))
    }

    private func updateSharpestCrown() {
        guard sharpness.count == cells.count,
              let best = sharpness.max(by: { $0.value < $1.value })?.key else { return }
        for (i, cell) in cells.enumerated() { cell.setSharpest(i == best) }
    }

    // MARK: - Layout (footer reserved at the bottom)

    override func layout() {
        super.layout()
        let pad: CGFloat = 20
        let gap: CGFloat = 14
        let area = bounds.insetBy(dx: pad, dy: pad)
        // Keep the grid clear of the footer bar.
        let usable = NSRect(x: area.minX, y: area.minY + 28,
                            width: area.width, height: area.height - 28)
        guard !cells.isEmpty, usable.width > 0, usable.height > 0 else { return }

        let columns = cells.count == 4 ? 2 : cells.count
        let rows = cells.count == 4 ? 2 : 1
        let cellW = (usable.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellH = (usable.height - gap * CGFloat(max(0, rows - 1))) / CGFloat(rows)

        for (i, cell) in cells.enumerated() {
            let col = i % columns
            let row = i / columns
            let y = usable.maxY - CGFloat(row + 1) * cellH - CGFloat(row) * gap
            cell.frame = NSRect(x: usable.minX + CGFloat(col) * (cellW + gap),
                                y: y, width: cellW, height: cellH)
        }
    }

    // MARK: - Focus & zoom

    private func focus(_ index: Int) {
        guard cells.indices.contains(index) else { return }
        focusedIndex = index
        for (i, cell) in cells.enumerated() { cell.setFocused(i == index) }
    }

    private func zoomBy(_ dy: CGFloat) {
        setZoom(zoomScale * (1 + dy * 0.006))
    }

    private func toggleZoom() {
        setZoom(zoomScale > 1.05 ? 1 : 2.5)
    }

    private func setZoom(_ scale: CGFloat) {
        zoomScale = min(6, max(1, scale))
        if zoomScale <= 1.001 { zoomCenter = CGPoint(x: 0.5, y: 0.5) }
        applyZoom()
    }

    private func panBy(_ dx: CGFloat, _ dy: CGFloat) {
        guard zoomScale > 1.001 else { return }
        let ref = max(1, bounds.width / CGFloat(cells.count == 4 ? 2 : cells.count))
        zoomCenter.x -= dx / (ref * zoomScale)
        zoomCenter.y += dy / (ref * zoomScale)
        applyZoom()
    }

    private func applyZoom() {
        let half = 0.5 / zoomScale
        zoomCenter.x = min(max(zoomCenter.x, half), 1 - half)
        zoomCenter.y = min(max(zoomCenter.y, half), 1 - half)
        let size = 1 / zoomScale
        let rect = CGRect(x: zoomCenter.x - half, y: zoomCenter.y - half, width: size, height: size)
        for cell in cells { cell.setContentsRect(rect) }
        zoomLabel.stringValue = zoomScale <= 1.001 ? "FIT" : "\(Int(zoomScale * 100))%"
    }

    override func scrollWheel(with event: NSEvent) {
        zoomBy(event.scrollingDeltaY)
    }

    private var focusedID: String { assets[focusedIndex].id }

    /// Same contract as the grid: true = key consumed.
    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: onClose?(); return true                       // esc
        case 123: focus(max(0, focusedIndex - 1)); return true // ←
        case 124: focus(min(cells.count - 1, focusedIndex + 1)); return true // →
        case 126: focus(max(0, focusedIndex - (cells.count == 4 ? 2 : 1))); return true // ↑
        case 125: focus(min(cells.count - 1, focusedIndex + (cells.count == 4 ? 2 : 1))); return true // ↓
        case 49, 36:                                           // space, return
            onOpenFull?(assets[focusedIndex]); return true
        default:
            break
        }
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { return false }
        let ctrl = event.modifierFlags.contains(.control)
        if ctrl, !["0", "1", "2", "3", "4", "5"].contains(chars) { return false }
        switch chars {
        case "z":
            toggleZoom(); return true
        case "1", "2", "3", "4", "5":
            let n = Int(chars)!
            if RatingsStore.shared.digitSetsStar(control: ctrl) {
                RatingsStore.shared.setRating(n, for: focusedID)
            } else {
                RatingsStore.shared.setColorLabel(n, for: focusedID)
            }
        case "0":
            if RatingsStore.shared.digitSetsStar(control: ctrl) {
                RatingsStore.shared.setRating(0, for: focusedID)
            } else {
                RatingsStore.shared.setColorLabel(0, for: focusedID)
            }
        case "x":
            RatingsStore.shared.toggleRejected(focusedID)
        case "u":
            RatingsStore.shared.setColorLabel(0, for: focusedID)
        case "s":
            onClose?()
        default:
            return false
        }
        cells[focusedIndex].refreshCull()
        onCullChanged?()
        return true
    }
}

/// One surveyed frame: aspect-fit image (zoomable via contentsRect), a color
/// strip along the top when labeled, and a tidy footer — filename, stars,
/// focus %. Amber ring when focused; "sharpest" crown on the winner.
private final class SurveyCell: NSView {

    let asset: PhotoAsset
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onScroll: ((CGFloat) -> Void)?
    var onPan: ((CGFloat, CGFloat) -> Void)?

    private let imageHost = NSView()
    private let colorStrip = NSView()
    private let footer = NSTextField(labelWithString: "")
    private let starsLabel = NSTextField(labelWithString: "")
    private let focusLabel = NSTextField(labelWithString: "")
    private let crown = PaddedLabel()
    private var isSharpest = false
    private var dragged = false

    init(asset: PhotoAsset) {
        self.asset = asset
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderColor = Theme.accent.cgColor
        layer?.masksToBounds = true

        imageHost.wantsLayer = true
        imageHost.layer?.contentsGravity = .resizeAspect
        addSubview(imageHost)

        // Color label shows as a strip along the TOP of the image — a real
        // highlight on the frame, not a floaty dot tacked into the footer.
        colorStrip.wantsLayer = true
        colorStrip.isHidden = true
        addSubview(colorStrip)

        footer.font = Theme.mono(11)
        footer.textColor = Theme.tx1
        footer.lineBreakMode = .byTruncatingMiddle
        footer.alignment = .center
        addSubview(footer)

        starsLabel.alignment = .center
        addSubview(starsLabel)

        focusLabel.font = Theme.mono(9.5)
        focusLabel.textColor = Theme.tx2
        focusLabel.alignment = .right
        addSubview(focusLabel)

        crown.stringValue = "SHARPEST"
        crown.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        crown.textColor = Theme.accentText
        crown.backgroundFill = Theme.accent
        crown.isHidden = true
        addSubview(crown)

        refreshCull()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setImage(_ image: NSImage?) { imageHost.layer?.contents = image }
    func setContentsRect(_ rect: CGRect) { imageHost.layer?.contentsRect = rect }
    func setFocused(_ focused: Bool) { layer?.borderWidth = focused ? 2 : 0 }

    func setFocus(fraction: Double) {
        focusLabel.stringValue = "focus \(Int(fraction * 100))%"
    }

    func setSharpest(_ sharpest: Bool) {
        isSharpest = sharpest
        crown.isHidden = !sharpest
    }

    func refreshCull() {
        let store = RatingsStore.shared
        let rating = store.rating(for: asset.id)
        if store.isRejected(asset.id) {
            starsLabel.attributedStringValue = NSAttributedString(string: "✕ REJECT", attributes: [
                .foregroundColor: Theme.red,
                .font: NSFont.systemFont(ofSize: 11, weight: .bold), .kern: 1.0
            ])
        } else {
            starsLabel.attributedStringValue = Theme.stars(rating, size: 13)
        }
        let label = store.colorLabel(for: asset.id)
        colorStrip.isHidden = label == 0
        if label > 0 { colorStrip.layer?.backgroundColor = Theme.labelColors[label].cgColor }
    }

    override func layout() {
        super.layout()
        let footerHeight: CGFloat = 38
        imageHost.frame = NSRect(x: 0, y: footerHeight, width: bounds.width, height: bounds.height - footerHeight)
        colorStrip.frame = NSRect(x: 0, y: bounds.height - 5, width: bounds.width, height: 5)
        footer.frame = NSRect(x: 10, y: 20, width: bounds.width - 20, height: 15)
        starsLabel.frame = NSRect(x: 0, y: 3, width: bounds.width, height: 16)
        focusLabel.frame = NSRect(x: bounds.width - 96, y: 4, width: 86, height: 13)
        let cw = crown.intrinsicContentSize.width
        crown.frame = NSRect(x: (bounds.width - cw) / 2, y: bounds.height - 28, width: cw, height: 18)
    }

    override func mouseDown(with event: NSEvent) { dragged = false }

    override func mouseDragged(with event: NSEvent) {
        dragged = true
        onPan?(event.deltaX, event.deltaY)
    }

    override func mouseUp(with event: NSEvent) {
        guard !dragged else { return }
        if event.clickCount >= 2 { onDoubleClick?() } else { onClick?() }
    }

    override func scrollWheel(with event: NSEvent) { onScroll?(event.scrollingDeltaY) }
}

/// A label with interior padding and a rounded fill — used for the crown so
/// its text is properly centered inside the pill (a bare NSTextField's fill
/// hugged the glyphs unevenly).
private final class PaddedLabel: NSTextField {
    var backgroundFill: NSColor = .clear { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = VCenterTextFieldCell()
        isEditable = false; isBordered = false; isBezeled = false
        drawsBackground = false
        alignment = .center
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        s.width += 20; s.height += 6
        return s
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        super.draw(dirtyRect)
    }
}

/// Text-field cell that vertically centers its single line of text — the
/// vertical-centering hook lives on the cell, not the field.
private final class VCenterTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let base = super.drawingRect(forBounds: rect)
        let textHeight = cellSize(forBounds: rect).height
        guard textHeight < base.height else { return base }
        let dy = (base.height - textHeight) / 2
        return NSRect(x: base.minX, y: base.minY + dy, width: base.width, height: textHeight)
    }
}

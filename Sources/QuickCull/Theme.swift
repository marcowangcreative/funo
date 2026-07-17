import AppKit

/// Photo surround: the background photos are judged against. Chrome stays
/// graphite; only the stage and contact-sheet backdrop change. 18% gray is
/// the print-evaluation standard - pure dark makes everything look punchier
/// than it will on paper.
enum Surround: Int, CaseIterable {
    case black, graphite, midGray

    var displayName: String {
        switch self {
        case .black:    return "Black"
        case .graphite: return "Graphite"
        case .midGray:  return "18% Gray"
        }
    }

    var color: NSColor {
        switch self {
        case .black:    return NSColor(white: 0.02, alpha: 1)
        case .graphite: return Theme.bg0
        case .midGray:  return NSColor(white: 0.47, alpha: 1) // ~18% reflectance in sRGB
        }
    }
}

/// The mockup's design language: neutral graphite so the UI never
/// color-casts the photos, one amber accent, hairline borders.
enum Theme {
    static let surroundChanged = Notification.Name("QuickCullSurroundChanged")

    static var surround: Surround {
        get { Surround(rawValue: UserDefaults.standard.integer(forKey: "QuickCullSurround")) ?? .graphite }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "QuickCullSurround")
            NotificationCenter.default.post(name: surroundChanged, object: nil)
        }
    }
    static let bg0    = NSColor(srgbRed: 0.047, green: 0.051, blue: 0.059, alpha: 1) // window
    static let bg1    = NSColor(srgbRed: 0.075, green: 0.078, blue: 0.090, alpha: 1) // panels
    static let bg2    = NSColor(srgbRed: 0.102, green: 0.110, blue: 0.125, alpha: 1) // cards
    static let bg3    = NSColor(srgbRed: 0.137, green: 0.149, blue: 0.161, alpha: 1) // hover / off-stars
    static let line   = NSColor(srgbRed: 0.149, green: 0.157, blue: 0.176, alpha: 1) // hairlines
    static let tx0    = NSColor(srgbRed: 0.925, green: 0.929, blue: 0.933, alpha: 1) // primary text
    static let tx1    = NSColor(srgbRed: 0.604, green: 0.624, blue: 0.651, alpha: 1) // secondary
    static let tx2    = NSColor(srgbRed: 0.361, green: 0.380, blue: 0.404, alpha: 1) // tertiary
    // Aged brass, not template amber: deeper and less saturated than the
    // #E8A33D every generated dark theme ships. Same warm family (selection,
    // stars, live state all keep their meaning) but reads engraved-metal -
    // and gives the Canon-red brand mark on the empty state room to breathe.
    static let accent = NSColor(srgbRed: 0.788, green: 0.588, blue: 0.184, alpha: 1) // #C9962F brass
    static let accentText = NSColor(srgbRed: 0.082, green: 0.063, blue: 0.024, alpha: 1)
    static let red    = NSColor(srgbRed: 0.898, green: 0.282, blue: 0.302, alpha: 1)

    /// Color labels 1–5 (red, yellow, green, blue, purple) - the industry
    /// standard alongside stars; ⌃1–5 apply them (color-first swaps 1–5).
    static let labelColors: [NSColor] = [
        .clear,
        NSColor(srgbRed: 0.898, green: 0.282, blue: 0.302, alpha: 1), // red
        NSColor(srgbRed: 0.961, green: 0.851, blue: 0.039, alpha: 1), // yellow
        NSColor(srgbRed: 0.275, green: 0.655, blue: 0.345, alpha: 1), // green
        NSColor(srgbRed: 0.243, green: 0.388, blue: 0.867, alpha: 1), // blue
        NSColor(srgbRed: 0.557, green: 0.306, blue: 0.776, alpha: 1)  // purple
    ]
    static let labelNames = ["None", "Red", "Yellow", "Green", "Blue", "Purple"]

    /// A keyboard key drawn as a small keycap chip - how real Mac apps show
    /// shortcuts, instead of typing them into a monospace string. Words stay
    /// in the system font; only the KEY itself is a chip.
    static func keycap(_ key: String) -> NSView {
        let label = NSTextField(labelWithString: key)
        label.font = Theme.monoEyebrow
        label.textColor = Theme.tx1
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.backgroundColor = Theme.bg3.cgColor
        chip.layer?.borderColor = Theme.line.cgColor
        chip.layer?.borderWidth = 1
        chip.layer?.cornerRadius = 3.5
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: chip.topAnchor, constant: 1.5),
            label.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -1.5)
        ])
        return chip
    }

    /// One shortcut-hint row: keycap chips + system-font action words.
    /// Rebuildable - callers empty the stack and call this again on mode change.
    static func hintRow(_ items: [(String, String)]) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 13
        for (key, action) in items {
            let word = NSTextField(labelWithString: action)
            word.font = Theme.caption
            word.textColor = Theme.tx2
            let pair = NSStackView(views: [keycap(key), word])
            pair.orientation = .horizontal
            pair.spacing = 4.5
            row.addArrangedSubview(pair)
        }
        return row
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    // MARK: - Type ramp - the ONLY sizes in the app.
    //
    // Two voices: SF for sentences, SF Mono for data (filenames, numbers,
    // keys). Georgia Italic exists solely for the ƒ brand mark. Everything
    // else picks from this ramp - if a new label wants a size that isn't
    // here, the ramp wins. (The audit that prompted this found ELEVEN mono
    // sizes and twelve system sizes, drifted in half-points nobody chose.)
    // Exempt as artwork, not typography: star glyphs, the Lr/Ps chip
    // letters, file-type badges' 16px-tile fit, the title bar (system
    // chrome), and the ƒ lockup.

    // mono - the data voice
    static var monoEyebrow: NSFont { mono(9, .medium) }        // engraved labels, badges
    static var monoCaption: NSFont { mono(10.5) }              // chips, status, small data
    static var monoData: NSFont { mono(12) }                   // values, fields, footers
    static var monoDataStrong: NSFont { mono(12, .semibold) }  // bright values
    static var monoInput: NSFont { mono(15) }                  // the ⌘F field
    static var monoDisplay: NSFont { mono(26) }                // lockup "uno"

    // system - the voice
    static var caption: NSFont { .systemFont(ofSize: 10.5) }
    static var captionStrong: NSFont { .systemFont(ofSize: 10.5, weight: .semibold) }
    static var secondary: NSFont { .systemFont(ofSize: 11.5) }
    static var secondaryStrong: NSFont { .systemFont(ofSize: 11.5, weight: .semibold) }
    static var body: NSFont { .systemFont(ofSize: 13) }
    static var bodyStrong: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
    static var headline: NSFont { .systemFont(ofSize: 15, weight: .medium) }
    static var display: NSFont { .systemFont(ofSize: 34) }     // ƒ lockup fallback

    /// "★★★☆☆"-style attributed stars: filled amber, empty graphite.
    static func stars(_ rating: Int, size: CGFloat) -> NSAttributedString {
        let s = NSMutableAttributedString()
        for i in 1...5 {
            s.append(NSAttributedString(string: "★", attributes: [
                .foregroundColor: i <= rating ? accent : bg3,
                .font: NSFont.systemFont(ofSize: size),
                .kern: 2.5
            ]))
        }
        return s
    }

    /// Tracked small-caps header style - the ONE header voice app-wide.
    /// (System font, uppercased, letterspaced: reads "engraved label", not
    /// "monospace terminal", which was the generated-UI tell.)
    static func sectionTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text.uppercased(), attributes: [
            .foregroundColor: tx2,
            .font: Theme.captionStrong,
            .kern: 1.4
        ])
    }

    static func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = sectionTitle(text)
        return label
    }
}

/// Five color dots that act as an exclusive filter toggle - click a color to
/// show only that label, click it again to clear. Combines with the star
/// filter (both apply).
final class ColorFilterBar: NSView {
    var onChange: ((Set<Int>) -> Void)?
    private(set) var selected: Set<Int> = []
    private var buttons: [NSButton] = []
    private var hovered: Int?

    init() {
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 24)
        ])
        // Ring-and-gap dots: an 18pt button whose border is the selection
        // ring, with the 12pt color dot inset as a sublayer - selecting
        // draws a ring *around* the dot with breathing room instead of
        // fattening the dot itself. Geometry never changes; only the ring
        // and alpha do.
        // R Y G B P, then Lightroom's grey = "no label" (the to-do pile).
        for label in [1, 2, 3, 4, 5, 0] {
            let b = NSButton(title: "", target: self, action: #selector(tapped(_:)))
            b.isBordered = false
            b.setButtonType(.momentaryChange)
            b.tag = label
            b.wantsLayer = true
            b.layer?.cornerRadius = 9
            let dot = CALayer()
            dot.frame = CGRect(x: 3, y: 3, width: 12, height: 12)
            dot.cornerRadius = 6
            if label == 0 {
                dot.backgroundColor = NSColor(white: 0.42, alpha: 1).cgColor
                dot.borderColor = Theme.line.cgColor
                dot.borderWidth = 1
                b.toolTip = "Show photos with no color label"
            } else {
                dot.backgroundColor = Theme.labelColors[label].cgColor
                let key = label == 5 ? "P" : "\(label + 5)"
                b.toolTip = "Show \(Theme.labelNames[label].lowercased())-labeled (key \(key))"
            }
            b.layer?.addSublayer(dot)
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 18).isActive = true
            b.heightAnchor.constraint(equalToConstant: 18).isActive = true
            stack.addArrangedSubview(b)
            buttons.append(b)
        }
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func tapped(_ sender: NSButton) {
        // Multi-select: each dot toggles; selected colors combine as OR.
        if selected.contains(sender.tag) {
            selected.remove(sender.tag)
        } else {
            selected.insert(sender.tag)
        }
        restyle(animated: true)
        onChange?(selected)
    }

    /// Programmatic clear - does NOT fire onChange.
    func clear() {
        guard !selected.isEmpty else { return }
        selected = []
        restyle(animated: true)
    }

    private func restyle(animated: Bool = false) {
        let apply = {
            for b in self.buttons {
                let on = self.selected.contains(b.tag)
                b.layer?.borderWidth = on ? 1.5 : 0
                b.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
                let target: CGFloat
                if self.selected.isEmpty || on { target = 1.0 }
                else if b.tag == self.hovered { target = 0.7 }
                else { target = 0.35 }
                (animated ? b.animator() : b).alphaValue = target
            }
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                apply()
            }
        } else {
            apply()
        }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = buttons.first { $0.frame.insetBy(dx: -3, dy: -3).contains(convert(p, to: $0.superview)) }?.tag
        if h != hovered { hovered = h; restyle() }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; restyle() }
    }
}

/// The star filter, resolved: five stars and a threshold - exactly like
/// rating itself. Click the 3rd star → show 3★ & up (stars 1–3 light
/// amber); click the same star again → back to everything. Stars are a
/// SCALE, so one threshold beats toggling levels; colors are CATEGORIES,
/// so the dots stay multi-select. Rejects remains its own exclusive pile.
/// Lightroom's rating comparator: at least / exactly / at most.
/// "At most 3★" includes unrated - that's the to-do pile.
enum RatingComparison: Int {
    case atLeast, exactly, atMost
    var glyph: String { ["≥", "=", "≤"][rawValue] }
    var label: String { ["& up", "exactly", "& less"][rawValue] }
    var next: RatingComparison { RatingComparison(rawValue: (rawValue + 1) % 3)! }
}

final class StarFilterBar: NSView {
    /// (minimum stars, or nil = show all; comparison; rejects-only)
    var onChange: ((Int?, RatingComparison, Bool) -> Void)?
    private(set) var threshold: Int?
    private(set) var comparison: RatingComparison = .atLeast
    private(set) var rejectsOnly = false

    private let cmpButton = NSButton(title: "", target: nil, action: nil)
    private var starButtons: [NSButton] = []
    private let rejectsButton = NSButton(title: "", target: nil, action: nil)
    private let rejectsHighlight = NSView()
    private var hoveredStar: Int?

    private let barHeight: CGFloat = 26
    private let inset: CGFloat = 3
    private let starWidth: CGFloat = 22

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg2.cgColor
        layer?.borderColor = Theme.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = barHeight / 2
        layer?.masksToBounds = true
        heightAnchor.constraint(equalToConstant: barHeight).isActive = true

        // The Lightroom comparator: ≥ / = / ≤, click to cycle.
        cmpButton.target = self
        cmpButton.action = #selector(cmpTapped(_:))
        cmpButton.isBordered = false
        cmpButton.setButtonType(.momentaryChange)
        cmpButton.toolTip = "At least / exactly / at most this rating"
        cmpButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cmpButton)
        NSLayoutConstraint.activate([
            cmpButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            cmpButton.widthAnchor.constraint(equalToConstant: 18),
            cmpButton.topAnchor.constraint(equalTo: topAnchor),
            cmpButton.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        var previous: NSView = cmpButton
        for i in 1...5 {
            let b = NSButton(title: "", target: self, action: #selector(starTapped(_:)))
            b.isBordered = false
            b.setButtonType(.momentaryChange)
            b.tag = i
            b.toolTip = "Filter by \(i) star\(i == 1 ? "" : "s")"
            b.translatesAutoresizingMaskIntoConstraints = false
            addSubview(b)
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: starWidth),
                b.topAnchor.constraint(equalTo: topAnchor),
                b.bottomAnchor.constraint(equalTo: bottomAnchor),
                b.leadingAnchor.constraint(equalTo: previous.trailingAnchor,
                                           constant: previous === cmpButton ? 2 : 0)
            ])
            previous = b
            starButtons.append(b)
        }

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.line.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        rejectsHighlight.wantsLayer = true
        rejectsHighlight.layer?.backgroundColor = Theme.accent.cgColor
        rejectsHighlight.layer?.cornerRadius = (barHeight - inset * 2) / 2
        rejectsHighlight.alphaValue = 0
        addSubview(rejectsHighlight)

        rejectsButton.target = self
        rejectsButton.action = #selector(rejectsTapped(_:))
        rejectsButton.isBordered = false
        rejectsButton.setButtonType(.momentaryChange)
        rejectsButton.toolTip = "Show only rejected photos"
        rejectsButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rejectsButton)

        let rejectsWidth = ceil(("Rejects" as NSString).size(withAttributes: [
            .font: Theme.secondaryStrong
        ]).width) + 24
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: starButtons[4].trailingAnchor, constant: 9),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            rejectsButton.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            rejectsButton.widthAnchor.constraint(equalToConstant: rejectsWidth),
            rejectsButton.topAnchor.constraint(equalTo: topAnchor),
            rejectsButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            trailingAnchor.constraint(equalTo: rejectsButton.trailingAnchor)
        ])
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        rejectsHighlight.frame = rejectsButton.frame.insetBy(dx: inset, dy: inset)
    }

    @objc private func starTapped(_ sender: NSButton) {
        threshold = (threshold == sender.tag) ? nil : sender.tag
        rejectsOnly = false
        restyle(animated: true)
        onChange?(threshold, comparison, rejectsOnly)
    }

    @objc private func cmpTapped(_ sender: Any?) {
        comparison = comparison.next
        restyle(animated: true)
        if threshold != nil { onChange?(threshold, comparison, rejectsOnly) }
    }

    @objc private func rejectsTapped(_ sender: NSButton) {
        rejectsOnly.toggle()
        if rejectsOnly { threshold = nil }
        restyle(animated: true)
        onChange?(threshold, comparison, rejectsOnly)
    }

    /// Programmatic reset (filter strip's Show All) - does NOT fire onChange.
    func clear() {
        guard threshold != nil || rejectsOnly else { return }
        threshold = nil
        rejectsOnly = false
        restyle(animated: true)
    }

    private func restyle(animated: Bool = false) {
        // Hover previews the threshold you'd get; the set threshold is the
        // committed state. Both fill stars 1…level (Lightroom fills the run
        // regardless of comparator - the ≥/=/≤ glyph disambiguates).
        let level = hoveredStar ?? threshold ?? 0
        let previewing = hoveredStar != nil && hoveredStar != threshold
        for b in starButtons {
            let filled = !rejectsOnly && b.tag <= level
            let color: NSColor = filled
                ? (previewing ? Theme.accent.withAlphaComponent(0.55) : Theme.accent)
                : Theme.bg3
            b.attributedTitle = NSAttributedString(string: "★", attributes: [
                .foregroundColor: color,
                .font: Theme.body
            ])
        }
        let cmpActive = threshold != nil && !rejectsOnly
        cmpButton.attributedTitle = NSAttributedString(string: comparison.glyph, attributes: [
            .foregroundColor: cmpActive ? Theme.tx0 : Theme.tx2,
            .font: Theme.monoDataStrong
        ])
        (animated ? rejectsHighlight.animator() : rejectsHighlight).alphaValue = rejectsOnly ? 1 : 0
        rejectsButton.attributedTitle = NSAttributedString(string: "Rejects", attributes: [
            .foregroundColor: rejectsOnly ? Theme.accentText : Theme.tx1,
            .font: NSFont.systemFont(ofSize: 11.5, weight: rejectsOnly ? .semibold : .medium)
        ])
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = starButtons.first { $0.frame.contains(p) }?.tag
        if h != hoveredStar { hoveredStar = h; restyle() }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredStar != nil { hoveredStar = nil; restyle() }
    }
}

/// The amber segmented filter control (native NSSegmentedControl can't be
/// tinted like this).
///
/// Design rules this control enforces:
/// - Frame constant, content adapts: every segment's width is measured ONCE
///   at the heaviest font weight it will ever render, then pinned. Selecting
///   a segment can never change layout - the old version re-measured bold
///   titles on click and shoved everything to its right a few pixels.
/// - Selection is a single amber pill that *slides* between segments
///   (0.16s ease-out) instead of teleporting.
/// - Hover brightens a segment's text; nothing moves.
final class FilterBar: NSView {
    var onChange: ((Int) -> Void)?
    private(set) var selectedIndex = 0
    private var buttons: [NSButton] = []
    private let titles: [String]
    private let indicator = NSView()
    private var hovered: Int?

    private let barHeight: CGFloat = 26
    private let inset: CGFloat = 3

    init(titles: [String]) {
        self.titles = titles
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg2.cgColor
        layer?.borderColor = Theme.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = barHeight / 2
        layer?.masksToBounds = true
        heightAnchor.constraint(equalToConstant: barHeight).isActive = true

        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = Theme.accent.cgColor
        indicator.layer?.cornerRadius = (barHeight - inset * 2) / 2
        addSubview(indicator)

        // Fixed widths, measured at the widest weight ever rendered.
        let measureFont = Theme.secondaryStrong
        var previous: NSView?
        for (i, title) in titles.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(tapped(_:)))
            b.isBordered = false
            b.setButtonType(.momentaryChange)
            b.tag = i
            b.translatesAutoresizingMaskIntoConstraints = false
            addSubview(b)
            let w = ceil((title as NSString).size(withAttributes: [.font: measureFont]).width) + 24
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: w),
                b.topAnchor.constraint(equalTo: topAnchor),
                b.bottomAnchor.constraint(equalTo: bottomAnchor),
                b.leadingAnchor.constraint(equalTo: previous?.trailingAnchor ?? leadingAnchor)
            ])
            previous = b
            buttons.append(b)
        }
        if let last = previous {
            trailingAnchor.constraint(equalTo: last.trailingAnchor).isActive = true
        }
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func indicatorFrame() -> NSRect {
        guard buttons.indices.contains(selectedIndex) else { return .zero }
        return buttons[selectedIndex].frame.insetBy(dx: inset, dy: inset)
    }

    override func layout() {
        super.layout()
        indicator.frame = indicatorFrame()
    }

    @objc private func tapped(_ sender: NSButton) {
        guard sender.tag != selectedIndex else { return }
        moveSelection(to: sender.tag)
        onChange?(selectedIndex)
    }

    /// Programmatic selection (filter-strip reset etc.) - does NOT fire
    /// onChange, so callers can't loop.
    func select(_ index: Int) {
        guard buttons.indices.contains(index), index != selectedIndex else { return }
        moveSelection(to: index)
    }

    private func moveSelection(to index: Int) {
        selectedIndex = index
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            indicator.animator().frame = indicatorFrame()
        }
        restyle()
    }

    private func restyle() {
        for b in buttons {
            let on = b.tag == selectedIndex
            let color: NSColor = on ? Theme.accentText
                                    : (b.tag == hovered ? Theme.tx0 : Theme.tx1)
            b.attributedTitle = NSAttributedString(string: titles[b.tag], attributes: [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: 11, weight: on ? .semibold : .medium)
            ])
        }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = buttons.first { $0.frame.contains(p) }?.tag
        if h != hovered { hovered = h; restyle() }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; restyle() }
    }
}

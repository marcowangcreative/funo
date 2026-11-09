import AppKit

/// Flat graphite scroller. A quiet track, a tx-tone knob, brass while the
/// pointer is over it or it is being dragged. No arrows, no overlay pill.
/// Drawing is the scroller's own `draw`; nothing is allocated per scroll tick.
final class GraphiteScroller: NSScroller {
    private var hovering = false
    private var dragging = false
    private var tracking: NSTrackingArea?

    /// Thin enough to sit under a filmstrip without eating the frames.
    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                      scrollerStyle: NSScroller.Style) -> CGFloat {
        8
    }

    override func draw(_ dirtyRect: NSRect) {
        drawKnobSlot(in: bounds, highlight: false)
        drawKnob()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight: Bool) {
        Theme.bg2.setFill()
        slotRect.fill()
    }

    override func drawKnob() {
        let horizontal = bounds.width > bounds.height
        let knob = rect(for: .knob).insetBy(dx: horizontal ? 0 : 1.5, dy: horizontal ? 1.5 : 0)
        guard knob.width > 1, knob.height > 1 else { return }
        (hovering || dragging ? Theme.accent : Theme.tx1.withAlphaComponent(0.8)).setFill()
        knob.fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        needsDisplay = true
        super.mouseDown(with: event)
        dragging = false
        needsDisplay = true
    }
}

/// NSScrollView that installs `GraphiteScroller` and follows the system
/// "show scroll bars" setting. `persistentScroller` keeps a legacy bar on
/// screen whenever the document overflows: the filmstrip is a position
/// indicator, and keyboard culling scrolls it without a gesture, so an
/// overlay bar fades and does not come back.
final class GraphiteScrollView: NSScrollView {
    var persistentScroller = false {
        didSet { applyChrome() }
    }

    private var applying = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyChrome()
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollerPreferenceChanged),
            name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func scrollerPreferenceChanged() { applyChrome() }

    override func tile() {
        super.tile()
        applyChrome()
    }

    private func applyChrome() {
        guard !applying else { return }
        applying = true
        defer { applying = false }
        let style: NSScroller.Style = persistentScroller ? .legacy : NSScroller.preferredScrollerStyle
        if scrollerStyle != style { scrollerStyle = style }
        if autohidesScrollers != true { autohidesScrollers = true }
        if hasVerticalScroller, !(verticalScroller is GraphiteScroller) {
            verticalScroller = GraphiteScroller()
        }
        if hasHorizontalScroller, !(horizontalScroller is GraphiteScroller) {
            horizontalScroller = GraphiteScroller()
        }
    }
}

import AppKit

/// The per-face triage mark: an eye glyph + a rangefinder focus split, drawn in
/// f/uno's own language rather than a borrowed traffic-light dot.
///
/// - Eyes: an open lid (almond + pupil) or a closed lid (a downward curve with
///   lashes) - a fact, not a score.
/// - Focus: a rangefinder split. Two half-strokes that slide into ONE clean
///   line as the face sharpens and break apart as it softens. Full alignment is
///   anchored to the "sharp enough" knee, not a literal 100%, so every real
///   keeper reads clean and the split is reserved for genuinely soft faces.
///
/// Colour reinforces but the SHAPE carries it (alignment = sharp, lid = eyes),
/// so it stays legible small and colourblind-safe. Used both on the frame
/// (exceptions only) and, later, in the faces panel (every face).
final class RangefinderBadgeView: NSView {

    static let badgeSize = NSSize(width: 44, height: 20)

    private var quality: CGFloat = 1     // 0…1 per-face sharpness/quality
    private var blinking = false
    private var squinting = false

    private static let green = NSColor(srgbRed: 0.32, green: 0.74, blue: 0.42, alpha: 1)

    override var isFlipped: Bool { true } // top-left origin: easier glyph maths

    override init(frame: NSRect) {
        super.init(frame: NSRect(origin: frame.origin, size: Self.badgeSize))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(quality: CGFloat, blinking: Bool, squinting: Bool) {
        self.quality = quality
        self.blinking = blinking
        self.squinting = squinting
        needsDisplay = true
    }

    // MARK: - Mappings (shared vocabulary, reusable by the panel)

    /// 0 = fully split (soft), 1 = fully aligned (sharp). Input is the SAME
    /// focus fraction as the info panel's Focus row (real per-face acutance,
    /// never Vision's faceCaptureQuality). Hard knee at the row's "crisp" band:
    /// >= 0.80 is dead-aligned, below it the gap opens toward soft - so the
    /// badge and the Focus row can never disagree.
    static func alignment(forQuality q: CGFloat) -> CGFloat {
        let crisp: CGFloat = 0.80
        if q >= crisp { return 1 }
        return max(0, q / crisp)
    }

    /// Same bands as the Focus row: crisp green, fair amber, soft red.
    static func focusColor(forQuality q: CGFloat) -> NSColor {
        q >= 0.80 ? green : (q >= 0.50 ? Theme.accent : Theme.red)
    }

    static func eyeColor(blinking: Bool, squinting: Bool) -> NSColor {
        blinking ? Theme.red : (squinting ? Theme.accent : green)
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        // Plate
        let plate = bounds.insetBy(dx: 0.5, dy: 0.5)
        let bg = NSBezierPath(roundedRect: plate, xRadius: 5, yRadius: 5)
        Theme.bg1.withAlphaComponent(0.94).setFill(); bg.fill()
        Theme.line.setStroke(); bg.lineWidth = 1; bg.stroke()

        let cy = bounds.midY
        drawEye(centerX: 15, centerY: cy)
        drawSplit(centerX: 32, centerY: cy)
    }

    private func drawEye(centerX: CGFloat, centerY: CGFloat) {
        let color = Self.eyeColor(blinking: blinking, squinting: squinting)
        color.setStroke(); color.setFill()
        let w: CGFloat = 15, h: CGFloat = squinting ? 6 : 9
        let x = centerX - w / 2

        if blinking {
            // Closed lid: a downward curve + three short lashes.
            let lid = NSBezierPath()
            lid.move(to: NSPoint(x: x, y: centerY - 1))
            lid.curve(to: NSPoint(x: x + w, y: centerY - 1),
                      controlPoint1: NSPoint(x: x + w * 0.3, y: centerY + 3.4),
                      controlPoint2: NSPoint(x: x + w * 0.7, y: centerY + 3.4))
            lid.lineWidth = 1.4; lid.lineCapStyle = .round; lid.stroke()
            for f in [0.22, 0.5, 0.78] {
                let lx = x + w * CGFloat(f)
                let lash = NSBezierPath()
                lash.move(to: NSPoint(x: lx, y: centerY + 1.2))
                lash.line(to: NSPoint(x: lx + (f == 0.5 ? 0 : (f < 0.5 ? -1.3 : 1.3)),
                                      y: centerY + 3.4))
                lash.lineWidth = 1.1; lash.lineCapStyle = .round; lash.stroke()
            }
        } else {
            // Open (or squint) lid: an almond with a pupil.
            let eye = NSBezierPath()
            eye.move(to: NSPoint(x: x, y: centerY))
            eye.curve(to: NSPoint(x: x + w, y: centerY),
                      controlPoint1: NSPoint(x: x + w * 0.28, y: centerY - h * 0.6),
                      controlPoint2: NSPoint(x: x + w * 0.72, y: centerY - h * 0.6))
            eye.curve(to: NSPoint(x: x, y: centerY),
                      controlPoint1: NSPoint(x: x + w * 0.72, y: centerY + h * 0.6),
                      controlPoint2: NSPoint(x: x + w * 0.28, y: centerY + h * 0.6))
            eye.lineWidth = 1.3; eye.stroke()
            if !squinting {
                let r: CGFloat = 1.9
                NSBezierPath(ovalIn: NSRect(x: centerX - r, y: centerY - r, width: r * 2, height: r * 2)).fill()
            }
        }
    }

    private func drawSplit(centerX: CGFloat, centerY: CGFloat) {
        let color = Self.focusColor(forQuality: quality)
        color.setStroke()
        let offset = (1 - Self.alignment(forQuality: quality)) * 4.0
        let half: CGFloat = 6.5, gap: CGFloat = 1.4
        let top = NSBezierPath()
        top.move(to: NSPoint(x: centerX - offset, y: centerY - half))
        top.line(to: NSPoint(x: centerX - offset, y: centerY - gap))
        let bot = NSBezierPath()
        bot.move(to: NSPoint(x: centerX + offset, y: centerY + gap))
        bot.line(to: NSPoint(x: centerX + offset, y: centerY + half))
        for p in [top, bot] { p.lineWidth = 1.7; p.lineCapStyle = .round; p.stroke() }
    }
}

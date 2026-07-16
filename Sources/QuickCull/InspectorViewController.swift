import AppKit
import ImageIO

/// Per-channel histogram + clipping stats.
struct HistogramData {
    var r: [Float]
    var g: [Float]
    var b: [Float]
    var highlightPct: Float   // % of pixels with a channel at/near 255
    var shadowPct: Float      // % of pixels with a channel at/near 0
}

/// RGB histogram with clipping indicators — the core "is this exposure
/// recoverable" instrument. Channels overlay with additive blending so
/// overlaps read white (the classic Photoshop/PM look); the blown ends get
/// a red/blue flag when a channel is clipping.
final class HistogramView: NSView {
    var data: HistogramData? { didSet { needsDisplay = true } }
    /// Legacy luminance path (still used by the static inspector column).
    var bins: [Float] = [] { didSet { needsDisplay = true } }

    private let rColor = NSColor(srgbRed: 1.0, green: 0.28, blue: 0.30, alpha: 1)
    private let gColor = NSColor(srgbRed: 0.30, green: 0.92, blue: 0.45, alpha: 1)
    private let bColor = NSColor(srgbRed: 0.36, green: 0.58, blue: 1.0, alpha: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg2.cgColor
        layer?.borderColor = Theme.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let data { drawRGB(data); return }
        drawLuminance()
    }

    private func drawRGB(_ d: HistogramData) {
        let plot = bounds.insetBy(dx: 8, dy: 8)
        let maxBin = max(d.r.max() ?? 0, max(d.g.max() ?? 0, d.b.max() ?? 0))
        guard maxBin > 0 else { return }
        let barWidth = plot.width / CGFloat(d.r.count)

        NSGraphicsContext.current?.compositingOperation = .plusLighter
        for (channel, color) in [(d.r, rColor), (d.g, gColor), (d.b, bColor)] {
            color.withAlphaComponent(0.7).setFill()
            for (i, v) in channel.enumerated() {
                let h = CGFloat(v / maxBin) * plot.height
                guard h > 0 else { continue }
                NSRect(x: plot.minX + CGFloat(i) * barWidth, y: plot.minY,
                       width: max(1, barWidth - 0.5), height: h).fill()
            }
        }
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        // Blown ends flagged. Threshold small so real clipping shows, but
        // not so small every photo lights up.
        if d.shadowPct > 0.1 {
            NSColor(srgbRed: 0.36, green: 0.58, blue: 1, alpha: 0.9).setFill()
            NSRect(x: bounds.minX, y: bounds.minY, width: 3, height: bounds.height).fill()
        }
        if d.highlightPct > 0.1 {
            Theme.red.setFill()
            NSRect(x: bounds.maxX - 3, y: bounds.minY, width: 3, height: bounds.height).fill()
        }
        drawClipText(d)
    }

    private func drawClipText(_ d: HistogramData) {
        func label(_ text: String, _ color: NSColor, rightAligned: Bool) {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: NSFont.monospacedSystemFont(ofSize: 8.5, weight: .semibold)
            ]
            let s = NSAttributedString(string: text, attributes: attrs)
            let size = s.size()
            let x = rightAligned ? bounds.maxX - size.width - 6 : bounds.minX + 6
            s.draw(at: NSPoint(x: x, y: bounds.maxY - size.height - 4))
        }
        if d.shadowPct > 0.1 {
            label(String(format: "▼%.1f%%", d.shadowPct), bColor, rightAligned: false)
        }
        if d.highlightPct > 0.1 {
            label(String(format: "▲%.1f%%", d.highlightPct), rColor, rightAligned: true)
        }
    }

    private func drawLuminance() {
        guard !bins.isEmpty, let maxBin = bins.max(), maxBin > 0 else { return }
        let plot = bounds.insetBy(dx: 8, dy: 8)
        let barWidth = plot.width / CGFloat(bins.count)
        for (i, v) in bins.enumerated() {
            let h = CGFloat(v / maxBin) * plot.height
            let alpha = 0.35 + 0.65 * CGFloat(i) / CGFloat(bins.count)
            Theme.accent.withAlphaComponent(alpha).setFill()
            NSRect(x: plot.minX + CGFloat(i) * barWidth, y: plot.minY,
                   width: max(1, barWidth - 1), height: h).fill()
        }
    }

    static func compute(from image: NSImage) -> [Float] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let w = 128, h = 96
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return [] }
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var bins = [Float](repeating: 0, count: 64)
        for p in 0..<(w * h) {
            let r = Float(pixels[p * 4]), g = Float(pixels[p * 4 + 1]), b = Float(pixels[p * 4 + 2])
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            bins[min(63, Int(lum / 4))] += 1
        }
        return bins
    }

    /// RGB channels + clipping percentages, from an already-decoded preview.
    static func computeRGB(from image: NSImage) -> HistogramData? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = 128, h = 96
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var r = [Float](repeating: 0, count: 64)
        var g = [Float](repeating: 0, count: 64)
        var b = [Float](repeating: 0, count: 64)
        var hi = 0, sh = 0
        let total = w * h
        for p in 0..<total {
            let rr = pixels[p * 4], gg = pixels[p * 4 + 1], bb = pixels[p * 4 + 2]
            r[Int(rr) / 4] += 1
            g[Int(gg) / 4] += 1
            b[Int(bb) / 4] += 1
            let mx = max(rr, max(gg, bb)), mn = min(rr, min(gg, bb))
            if mx >= 250 { hi += 1 }
            if mn <= 5 { sh += 1 }
        }
        return HistogramData(r: r, g: g, b: b,
                             highlightPct: Float(hi) / Float(total) * 100,
                             shadowPct: Float(sh) / Float(total) * 100)
    }
}

/// Right column: selected photo, histogram, EXIF, matching the mockup.
final class InspectorViewController: NSViewController {

    private let thumbView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "—")
    private let subLabel = NSTextField(labelWithString: "")
    private let starsLabel = NSTextField(labelWithString: "")
    private var swatchButtons: [NSButton] = []

    /// Fired when the user edits culling state here, so the grid refreshes.
    var onCullEdited: (() -> Void)?
    private let histogram = HistogramView()
    private let exifStack = NSStackView()
    private let placeholder = NSTextField(labelWithString: "No photo selected")

    private var generation = 0
    private var currentAsset: PhotoAsset?
    private var colorRow: NSStackView?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.bg1.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let leftLine = NSView()
        leftLine.wantsLayer = true
        leftLine.layer?.backgroundColor = Theme.line.cgColor
        leftLine.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(leftLine)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let selectedHeader = Theme.sectionHeader("Selected")

        thumbView.imageScaling = .scaleProportionallyDown
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 8
        thumbView.layer?.masksToBounds = true
        thumbView.layer?.backgroundColor = NSColor.black.cgColor
        thumbView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = Theme.mono(11)
        nameLabel.textColor = Theme.tx0
        nameLabel.lineBreakMode = .byTruncatingMiddle

        subLabel.font = Theme.mono(10)
        subLabel.textColor = Theme.tx2
        subLabel.lineBreakMode = .byTruncatingTail

        starsLabel.attributedStringValue = Theme.stars(0, size: 16)

        // Clickable color swatches — the visible provision for color labels.
        let colorRow = NSStackView()
        colorRow.orientation = .horizontal
        colorRow.spacing = 7
        for label in 1...5 {
            let b = NSButton(title: "", target: self, action: #selector(swatchTapped(_:)))
            b.isBordered = false
            b.setButtonType(.momentaryChange)
            b.tag = label
            b.wantsLayer = true
            b.layer?.cornerRadius = 8
            b.layer?.backgroundColor = Theme.labelColors[label].cgColor
            b.toolTip = "\(Theme.labelNames[label]) label (key \(label + 5))"
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 16).isActive = true
            b.heightAnchor.constraint(equalToConstant: 16).isActive = true
            colorRow.addArrangedSubview(b)
            swatchButtons.append(b)
        }
        self.colorRow = colorRow

        let histoHeader = Theme.sectionHeader("Histogram")
        histogram.translatesAutoresizingMaskIntoConstraints = false

        let exifHeader = Theme.sectionHeader("EXIF")
        exifStack.orientation = .vertical
        exifStack.alignment = .leading
        exifStack.spacing = 0
        exifStack.translatesAutoresizingMaskIntoConstraints = false

        placeholder.font = NSFont.systemFont(ofSize: 12)
        placeholder.textColor = Theme.tx2

        stack.addArrangedSubview(selectedHeader)
        stack.addArrangedSubview(thumbView)
        stack.addArrangedSubview(nameLabel)
        stack.addArrangedSubview(subLabel)
        stack.addArrangedSubview(starsLabel)
        stack.addArrangedSubview(colorRow)
        stack.setCustomSpacing(18, after: colorRow)
        stack.addArrangedSubview(histoHeader)
        stack.addArrangedSubview(histogram)
        stack.setCustomSpacing(18, after: histogram)
        stack.addArrangedSubview(exifHeader)
        stack.addArrangedSubview(exifStack)
        stack.addArrangedSubview(placeholder)

        NSLayoutConstraint.activate([
            leftLine.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            leftLine.topAnchor.constraint(equalTo: view.topAnchor),
            leftLine.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            leftLine.widthAnchor.constraint(equalToConstant: 1),

            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),

            thumbView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            thumbView.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            thumbView.heightAnchor.constraint(equalTo: thumbView.widthAnchor, multiplier: 2.0 / 3.0),

            histogram.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            histogram.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            histogram.heightAnchor.constraint(equalToConstant: 72),

            exifStack.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            exifStack.trailingAnchor.constraint(equalTo: stack.trailingAnchor),

            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor)
        ])
    }

    // MARK: - Content

    func show(_ asset: PhotoAsset?) {
        currentAsset = asset
        generation += 1
        let gen = generation

        guard let asset else {
            placeholder.isHidden = false
            thumbView.image = nil
            nameLabel.stringValue = "—"
            subLabel.stringValue = ""
            starsLabel.attributedStringValue = Theme.stars(0, size: 16)
            restyleSwatches(current: 0)
            histogram.bins = []
            setExifRows([])
            return
        }
        placeholder.isHidden = true
        nameLabel.stringValue = asset.filename
        refreshCullState()

        // File size + dimensions arrive async: attributesOfItem is a stat
        // against the photo's volume, and this runs on every arrow-key
        // selection change. ONE background block (the EXIF read below)
        // gathers both and is the only writer of subLabel — two racing
        // writers was the first version of this fix, and a compile error.
        let pairNote = asset.hasJPEGPair ? " · paired JPEG hidden" : ""
        subLabel.stringValue = asset.hasJPEGPair ? "paired JPEG hidden" : ""

        // Thumbnail + histogram
        ThumbnailLoader.shared.request(asset.url, maxPixel: ThumbnailLoader.thumbnailPixelSize) { [weak self] image in
            guard let self, self.generation == gen else { return }
            self.thumbView.image = image
            guard let image else { return }
            DispatchQueue.global(qos: .utility).async {
                let bins = HistogramView.compute(from: image)
                DispatchQueue.main.async {
                    guard self.generation == gen else { return }
                    self.histogram.bins = bins
                }
            }
        }

        // EXIF (header read only — cheap even for RAW) + file size, one trip.
        let url = asset.url
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let rows = Self.exifRows(for: url)
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
            let sizeText = fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.setExifRows(rows)
                let dims = rows.first(where: { $0.0 == "Size" })?.1
                let parts = [dims, sizeText.isEmpty ? nil : sizeText].compactMap { $0 }
                self.subLabel.stringValue = parts.joined(separator: " · ") + pairNote
            }
        }
    }

    /// Re-render stars/reject/color without re-reading metadata.
    func refreshCullState() {
        guard let asset = currentAsset else { return }
        if RatingsStore.shared.isRejected(asset.id) {
            starsLabel.attributedStringValue = NSAttributedString(string: "✕ rejected", attributes: [
                .foregroundColor: Theme.red,
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
            ])
        } else {
            starsLabel.attributedStringValue = Theme.stars(RatingsStore.shared.rating(for: asset.id), size: 16)
        }
        restyleSwatches(current: RatingsStore.shared.colorLabel(for: asset.id))
    }

    private func restyleSwatches(current: Int) {
        for b in swatchButtons {
            let on = b.tag == current
            b.alphaValue = (current == 0 || on) ? 1.0 : 0.35
            b.layer?.borderWidth = on ? 2 : 0
            b.layer?.borderColor = NSColor.white.cgColor
        }
    }

    @objc private func swatchTapped(_ sender: NSButton) {
        guard let asset = currentAsset else { return }
        let current = RatingsStore.shared.colorLabel(for: asset.id)
        RatingsStore.shared.setColorLabel(current == sender.tag ? 0 : sender.tag, for: asset.id)
        refreshCullState()
        onCullEdited?()
    }

    private func setExifRows(_ rows: [(String, String)]) {
        for sub in exifStack.arrangedSubviews {
            exifStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        for (key, value) in rows {
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false

            let k = NSTextField(labelWithString: key)
            k.font = NSFont.systemFont(ofSize: 11)
            k.textColor = Theme.tx2
            k.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(k)

            let v = NSTextField(labelWithString: value)
            v.font = Theme.mono(10.5)
            v.textColor = Theme.tx1
            v.alignment = .right
            v.lineBreakMode = .byTruncatingHead
            v.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(v)

            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = Theme.line.cgColor
            line.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(line)

            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 24),
                k.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                k.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                v.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                v.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                v.leadingAnchor.constraint(greaterThanOrEqualTo: k.trailingAnchor, constant: 10),
                line.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                line.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                line.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                line.heightAnchor.constraint(equalToConstant: 1)
            ])
            exifStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: exifStack.widthAnchor).isActive = true
        }
    }

    /// Shared with the expanded view's INFO card.
    /// One-line shooting summary for the expanded-view footer:
    /// "1/250   ƒ/2.8   ISO 400   85mm   RF24-70mm F2.8".
    static func exifSummary(for url: URL) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return ""
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        var parts: [String] = []
        if let t = exif?[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            parts.append(t >= 1 ? String(format: "%.1fs", t) : String(format: "1/%.0f", 1 / t))
        }
        if let f = exif?[kCGImagePropertyExifFNumber] as? Double {
            parts.append(String(format: "ƒ/%.1f", f))
        }
        if let isos = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Any], let iso = isos.first {
            parts.append("ISO \(iso)")
        }
        if let fl = exif?[kCGImagePropertyExifFocalLength] as? Double, fl > 0 {
            parts.append(String(format: "%.0fmm", fl))
        }
        if let lens = exif?[kCGImagePropertyExifLensModel] as? String, !lens.isEmpty {
            parts.append(lens)
        }
        return parts.joined(separator: "   ")
    }

    static func exifRows(for url: URL) -> [(String, String)] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return []
        }
        var rows: [(String, String)] = []
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]

        if let model = tiff?[kCGImagePropertyTIFFModel] as? String {
            rows.append(("Camera", model))
        }
        if let lens = exif?[kCGImagePropertyExifLensModel] as? String {
            rows.append(("Lens", lens))
        }
        if let time = exif?[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
            rows.append(("Exposure", time >= 1 ? String(format: "%.1f s", time) : String(format: "1/%.0f s", 1 / time)))
        }
        if let f = exif?[kCGImagePropertyExifFNumber] as? Double {
            rows.append(("Aperture", String(format: "ƒ/%.1f", f)))
        }
        if let isos = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Any], let iso = isos.first {
            rows.append(("ISO", "\(iso)"))
        }
        if let fl = exif?[kCGImagePropertyExifFocalLength] as? Double, fl > 0 {
            var focal = String(format: "%.0f mm", fl)
            if let fl35 = exif?[kCGImagePropertyExifFocalLenIn35mmFilm] as? Double, fl35 > 0,
               abs(fl35 - fl) > 1 {
                focal += String(format: " (%.0f eq)", fl35)
            }
            rows.append(("Focal", focal))
        }
        // The Photo-Mechanic "unusual info" pros scan for — nearly free reads.
        if let bias = exif?[kCGImagePropertyExifExposureBiasValue] as? Double {
            rows.append(("Exp. comp", String(format: "%+.1f EV", bias)))
        }
        if let mode = exif?[kCGImagePropertyExifExposureProgram] as? Int {
            let names = ["—", "Manual", "Program", "Aperture", "Shutter",
                         "Creative", "Action", "Portrait", "Landscape"]
            rows.append(("Mode", mode < names.count ? names[mode] : "—"))
        }
        if let meter = exif?[kCGImagePropertyExifMeteringMode] as? Int {
            let names = ["Unknown", "Average", "Center-weighted", "Spot",
                         "Multi-spot", "Pattern", "Partial"]
            if meter < names.count, meter > 0 { rows.append(("Metering", names[meter])) }
        }
        if let wb = exif?[kCGImagePropertyExifWhiteBalance] as? Int {
            rows.append(("WB", wb == 0 ? "Auto" : "Manual"))
        }
        if let flash = exif?[kCGImagePropertyExifFlash] as? Int {
            rows.append(("Flash", flash & 0x1 != 0 ? "Fired" : "Off"))
        }
        if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            rows.append(("Size", "\(w) × \(h)"))
        }
        if let date = exif?[kCGImagePropertyExifDateTimeOriginal] as? String {
            rows.append(("Captured", date))
        }
        return rows
    }
}

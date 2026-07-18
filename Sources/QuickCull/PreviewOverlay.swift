import AppKit

/// Keeps the photo centered when it's smaller than the viewport -
/// without this, NSScrollView pins the image to the bottom-left and
/// fit-to-window feels broken.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if let doc = documentView {
            if doc.frame.width < rect.width {
                rect.origin.x = (doc.frame.width - rect.width) / 2
            }
            if doc.frame.height < rect.height {
                rect.origin.y = (doc.frame.height - rect.height) / 2
            }
        }
        return rect
    }
}

/// Scroll-document container whose content hangs from the TOP (NSView
/// default is bottom-up, which makes scrollable lists feel upside down).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The zoom stage's document view: draws a CGImage via its backing layer
/// (an NSImageView would fight the window with its intrinsic size - the old
/// v2 bug), reports double-clicks, and pans with mouse drag.
final class StageImageView: NSView {
    var onDoubleClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .trilinear
        layer?.minificationFilter = .trilinear
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setImage(_ cgImage: CGImage?) {
        layer?.contents = cgImage
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            NSCursor.closedHand.push()
        }
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
        super.mouseUp(with: event)
    }

    /// Hand-tool panning.
    override func mouseDragged(with event: NSEvent) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        var origin = clip.bounds.origin
        origin.x -= event.deltaX / scroll.magnification
        origin.y += event.deltaY / scroll.magnification
        clip.setBoundsOrigin(clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }
}

/// One frame in the filmstrip: thumbnail, amber ring when current, color
/// label as a strip along the bottom, stars/reject badge, dimmed when culled.
final class FilmstripItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FilmstripItem")

    private let thumb = NSImageView()
    private let colorStrip = NSView()
    private let badgePlate = NSView()
    private let badge = NSTextField(labelWithString: "")
    private(set) var representedURL: URL?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.layer?.cornerRadius = 4
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = Theme.bg2.cgColor

        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(thumb)

        colorStrip.wantsLayer = true
        colorStrip.layer?.cornerRadius = 2 // reads as a tag on the photo, not frame chrome
        colorStrip.isHidden = true
        colorStrip.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(colorStrip)

        // Rating/reject chip: stars on a dark scrim so they stay legible over
        // any thumbnail (bare gold text vanished on bright/warm frames). The
        // plate hugs the label and hides itself when there's nothing to show.
        badgePlate.wantsLayer = true
        badgePlate.layer?.cornerRadius = 3
        badgePlate.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        badgePlate.isHidden = true
        badgePlate.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(badgePlate)

        badge.font = Theme.secondaryStrong
        badge.translatesAutoresizingMaskIntoConstraints = false
        badgePlate.addSubview(badge)

        NSLayoutConstraint.activate([
            // Gallery mat: content sits 4px inside the cell, so the amber
            // current-frame ring (drawn on the cell edge) and the color-label
            // strip (on the photo's own edge) never touch - the dark gap
            // between them is what kills the amber-on-red clash.
            thumb.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            thumb.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            thumb.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            thumb.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),

            colorStrip.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            colorStrip.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            colorStrip.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            colorStrip.heightAnchor.constraint(equalToConstant: 4),

            badgePlate.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            badgePlate.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            badge.leadingAnchor.constraint(equalTo: badgePlate.leadingAnchor, constant: 5),
            badge.trailingAnchor.constraint(equalTo: badgePlate.trailingAnchor, constant: -5),
            badge.topAnchor.constraint(equalTo: badgePlate.topAnchor, constant: 1),
            badge.bottomAnchor.constraint(equalTo: badgePlate.bottomAnchor, constant: -1)
        ])
    }

    func configure(asset: PhotoAsset, isCurrent: Bool) {
        representedURL = asset.url
        let id = asset.id
        let rejected = RatingsStore.shared.isRejected(id)
        let rating = RatingsStore.shared.rating(for: id)
        let color = RatingsStore.shared.colorLabel(for: id)

        view.alphaValue = rejected ? 0.22 : (isCurrent ? 1.0 : 0.55)
        view.layer?.borderWidth = isCurrent ? 2 : 0
        view.layer?.borderColor = Theme.accent.cgColor

        colorStrip.isHidden = color == 0
        if color > 0 { colorStrip.layer?.backgroundColor = Theme.labelColors[color].cgColor }

        if rejected {
            badge.stringValue = "✕"
            badge.textColor = Theme.red
        } else {
            badge.stringValue = rating > 0 ? String(repeating: "★", count: rating) : ""
            badge.textColor = Theme.accent
        }
        badgePlate.isHidden = badge.stringValue.isEmpty

        let url = asset.url
        if let cached = ThumbnailLoader.shared.cachedImage(for: url, maxPixel: ThumbnailLoader.thumbnailPixelSize) {
            thumb.image = cached
        } else {
            thumb.image = nil
            ThumbnailLoader.shared.request(url, maxPixel: ThumbnailLoader.thumbnailPixelSize) { [weak self] image in
                guard let self, self.representedURL == url else { return }
                self.thumb.image = image
            }
        }
    }
}

/// Full-window preview. Fit-to-window by default; Z / double-click toggles
/// 100%; +/− steps zoom; drag or trackpad pans; pinch zooms. Neighbors
/// pre-decode so arrowing never blanks. The filmstrip spans the ENTIRE
/// A grab handle that resizes the filmstrip: drag up for bigger thumbnails,
/// down for smaller. Clamped by the overlay so it can't swallow the stage.
final class FilmstripResizeHandle: NSView {
    var onDragStart: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?   // cumulative Δ from drag start (up = +)
    var onDragEnd: (() -> Void)?
    private var startY: CGFloat = 0

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }

    override func draw(_ dirtyRect: NSRect) {
        // A visible grab capsule so the affordance reads against the dark
        // filmstrip: rounded bg3 background + a bright grip line.
        let capsule = bounds.insetBy(dx: 0, dy: 3)
        let bg = NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2)
        Theme.bg3.setFill()
        bg.fill()
        Theme.line.setStroke()
        bg.lineWidth = 1
        bg.stroke()
        let grip = NSRect(x: bounds.midX - 14, y: bounds.midY - 1.5, width: 28, height: 3)
        Theme.tx1.setFill()
        NSBezierPath(roundedRect: grip, xRadius: 1.5, yRadius: 1.5).fill()
    }

    var onDoubleClick: (() -> Void)?

    override func mouseDown(with e: NSEvent) { startY = e.locationInWindow.y; onDragStart?() }
    override func mouseDragged(with e: NSEvent) { onDrag?(e.locationInWindow.y - startY) }
    override func mouseUp(with e: NSEvent) {
        onDragEnd?()
        if e.clickCount == 2 { onDoubleClick?() }
    }
}

/// folder - scrollable, current frame auto-centered, scroller as progress.
final class PreviewOverlayView: NSView {

    private let stageScroll = NSScrollView()
    private let stageView = StageImageView()
    private var stageBackdrop: NSView?
    private let infoLabel = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSStackView()
    private let filmstripLayout = NSCollectionViewFlowLayout()
    private let filmstripView = NSCollectionView()
    private let filmstripScroll = NSScrollView()
    private let filmstripHandle = FilmstripResizeHandle()
    private var filmstripHeightConstraint: NSLayoutConstraint!
    private var filmDragStartHeight: CGFloat = 60
    private static let filmMinHeight: CGFloat = 60
    private static let filmMaxHeight: CGFloat = 200

    // Info card (histogram + EXIF) - right rail, above faces, I to toggle.
    private let infoPanel = NSView()
    private let infoHistogram = HistogramView()
    private let infoStack = NSStackView()
    private var infoPanelWidth: NSLayoutConstraint!
    private var infoPanelHeight: NSLayoutConstraint!
    private var stageTrailing: NSLayoutConstraint!
    /// ONE width for every right-rail card - the photo edge never jitters
    /// with face count, and the rail reads as a single instrument column.
    private static let railWidth: CGFloat = 272
    private static let infoMinHeight: CGFloat = 320
    private static let infoPanelFixedWidth: CGFloat = railWidth
    /// User-adjustable info/faces split (drag the rail handle). Persisted.
    private var infoPanelHeightValue: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "QuickCullInfoHeight") as? Double
        return max(320, CGFloat(v ?? 396))
    }()
    private let railHandle = FilmstripResizeHandle()
    private var infoDragStartHeight: CGFloat = 396
    private var infoHeightBeforeCollapse: CGFloat = 396
    private var infoGeneration = 0
    private weak var infoFocusRow: NSView?
    private var showInfoPanel: Bool = {
        UserDefaults.standard.object(forKey: "QuickCullShowInfo") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "QuickCullShowInfo")
    }()

    // Face side panel - vertical, scrollable, Tab to toggle.
    private let facesPanel = NSView()
    private let facesHeaderLabel = NSTextField(labelWithString: "")
    private let facesScroll = NSScrollView()
    private let facesStack = NSStackView()
    private var facesPanelWidth: NSLayoutConstraint!
    private var facesTopToInfo: NSLayoutConstraint?
    private var facesTopToEdge: NSLayoutConstraint?
    private let facesFooterLabel = NSTextField(labelWithString: "")
    private var currentFaces: [FaceInfo] = []
    private var currentFacePairs: [(NSImage, FaceInfo)] = []
    private var lastFacesLayoutSize: NSSize = .zero
    private var showFacesPanel: Bool = {
        UserDefaults.standard.object(forKey: "QuickCullShowFaces") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "QuickCullShowFaces")
    }()

    private var assets: [PhotoAsset] = []
    private var index: Int = 0
    private var atFit = true
    private var fullResLoaded = false
    private var showGeneration = 0

    /// Called when the overlay closes; passes the last-viewed index.
    var onClose: ((Int) -> Void)?
    /// Called whenever a rating/reject/color changes, so the grid can repaint.
    var onCullChanged: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.024, green: 0.024, blue: 0.028, alpha: 0.97).cgColor

        // The photo surround: only the stage backdrop changes with the
        // setting - chrome, labels and panels stay graphite for legibility.
        let stageBackdrop = NSView()
        stageBackdrop.wantsLayer = true
        stageBackdrop.layer?.backgroundColor = Theme.surround.color.cgColor
        stageBackdrop.layer?.cornerRadius = 6
        stageBackdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stageBackdrop)
        self.stageBackdrop = stageBackdrop

        stageScroll.contentView = CenteringClipView()
        stageScroll.hasHorizontalScroller = true
        stageScroll.hasVerticalScroller = true
        stageScroll.autohidesScrollers = true
        stageScroll.drawsBackground = false
        stageScroll.allowsMagnification = true
        stageScroll.minMagnification = 0.01
        stageScroll.maxMagnification = 10
        stageScroll.documentView = stageView
        stageScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stageScroll)

        stageView.onDoubleClick = { [weak self] in self?.toggle100() }

        stageScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollStateChanged),
                                               name: NSView.boundsDidChangeNotification,
                                               object: stageScroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveMagnifyEnded),
                                               name: NSScrollView.didEndLiveMagnifyNotification,
                                               object: stageScroll)

        infoLabel.font = Theme.monoData
        infoLabel.textColor = Theme.tx1
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(infoLabel)

        zoomLabel.font = Theme.monoCaption
        zoomLabel.textColor = Theme.tx2
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(zoomLabel)

        facesFooterLabel.font = Theme.monoCaption
        facesFooterLabel.textColor = Theme.tx2
        facesFooterLabel.maximumNumberOfLines = 2
        facesFooterLabel.translatesAutoresizingMaskIntoConstraints = false
        facesPanel.addSubview(facesFooterLabel)

        hintLabel.orientation = .horizontal
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hintLabel)
        NotificationCenter.default.addObserver(self, selector: #selector(cullModeDidChange),
                                               name: RatingsStore.cullModeChanged, object: nil)
        refreshHintLabel()

        filmstripLayout.scrollDirection = .horizontal
        filmstripLayout.itemSize = NSSize(width: 84, height: 56)
        filmstripLayout.minimumInteritemSpacing = 6
        filmstripLayout.minimumLineSpacing = 6
        filmstripLayout.sectionInset = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)

        filmstripView.collectionViewLayout = filmstripLayout
        filmstripView.dataSource = self
        filmstripView.delegate = self
        filmstripView.isSelectable = true
        filmstripView.allowsMultipleSelection = false
        filmstripView.backgroundColors = [.clear]
        filmstripView.register(FilmstripItem.self, forItemWithIdentifier: FilmstripItem.identifier)

        filmstripScroll.documentView = filmstripView
        filmstripScroll.drawsBackground = false
        filmstripScroll.hasHorizontalScroller = true
        filmstripScroll.hasVerticalScroller = false
        filmstripScroll.autohidesScrollers = true
        filmstripScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(filmstripScroll)

        filmstripHandle.translatesAutoresizingMaskIntoConstraints = false
        filmstripHandle.onDragStart = { [weak self] in
            self?.filmDragStartHeight = self?.filmstripHeightConstraint.constant ?? Self.filmMinHeight
        }
        filmstripHandle.onDrag = { [weak self] delta in
            guard let self else { return }
            let h = max(Self.filmMinHeight, min(self.maxFilmstripHeight(), self.filmDragStartHeight + delta))
            self.setFilmstripHeight(h)
        }
        filmstripHandle.onDragEnd = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Double(self.filmstripHeightConstraint.constant),
                                      forKey: "QuickCullFilmstripHeight")
        }
        addSubview(filmstripHandle)

        // Info card: histogram + shooting data, top of the right rail.
        infoPanel.wantsLayer = true
        infoPanel.layer?.backgroundColor = Theme.bg1.withAlphaComponent(0.92).cgColor
        infoPanel.layer?.cornerRadius = 10
        infoPanel.layer?.borderColor = Theme.line.cgColor
        infoPanel.layer?.borderWidth = 1
        infoPanel.layer?.masksToBounds = true // collapses cleanly to height 0
        infoPanel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(infoPanel)
        infoPanelWidth = infoPanel.widthAnchor.constraint(equalToConstant: 0)
        infoPanelWidth.isActive = true
        // Fixed height when shown: the faces card below budgets against a
        // KNOWN number instead of an intrinsic one (unsatisfiable-constraint
        // roulette was making views vanish on resize).
        infoPanelHeight = infoPanel.heightAnchor.constraint(equalToConstant: 0)
        infoPanelHeight.isActive = true

        let infoHeader = NSTextField(labelWithString: "")
        infoHeader.attributedStringValue = Theme.sectionTitle("Info")
        infoHeader.translatesAutoresizingMaskIntoConstraints = false
        infoPanel.addSubview(infoHeader)

        // Rating/color are NOT shown here - the filmstrip frame already
        // carries them. The info card is pure instrument: histogram + data.
        infoHistogram.translatesAutoresizingMaskIntoConstraints = false
        infoPanel.addSubview(infoHistogram)

        infoStack.orientation = .vertical
        infoStack.spacing = 3
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        infoPanel.addSubview(infoStack)

        NSLayoutConstraint.activate([
            infoPanel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            infoPanel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            infoHeader.topAnchor.constraint(equalTo: infoPanel.topAnchor, constant: 9),
            infoHeader.leadingAnchor.constraint(equalTo: infoPanel.leadingAnchor, constant: 10),
            infoHistogram.topAnchor.constraint(equalTo: infoHeader.bottomAnchor, constant: 10),
            infoHistogram.leadingAnchor.constraint(equalTo: infoPanel.leadingAnchor, constant: 9),
            infoHistogram.trailingAnchor.constraint(equalTo: infoPanel.trailingAnchor, constant: -9),
            infoHistogram.heightAnchor.constraint(equalToConstant: 92),
            infoStack.topAnchor.constraint(equalTo: infoHistogram.bottomAnchor, constant: 8),
            infoStack.leadingAnchor.constraint(equalTo: infoPanel.leadingAnchor, constant: 10),
            infoStack.trailingAnchor.constraint(equalTo: infoPanel.trailingAnchor, constant: -10),
            infoStack.bottomAnchor.constraint(lessThanOrEqualTo: infoPanel.bottomAnchor, constant: -10)
        ])

        // Drag handle straddling the info/faces seam - rebalance the rail.
        railHandle.translatesAutoresizingMaskIntoConstraints = false
        railHandle.onDragStart = { [weak self] in
            self?.infoDragStartHeight = self?.infoPanelHeightValue ?? 396
        }
        railHandle.onDrag = { [weak self] delta in
            guard let self else { return }
            // Handle convention: up = +delta. Dragging DOWN grows the info
            // card (it's on top), so subtract.
            let h = max(Self.infoMinHeight, min(self.maxInfoHeight(), self.infoDragStartHeight - delta))
            self.infoPanelHeightValue = h
            self.infoPanelHeight.constant = h
            self.refreshInfoPanel()
            self.layoutFacesGrid()
        }
        railHandle.onDragEnd = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Double(self.infoPanelHeightValue), forKey: "QuickCullInfoHeight")
        }
        // Double-click the seam: give faces every pixel (info shrinks to its
        // minimum). Double-click again: restore the previous balance - the
        // macOS split-divider convention.
        railHandle.onDoubleClick = { [weak self] in
            guard let self else { return }
            let minH = Self.infoMinHeight
            if self.infoPanelHeightValue > minH + 1 {
                self.infoHeightBeforeCollapse = self.infoPanelHeightValue
                self.infoPanelHeightValue = minH
            } else {
                self.infoPanelHeightValue = min(self.maxInfoHeight(),
                                                max(self.infoHeightBeforeCollapse, minH))
            }
            self.infoPanelHeight.constant = self.infoPanelHeightValue
            UserDefaults.standard.set(Double(self.infoPanelHeightValue), forKey: "QuickCullInfoHeight")
            self.refreshInfoPanel()
            self.layoutFacesGrid()
        }
        railHandle.isHidden = true
        addSubview(railHandle)
        NSLayoutConstraint.activate([
            railHandle.centerXAnchor.constraint(equalTo: infoPanel.centerXAnchor),
            railHandle.centerYAnchor.constraint(equalTo: infoPanel.bottomAnchor, constant: 5),
            railHandle.widthAnchor.constraint(equalToConstant: 50),
            railHandle.heightAnchor.constraint(equalToConstant: 14)
        ])

        // Face side panel: right edge, where landscape photos have room to
        // spare. A contained card, not floating heads on black.
        facesPanel.wantsLayer = true
        facesPanel.layer?.backgroundColor = Theme.bg1.withAlphaComponent(0.92).cgColor
        facesPanel.layer?.cornerRadius = 10
        facesPanel.layer?.borderColor = Theme.line.cgColor
        facesPanel.layer?.borderWidth = 1
        facesPanel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(facesPanel)
        facesPanelWidth = facesPanel.widthAnchor.constraint(equalToConstant: 0)
        // Faces card hangs below the info card when it's shown, else from the top.
        facesTopToInfo = facesPanel.topAnchor.constraint(equalTo: infoPanel.bottomAnchor, constant: 10)
        facesTopToEdge = facesPanel.topAnchor.constraint(equalTo: topAnchor, constant: 12)
        (showInfoPanel ? facesTopToInfo : facesTopToEdge)?.isActive = true

        facesHeaderLabel.attributedStringValue = Theme.sectionTitle("Faces")
        facesHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        facesPanel.addSubview(facesHeaderLabel)

        facesStack.orientation = .vertical
        facesStack.spacing = 6
        facesStack.translatesAutoresizingMaskIntoConstraints = false
        let facesDoc = FlippedView()
        facesDoc.translatesAutoresizingMaskIntoConstraints = false
        facesDoc.addSubview(facesStack)
        facesScroll.documentView = facesDoc
        facesScroll.drawsBackground = false
        facesScroll.hasVerticalScroller = true
        facesScroll.autohidesScrollers = true
        facesScroll.translatesAutoresizingMaskIntoConstraints = false
        facesPanel.addSubview(facesScroll)

        NSLayoutConstraint.activate([
            facesHeaderLabel.topAnchor.constraint(equalTo: facesPanel.topAnchor, constant: 9),
            facesHeaderLabel.leadingAnchor.constraint(equalTo: facesPanel.leadingAnchor, constant: 10),
            facesScroll.topAnchor.constraint(equalTo: facesHeaderLabel.bottomAnchor, constant: 8),
            facesScroll.leadingAnchor.constraint(equalTo: facesPanel.leadingAnchor, constant: 9),
            facesScroll.trailingAnchor.constraint(equalTo: facesPanel.trailingAnchor, constant: -9),
            facesScroll.bottomAnchor.constraint(equalTo: facesFooterLabel.topAnchor, constant: -8),
            facesFooterLabel.leadingAnchor.constraint(equalTo: facesPanel.leadingAnchor, constant: 10),
            facesFooterLabel.trailingAnchor.constraint(lessThanOrEqualTo: facesPanel.trailingAnchor, constant: -10),
            facesFooterLabel.bottomAnchor.constraint(equalTo: facesPanel.bottomAnchor, constant: -9),
            facesStack.topAnchor.constraint(equalTo: facesDoc.topAnchor),
            facesStack.leadingAnchor.constraint(equalTo: facesDoc.leadingAnchor),
            facesStack.trailingAnchor.constraint(lessThanOrEqualTo: facesDoc.trailingAnchor),
            facesStack.bottomAnchor.constraint(equalTo: facesDoc.bottomAnchor),
            facesDoc.widthAnchor.constraint(equalTo: facesScroll.contentView.widthAnchor)
        ])

        // Footer band: a real bar (bg1 + top hairline) like the grid's
        // window footer - filename + exposure sits IN it, above the filmstrip.
        let footerBand = NSView()
        footerBand.wantsLayer = true
        footerBand.layer?.backgroundColor = Theme.bg1.cgColor
        footerBand.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footerBand, positioned: .below, relativeTo: infoLabel)
        let footerLine = NSView()
        footerLine.wantsLayer = true
        footerLine.layer?.backgroundColor = Theme.line.cgColor
        footerLine.translatesAutoresizingMaskIntoConstraints = false
        footerBand.addSubview(footerLine)

        stageTrailing = stageScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        NSLayoutConstraint.activate([
            // Layout, bottom → top: footer band (flush bottom) · filmstrip ·
            // resize handle (in the gap, never over a thumbnail) · stage.
            footerBand.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerBand.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerBand.bottomAnchor.constraint(equalTo: bottomAnchor),
            footerBand.heightAnchor.constraint(equalToConstant: 30),
            footerLine.leadingAnchor.constraint(equalTo: footerBand.leadingAnchor),
            footerLine.trailingAnchor.constraint(equalTo: footerBand.trailingAnchor),
            footerLine.topAnchor.constraint(equalTo: footerBand.topAnchor),
            footerLine.heightAnchor.constraint(equalToConstant: 1),

            // filename + exposure (left) · zoom % · hints (right), IN the band.
            infoLabel.leadingAnchor.constraint(equalTo: footerBand.leadingAnchor, constant: 14),
            infoLabel.centerYAnchor.constraint(equalTo: footerBand.centerYAnchor),
            infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: zoomLabel.leadingAnchor, constant: -14),
            zoomLabel.trailingAnchor.constraint(equalTo: hintLabel.leadingAnchor, constant: -16),
            zoomLabel.centerYAnchor.constraint(equalTo: footerBand.centerYAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: footerBand.trailingAnchor, constant: -14),
            hintLabel.centerYAnchor.constraint(equalTo: footerBand.centerYAnchor),

            filmstripScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            filmstripScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            filmstripScroll.bottomAnchor.constraint(equalTo: footerBand.topAnchor, constant: -6),

            // Resize handle: floats in the empty gap ABOVE the filmstrip
            // (4px clear of the top thumbnail edge) - grab it to size thumbs.
            filmstripHandle.centerXAnchor.constraint(equalTo: centerXAnchor),
            filmstripHandle.bottomAnchor.constraint(equalTo: filmstripScroll.topAnchor, constant: -4),
            filmstripHandle.widthAnchor.constraint(equalToConstant: 50),
            filmstripHandle.heightAnchor.constraint(equalToConstant: 16),

            stageScroll.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stageScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stageTrailing,
            stageScroll.bottomAnchor.constraint(equalTo: filmstripHandle.topAnchor, constant: -4),

            stageBackdrop.topAnchor.constraint(equalTo: stageScroll.topAnchor),
            stageBackdrop.leadingAnchor.constraint(equalTo: stageScroll.leadingAnchor),
            stageBackdrop.trailingAnchor.constraint(equalTo: stageScroll.trailingAnchor),
            stageBackdrop.bottomAnchor.constraint(equalTo: stageScroll.bottomAnchor),

            facesPanel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            facesPanel.bottomAnchor.constraint(equalTo: filmstripHandle.topAnchor, constant: -4),
            facesPanelWidth
        ])

        // Restore the user's saved filmstrip size (bigger thumbnails stick),
        // clamped to what actually fits this window.
        let saved = UserDefaults.standard.object(forKey: "QuickCullFilmstripHeight") as? Double
        let startHeight = max(Self.filmMinHeight, min(maxFilmstripHeight(), CGFloat(saved ?? 60)))
        filmstripHeightConstraint = filmstripScroll.heightAnchor.constraint(equalToConstant: startHeight)
        filmstripHeightConstraint.isActive = true
        applyFilmstripItemSize(for: startHeight)
    }

    /// The tallest the filmstrip may grow while still leaving the stage a
    /// usable minimum - so its fixed height can NEVER over-demand and shove
    /// the window past the screen.
    private func maxFilmstripHeight() -> CGFloat {
        let reserved: CGFloat = 30 + 24 + 220 // footer + handle gap + min stage
        let fit = bounds.height - reserved
        return max(Self.filmMinHeight, min(Self.filmMaxHeight, fit))
    }

    /// Filmstrip height ↔ thumbnail size, kept in lockstep (3:2 frames).
    private func setFilmstripHeight(_ h: CGFloat) {
        filmstripHeightConstraint.constant = h
        applyFilmstripItemSize(for: h)
        // Re-center the current frame at the new size.
        guard index >= 0, index < assets.count else { return }
        let target = IndexPath(item: index, section: 0)
        filmstripView.scrollToItems(at: [target], scrollPosition: .centeredHorizontally)
    }

    private func applyFilmstripItemSize(for height: CGFloat) {
        let itemH = height - 4
        filmstripLayout.itemSize = NSSize(width: (itemH * 1.5).rounded(), height: itemH.rounded())
        filmstripLayout.invalidateLayout()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func present(assets: [PhotoAsset], startIndex: Int) {
        self.assets = assets
        self.index = max(0, min(startIndex, assets.count - 1))
        filmstripView.reloadData()
        showCurrent()
    }

    // MARK: - Image display

    private func showCurrent() {
        guard index >= 0, index < assets.count else { return }
        showGeneration += 1
        let gen = showGeneration
        let asset = assets[index]
        let url = asset.url
        fullResLoaded = false
        // Navigation always lands at FIT. Without this, arriving on a photo
        // whose preview was evicted (full-res decodes are huge and purge the
        // cache) while zoomed left the async display blocked by the atFit
        // guard - the stage kept the OLD photo while the footer, filmstrip
        // and info panel advanced. The guard still protects a zoom made
        // AFTER landing here; it just can't veto the arrival itself.
        atFit = true

        // Show whatever is already decoded (grid thumb), then sharpen.
        if let preview = ThumbnailLoader.shared.cachedImage(for: url, maxPixel: ThumbnailLoader.previewPixelSize) {
            display(preview)
        } else {
            if let thumb = ThumbnailLoader.shared.cachedImage(for: url, maxPixel: ThumbnailLoader.thumbnailPixelSize) {
                display(thumb)
            }
            ThumbnailLoader.shared.request(url, maxPixel: ThumbnailLoader.previewPixelSize) { [weak self] image in
                guard let self, self.showGeneration == gen, self.atFit, !self.fullResLoaded, let image else { return }
                self.display(image)
            }
        }

        // Footer: filename + position now, exposure summary async (a tiny
        // metadata read that must never block the frame swap).
        let position = "\(index + 1) / \(assets.count)"
        infoLabel.attributedStringValue = Self.footerLine(filename: asset.filename, parts: [], position: position)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let parts = InspectorViewController.exifSummaryParts(for: url)
            DispatchQueue.main.async {
                guard let self, self.showGeneration == gen else { return }
                self.infoLabel.attributedStringValue = Self.footerLine(
                    filename: asset.filename, parts: parts, position: position)
            }
        }
        FaceAnalyzer.shared.prioritize(asset.id) // scan what's on screen first
        scheduleFacesRefresh()
        refreshInfoPanel()
        refreshFilmstrip()

        // Keep the shooting rhythm: neighbors decode while you look at this
        // one. ±2 (immediate neighbors first) covers fast arrow-key paging
        // so the sharp preview is already waiting - no lower-res flash.
        for offset in [1, -1, 2, -2] {
            let n = index + offset
            if n >= 0, n < assets.count {
                ThumbnailLoader.shared.prefetch(assets[n].url, maxPixel: ThumbnailLoader.previewPixelSize)
            }
        }
    }

    private func display(_ image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        stageView.setImage(cg)
        stageView.frame = NSRect(x: 0, y: 0, width: cg.width, height: cg.height)
        fitToWindow()
    }

    // MARK: - Zoom

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }

    private func fitToWindow() {
        atFit = true
        stageScroll.magnify(toFit: stageView.frame)
        updateZoomLabel()
    }

    /// Swap in the native-resolution decode before zooming past the preview.
    private func ensureFullRes(_ then: @escaping () -> Void) {
        if fullResLoaded { then(); return }
        let gen = showGeneration
        let url = assets[index].url
        zoomLabel.stringValue = "loading full res…"
        ThumbnailLoader.shared.request(url, maxPixel: ThumbnailLoader.fullPixelSize) { [weak self] image in
            guard let self, self.showGeneration == gen else { return }
            defer { then() }
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let center = self.visibleCenterFraction()
            let oldWidth = self.stageView.frame.width
            let magnification = self.stageScroll.magnification
            self.stageView.setImage(cg)
            self.stageView.frame = NSRect(x: 0, y: 0, width: cg.width, height: cg.height)
            if oldWidth > 0 {
                // Keep the on-screen size identical across the swap.
                let compensated = magnification * oldWidth / CGFloat(cg.width)
                let target = NSPoint(x: CGFloat(cg.width) * center.x, y: CGFloat(cg.height) * center.y)
                self.stageScroll.setMagnification(compensated, centeredAt: target)
            }
            self.fullResLoaded = true
        }
    }

    private func zoom(to magnification: CGFloat) {
        atFit = false
        let clamped = max(stageScroll.minMagnification, min(stageScroll.maxMagnification, magnification))
        let doc = stageView.frame
        let visible = stageScroll.contentView.documentVisibleRect
        let center = NSPoint(x: min(max(visible.midX, 0), doc.width),
                             y: min(max(visible.midY, 0), doc.height))
        stageScroll.setMagnification(clamped, centeredAt: center)
        updateZoomLabel()
    }

    private func zoomStep(_ factor: CGFloat) {
        ensureFullRes { [weak self] in
            guard let self else { return }
            self.zoom(to: self.stageScroll.magnification * factor)
        }
    }

    private func toggle100() {
        if !atFit {
            fitToWindow()
            return
        }
        ensureFullRes { [weak self] in
            guard let self else { return }
            self.zoom(to: 1.0 / self.backingScale) // true pixel-for-pixel
        }
    }

    private func updateZoomLabel() {
        let percent = Int((stageScroll.magnification * backingScale * 100).rounded())
        zoomLabel.stringValue = atFit ? "FIT \(percent)%" : "\(percent)%"
    }

    @objc private func scrollStateChanged(_ note: Notification) {
        updateZoomLabel()
    }

    @objc private func liveMagnifyEnded(_ note: Notification) {
        atFit = false
        // Pinching past the preview resolution? Pull in the full decode.
        if stageScroll.magnification * backingScale > 1 || !fullResLoaded {
            ensureFullRes { [weak self] in self?.updateZoomLabel() }
        }
        updateZoomLabel()
    }

    /// Where the user is currently looking, as a fraction of the document.
    private func visibleCenterFraction() -> NSPoint {
        let doc = stageView.frame
        guard doc.width > 0, doc.height > 0 else { return NSPoint(x: 0.5, y: 0.5) }
        let visible = stageScroll.contentView.documentVisibleRect
        return NSPoint(x: max(0, min(1, visible.midX / doc.width)),
                       y: max(0, min(1, visible.midY / doc.height)))
    }

    // MARK: - Filmstrip

    /// Restyle visible cells and keep the current frame centered. Cell reuse
    /// makes this cheap even for multi-thousand-photo folders.
    private func refreshFilmstrip() {
        guard !assets.isEmpty else { return }
        for ip in filmstripView.indexPathsForVisibleItems() {
            guard ip.item < assets.count,
                  let item = filmstripView.item(at: ip) as? FilmstripItem else { continue }
            item.configure(asset: assets[ip.item], isCurrent: ip.item == index)
        }
        // Right after present() the strip hasn't been laid out yet, so an
        // immediate scroll silently no-ops and the strip sits at the start
        // of the roll. Center on the NEXT runloop pass, after layout, then
        // restyle whatever scrolled into view.
        let target = IndexPath(item: index, section: 0)
        DispatchQueue.main.async { [weak self] in
            guard let self, target.item < self.assets.count else { return }
            self.filmstripView.layoutSubtreeIfNeeded()
            self.filmstripView.scrollToItems(at: [target], scrollPosition: .centeredHorizontally)
            for ip in self.filmstripView.indexPathsForVisibleItems() {
                guard ip.item < self.assets.count,
                      let item = self.filmstripView.item(at: ip) as? FilmstripItem else { continue }
                item.configure(asset: self.assets[ip.item], isCurrent: ip.item == self.index)
            }
        }
    }

    // MARK: - Culling state

    /// Cull state lives on the filmstrip frame (and the grid) - the info
    /// card no longer echoes it. Kept as a hook the cull-change path calls.
    /// A face analysis landed while the preview is open.
    func noteFaceResult(for id: String) {
        guard index < assets.count, assets[index].id == id else { return }
        // If a debounced refresh is already queued, let it do the work.
        if facesRefreshTimer?.isValid != true { rebuildFacesRow() }
        // Faces just landed → re-score focus on the subject, not the frame.
        refreshInfoPanel()
    }

    /// Debounce: while the user is flying through frames with the arrow keys,
    /// the panel holds its last layout (slightly dimmed) instead of tearing
    /// down and rebuilding per keystroke - that rebuild was the UI flashing.
    private var facesRefreshTimer: Timer?

    private func scheduleFacesRefresh() {
        if !facesPanel.isHidden { facesPanel.alphaValue = 0.35 }
        facesRefreshTimer?.invalidate()
        facesRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.28, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.facesPanel.alphaValue = 1
            self.rebuildFacesRow()
        }
    }

    // MARK: - Rail panels - F faces · I info · Tab both

    private func setFacesPanel(_ shown: Bool) {
        showFacesPanel = shown
        // The panel IS the switch: opening it powers the analysis engine
        // (and kicks a sweep of this folder), closing it stops all scanning.
        FaceAnalyzer.shared.isEnabled = shown
        if shown {
            FaceAnalyzer.shared.analyzeFolder(assets)
            if index < assets.count {
                FaceAnalyzer.shared.prioritize(assets[index].id)
            }
        }
        rebuildFacesRow()
    }

    private func setInfoPanel(_ shown: Bool) {
        showInfoPanel = shown
        UserDefaults.standard.set(shown, forKey: "QuickCullShowInfo")
        facesTopToInfo?.isActive = false
        facesTopToEdge?.isActive = false
        (shown ? facesTopToInfo : facesTopToEdge)?.isActive = true
        refreshInfoPanel()
        layoutFacesGrid() // re-budget faces against the new rail height
    }

    private func toggleFacesPanel() { setFacesPanel(!showFacesPanel) }
    private func toggleInfoPanel()  { setInfoPanel(!showInfoPanel) }

    /// Tab: show/hide the WHOLE rail (both cards) at once. If either is up,
    /// hide both; otherwise bring both back.
    private func toggleRail() {
        let show = !(showInfoPanel || showFacesPanel)
        setInfoPanel(show)
        setFacesPanel(show)
    }

    /// Tallest the info card may grow while faces keeps a usable minimum.
    private func maxInfoHeight() -> CGFloat {
        max(Self.infoMinHeight, bounds.height - 342) // reserve faces + filmstrip + footer
    }

    /// The rail handle only exists when BOTH cards are on screen and there's
    /// real room to rebalance - otherwise it'd be a dead grip.
    private func updateRailHandle() {
        let bothVisible = !infoPanel.isHidden && !facesPanel.isHidden
        let hasRange = maxInfoHeight() - Self.infoMinHeight > 40
        railHandle.isHidden = !(bothVisible && hasRange)
    }

    /// Photo stage clears whichever right-rail card is widest.
    private func updateStageRail() {
        let infoWidth = infoPanel.isHidden ? 0 : infoPanelWidth.constant
        let facesWidth = facesPanel.isHidden ? 0 : facesPanelWidth.constant
        let rail = max(infoWidth, facesWidth)
        stageTrailing.constant = rail > 0 ? -(rail + 18) : -10
        updateRailHandle()
    }

    private func refreshInfoPanel() {
        for sub in infoStack.arrangedSubviews {
            infoStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        infoGeneration += 1
        let gen = infoGeneration
        infoFocusRow = nil
        guard showInfoPanel, index < assets.count, bounds.width >= 780, bounds.height >= 560 else {
            infoPanelWidth.constant = 0
            infoPanelHeight.constant = 0
            infoPanel.isHidden = true
            updateStageRail()
            return
        }
        infoPanel.isHidden = false
        infoPanelWidth.constant = Self.infoPanelFixedWidth
        infoPanelHeightValue = max(Self.infoMinHeight, min(maxInfoHeight(), infoPanelHeightValue))
        infoPanelHeight.constant = infoPanelHeightValue
        updateStageRail()
        let asset = assets[index]

        // Rows that fit the current card height (leave one slot for Focus).
        let rowBudget = max(4, Int((infoPanelHeightValue - 180) / 17) - 1)

        // RGB histogram + clipping from whatever's already decoded - never a
        // new card read.
        if let image = ThumbnailLoader.shared.cachedImage(for: asset.url, maxPixel: ThumbnailLoader.thumbnailPixelSize)
            ?? ThumbnailLoader.shared.cachedImage(for: asset.url, maxPixel: ThumbnailLoader.previewPixelSize) {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let data = HistogramView.computeRGB(from: image)
                DispatchQueue.main.async {
                    guard let self, self.infoGeneration == gen else { return }
                    self.infoHistogram.data = data
                }
            }
        } else {
            infoHistogram.data = nil
        }

        let url = asset.url
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var rows = InspectorViewController.exifRows(for: url)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil {
                rows.append(("File", ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
            }
            DispatchQueue.main.async {
                guard let self, self.infoGeneration == gen else { return }
                for (key, value) in rows.prefix(rowBudget) {
                    self.infoStack.addArrangedSubview(self.infoRow(key, value))
                }
            }
        }

        // Focus/sharpness, pinned to the top of the list once it's scored.
        SharpnessAnalyzer.shared.score(for: asset) { [weak self] acutance in
            guard let self, self.infoGeneration == gen, let acutance else { return }
            let f = SharpnessAnalyzer.focusFraction(acutance)
            // Color-coded so focus quality reads at a glance - and the tint
            // advertises the metric exists: >=80% green, >=50% amber, else red.
            let word: String
            let tint: NSColor
            if f >= 0.80 { word = "crisp"; tint = NSColor(srgbRed: 0.32, green: 0.74, blue: 0.42, alpha: 1) }
            else if f >= 0.50 { word = "fair"; tint = Theme.accent }
            else { word = "soft"; tint = Theme.red }
            let row = self.infoRow("Focus", "\(Int(f * 100))%  \(word)", valueColor: tint)
            self.infoStack.insertArrangedSubview(row, at: 0)
            self.infoFocusRow = row
        }

    }

    /// The Leica info-card pattern: dim key, bright value, same size, same
    /// line. "S" whispers, "1/175" speaks. Filename and position sit dim at
    /// the ends; the exposure numbers own the middle.
    private static func footerLine(filename: String, parts: [(String, String)], position: String) -> NSAttributedString {
        let dim: [NSAttributedString.Key: Any] = [.font: Theme.monoData, .foregroundColor: Theme.tx2]
        let bright: [NSAttributedString.Key: Any] = [.font: Theme.monoDataStrong, .foregroundColor: Theme.tx1]
        let line = NSMutableAttributedString(string: filename, attributes: dim)
        for (key, value) in parts {
            line.append(NSAttributedString(string: "      ", attributes: dim))
            if !key.isEmpty {
                line.append(NSAttributedString(string: key + " ", attributes: dim))
            }
            line.append(NSAttributedString(string: value, attributes: bright))
        }
        line.append(NSAttributedString(string: "      " + position, attributes: dim))
        return line
    }

    private func infoRow(_ key: String, _ value: String, valueColor: NSColor = Theme.tx0) -> NSView {
        let k = NSTextField(labelWithString: "")
        // Engraved-key styling: uppercase, mono, letterspaced, dim - the
        // label recedes so the value (bright mono) carries the line.
        k.attributedStringValue = NSAttributedString(string: key.uppercased(), attributes: [
            .font: Theme.monoEyebrow,
            .foregroundColor: Theme.tx2,
            .kern: 0.8
        ])
        k.setContentHuggingPriority(.required, for: .horizontal)
        let v = NSTextField(labelWithString: value)
        v.font = Theme.monoData
        v.textColor = valueColor
        v.alignment = .right
        v.lineBreakMode = .byTruncatingHead
        let row = NSStackView(views: [k, v])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.infoPanelFixedWidth - 20).isActive = true
        return row
    }

    private func rebuildFacesRow() {
        currentFaces = []
        currentFacePairs = []
        layoutFacesGrid()
        guard showFacesPanel, FaceAnalyzer.shared.isEnabled, index < assets.count else { return }
        let gen = showGeneration
        FaceCropper.shared.crops(for: assets[index], maxFaces: 40) { [weak self] pairs in
            guard let self, self.showGeneration == gen, !pairs.isEmpty else { return }
            self.currentFacePairs = pairs
            self.currentFaces = pairs.map { $0.1 }
            self.layoutFacesGrid()
        }
    }

    /// Size the face card to the window: largest crops that fit the height
    /// without scrolling, columns capped by a width budget, hidden entirely
    /// when the window is too narrow to share (photo always wins).
    private func layoutFacesGrid() {
        for sub in facesStack.arrangedSubviews {
            facesStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        let pairs = currentFacePairs
        guard showFacesPanel, FaceAnalyzer.shared.isEnabled, bounds.width >= 780 else {
            facesPanelWidth.constant = 0
            facesPanel.isHidden = true
            updateStageRail()
            return
        }

        // No crops yet: distinguish "still scanning" from "won't scan here"
        // (memory card) from "scanned, no faces" - never a mystery.
        if pairs.isEmpty {
            if index < assets.count, FaceAnalyzer.shared.result(for: assets[index].id) == nil {
                facesHeaderLabel.attributedStringValue = Theme.sectionTitle("Faces")
                if FileOps.isMemoryCard(assets[index].url) {
                    facesFooterLabel.stringValue = "scans after ingest\nto a local drive"
                } else {
                    facesFooterLabel.stringValue = "scanning…"
                }
                facesFooterLabel.textColor = Theme.tx2
                facesPanelWidth.constant = Self.railWidth
                facesPanel.isHidden = false
            } else {
                facesPanelWidth.constant = 0
                facesPanel.isHidden = true
            }
            updateStageRail()
            return
        }

        let count = pairs.count
        let gap: CGFloat = 6
        let innerWidth = Self.railWidth - 24

        // Columns come from the COUNT ALONE - so dragging the divider never
        // reshuffles sizes; it only changes how many rows are visible. Fewer
        // faces → fewer columns → bigger crops.
        let columns: Int
        switch count {
        case 1:      columns = 1
        case 2...6:  columns = 2
        case 7...12: columns = 3
        default:     columns = 4
        }
        // Cells FILL the width (edge to edge), capped so a lone face isn't
        // absurdly large.
        let rawCell = (innerWidth - CGFloat(columns - 1) * gap) / CGFloat(columns)
        let chosenSize = min(rawCell, 150)

        let blinking = pairs.filter { $0.1.blinking }.count
        facesHeaderLabel.attributedStringValue = Theme.sectionTitle("Faces \(count)")
        if blinking > 0 {
            facesFooterLabel.stringValue = "\(blinking) of \(count) blinking"
            facesFooterLabel.textColor = Theme.red
        } else {
            facesFooterLabel.stringValue = "All eyes open"
            facesFooterLabel.textColor = Theme.tx2
        }

        // Center rows so partial last rows (and a capped single) sit tidily.
        facesStack.alignment = .centerX
        var row: NSStackView?
        for (i, pair) in pairs.enumerated() {
            if i % columns == 0 {
                let newRow = NSStackView()
                newRow.orientation = .horizontal
                newRow.spacing = gap
                facesStack.addArrangedSubview(newRow)
                row = newRow
            }
            row?.addArrangedSubview(faceCell(image: pair.0, face: pair.1, faceIndex: i, size: chosenSize))
        }

        // The card is pinned to the lower edge and the scroll fills it, so
        // crops sit at the top and the rest of the height is scrollable -
        // no dead gap below the panel, and sizes never depend on height.
        facesPanelWidth.constant = Self.railWidth
        facesPanel.isHidden = false
        updateStageRail()
    }

    private func faceCell(image: NSImage, face: FaceInfo, faceIndex: Int, size: CGFloat) -> NSView {
        let cell = NSView()
        cell.wantsLayer = true
        cell.layer?.cornerRadius = 5
        cell.layer?.masksToBounds = true
        cell.layer?.backgroundColor = Theme.bg2.cgColor
        cell.identifier = NSUserInterfaceItemIdentifier("\(faceIndex)")
        cell.translatesAutoresizingMaskIntoConstraints = false

        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(imageView)

        // Full triage on every face: red = blinking, amber = soft face or
        // marginal eyes, green = good. Every face gets a verdict.
        let ring: NSColor = face.blinking ? Theme.red
            : (face.lowQuality || face.squinting) ? Theme.accent
            : Theme.labelColors[3]
        cell.layer?.borderWidth = 2
        cell.layer?.borderColor = ring.cgColor

        var notes: [String] = [face.blinking ? "eyes closed"
                               : (face.squinting ? "squinting" : "eyes open")]
        if let q = face.quality { notes.append(String(format: "quality %.2f", q)) }
        if face.smileScore != nil { notes.append(face.smiling ? "smiling" : "not smiling") }
        notes.append("click to zoom")
        cell.toolTip = notes.joined(separator: " · ")

        cell.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(faceCellTapped(_:))))

        NSLayoutConstraint.activate([
            cell.widthAnchor.constraint(equalToConstant: size),
            cell.heightAnchor.constraint(equalToConstant: size),
            imageView.topAnchor.constraint(equalTo: cell.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: cell.bottomAnchor)
        ])
        return cell
    }

    @objc private func faceCellTapped(_ recognizer: NSClickGestureRecognizer) {
        guard let idString = recognizer.view?.identifier?.rawValue,
              let faceIndex = Int(idString),
              faceIndex < currentFaces.count else { return }
        zoomToFace(currentFaces[faceIndex].rect)
    }

    /// Click a face: below 1:1 → zoom to true 1:1 centered on it; already
    /// zoomed → PAN to it at the current level. Click around the group like
    /// inspection points without ever zooming out.
    private func zoomToFace(_ rect: CGRect) {
        ensureFullRes { [weak self] in
            guard let self else { return }
            self.atFit = false
            let doc = self.stageView.frame
            let center = NSPoint(x: rect.midX * doc.width, y: rect.midY * doc.height)
            let oneToOne = 1.0 / self.backingScale
            if self.stageScroll.magnification < oneToOne - 0.001 {
                self.stageScroll.setMagnification(oneToOne, centeredAt: center)
            } else {
                self.panVisible(to: center)
            }
            self.updateZoomLabel()
        }
    }

    /// Smoothly center the viewport on a point in document coordinates.
    private func panVisible(to point: NSPoint) {
        let clip = stageScroll.contentView
        let visible = clip.documentVisibleRect
        let target = NSRect(x: point.x - visible.width / 2,
                            y: point.y - visible.height / 2,
                            width: clip.bounds.width,
                            height: clip.bounds.height)
        let constrained = clip.constrainBoundsRect(target).origin
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            clip.animator().setBoundsOrigin(constrained)
        }
        stageScroll.reflectScrolledClipView(clip)
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard next >= 0, next < assets.count else { return }
        index = next
        showCurrent()
    }

    private func cullChanged() {
        refreshFilmstrip()
        onCullChanged?()
    }

    @objc private func cullModeDidChange() { refreshHintLabel() }

    private func refreshHintLabel() {
        hintLabel.arrangedSubviews.forEach { hintLabel.removeArrangedSubview($0); $0.removeFromSuperview() }
        let colorFirst = RatingsStore.shared.colorFirstRating
        hintLabel.addArrangedSubview(Theme.hintRow([
            ("← →", "nav"),
            ("1–5", colorFirst ? "color" : "rate"),
            ("⌃1–5", colorFirst ? "rate" : "color"),
            ("X", "reject"), ("Z", "100%"), ("I", "info"),
            ("F", "faces"), ("⇥", "both"), ("⎋", "grid")
        ]))
    }

    // MARK: - Keyboard (called from the app-level key monitor)

    /// Returns true if the event was consumed.
    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 123: step(-1); return true       // left arrow
        case 124: step(1); return true        // right arrow
        case 48: toggleRail(); return true // tab: whole rail (both cards)
        case 53, 49, 36: close(); return true // esc, space, return
        default: break
        }
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return false }
        let ctrl = event.modifierFlags.contains(.control)
        // Control only swaps the star/color axis on 0–5; pass any other
        // ⌃-combo through untouched.
        if ctrl, !["0", "1", "2", "3", "4", "5"].contains(chars.lowercased()) { return false }
        switch chars.lowercased() {
        case "z":
            toggle100()
            return true
        case "i":
            toggleInfoPanel()
            return true
        case "=", "+":
            zoomStep(1.5)
            return true
        case "-", "_":
            zoomStep(1.0 / 1.5)
            return true
        case "f":
            toggleFacesPanel() // F = faces (fit is still on Z)
            return true
        case "1", "2", "3", "4", "5":
            let n = Int(chars)!
            let id = assets[index].id
            if RatingsStore.shared.digitSetsStar(control: ctrl) {
                RatingsStore.shared.setRating(n, for: id)
            } else {
                RatingsStore.shared.setColorLabel(n, for: id)
            }
            cullChanged()
            step(1) // rate/color-and-advance
            return true
        case "0":
            let id = assets[index].id
            if RatingsStore.shared.digitSetsStar(control: ctrl) {
                RatingsStore.shared.setRating(0, for: id)
            } else {
                RatingsStore.shared.setColorLabel(0, for: id)
            }
            cullChanged()
            step(1) // clear-and-advance, same rhythm
            return true
        case "u":
            // Unlabel - clears the color outright.
            RatingsStore.shared.setColorLabel(0, for: assets[index].id)
            cullChanged()
            return true
        case "x":
            RatingsStore.shared.toggleRejected(assets[index].id)
            cullChanged()
            step(1)
            return true
        case "[", "]":
            // [ rotates CCW, ] rotates CW - re-decodes at the new orientation.
            RatingsStore.shared.rotate(assets[index].id, by: chars == "]" ? 90 : -90)
            showCurrent()
            onCullChanged?() // grid thumbnails re-render too
            return true
        default:
            return false
        }
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    override func layout() {
        super.layout()
        // Window got shorter than the current filmstrip allows → shrink it
        // back into bounds so the layout never over-demands height.
        let maxFilm = maxFilmstripHeight()
        if filmstripHeightConstraint != nil, filmstripHeightConstraint.constant > maxFilm {
            filmstripHeightConstraint.constant = maxFilm
            applyFilmstripItemSize(for: maxFilm)
        }
        if atFit { stageScroll.magnify(toFit: stageView.frame) }
        // Window resized meaningfully → re-fit the right rail to the new space.
        if abs(bounds.width - lastFacesLayoutSize.width) > 50 || abs(bounds.height - lastFacesLayoutSize.height) > 50 {
            lastFacesLayoutSize = bounds.size
            refreshInfoPanel()
            layoutFacesGrid()
        }
    }

    private func close() {
        onClose?(index)
    }
}

// MARK: - Filmstrip data source

extension PreviewOverlayView: NSCollectionViewDataSource, NSCollectionViewDelegate {

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        assets.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FilmstripItem.identifier, for: indexPath)
        if let cell = item as? FilmstripItem, indexPath.item < assets.count {
            cell.configure(asset: assets[indexPath.item], isCurrent: indexPath.item == index)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let ip = indexPaths.first, ip.item < assets.count else { return }
        collectionView.deselectItems(at: indexPaths) // current state shown via styling
        index = ip.item
        showCurrent()
    }
}

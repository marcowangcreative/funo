import AppKit
import QuickCullCore

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
        QuickCullImage.setContents(cgImage, of: layer)
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

/// One frame in the filmstrip. The thumbnail is only the photograph.
/// An 8px color square and the stars sit in a caption under it.
final class FilmstripItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FilmstripItem")

    private let thumb = NSImageView()
    private let colorDot = NSView()
    private let markLabel = NSTextField(labelWithString: "")
    private var dotWidth: NSLayoutConstraint!
    private var dotGap: NSLayoutConstraint!
    private(set) var representedURL: URL?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.borderColor = Theme.tx0.cgColor
        thumb.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(thumb)

        colorDot.wantsLayer = true
        colorDot.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(colorDot)

        markLabel.font = Theme.monoCaption
        markLabel.textColor = Theme.accent
        markLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(markLabel)

        dotWidth = colorDot.widthAnchor.constraint(equalToConstant: 0)
        dotGap = markLabel.leadingAnchor.constraint(equalTo: colorDot.trailingAnchor, constant: 0)
        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: view.topAnchor),
            thumb.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            thumb.bottomAnchor.constraint(equalTo: colorDot.topAnchor, constant: -3),

            colorDot.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            colorDot.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -1),
            colorDot.heightAnchor.constraint(equalToConstant: 8),
            dotWidth,

            markLabel.centerYAnchor.constraint(equalTo: colorDot.centerYAnchor),
            markLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            dotGap,
        ])
    }

    func configure(asset: PhotoAsset, isCurrent: Bool) {
        let urlChanged = representedURL != asset.url
        representedURL = asset.url
        let id = asset.id
        let rejected = RatingsStore.shared.isRejected(id)
        let rating = RatingsStore.shared.rating(for: id)
        let color = RatingsStore.shared.colorLabel(for: id)
        let caption = CellCaption.make(filename: "", format: "", rating: rating,
                                       rejected: rejected, colorLabel: color)

        thumb.alphaValue = rejected ? 0.4 : 1
        thumb.layer?.borderWidth = isCurrent ? 1 : 0

        if caption.showsColorDot {
            colorDot.layer?.backgroundColor = Theme.labelColors[caption.colorLabel].cgColor
        }
        let showDot = caption.showsColorDot
        if dotWidth.constant != (showDot ? 8 : 0) { dotWidth.constant = showDot ? 8 : 0 }
        if dotGap.constant != (showDot ? 3 : 0) { dotGap.constant = showDot ? 3 : 0 }
        markLabel.stringValue = caption.mark
        markLabel.textColor = caption.rejected ? Theme.red : Theme.accent

        let url = asset.url
        let rotation = RatingsStore.shared.rotation(for: url.path)
        if let cached = ThumbnailLoader.shared.cachedImage(for: url, maxPixel: ThumbnailLoader.thumbnailPixelSize) {
            thumb.image = cached
        } else {
            // Same cell, same file (the strip restyles on every arrow): don't
            // blank a thumb that's already painted. A URL change, or a
            // rotation (cache key changed, so this is a miss), still fetches.
            if urlChanged { thumb.image = nil }
            ThumbnailLoader.shared.request(url, maxPixel: ThumbnailLoader.thumbnailPixelSize) { [weak self] image in
                guard let self, self.representedURL == url else { return }
                guard RatingsStore.shared.rotation(for: url.path) == rotation else { return }
                if let image { self.thumb.image = image }
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
    /// Cull state ON the stage (bottom-left): color chip + stars/reject for
    /// the CURRENT frame. The filmstrip's 4px strip was the only echo of a
    /// color label in expanded view - invisible while your eye is on the
    /// photo, and rate-and-advance means the strip you'd check belongs to a
    /// frame you already left.
    private let cullPlate = NSView()
    private let cullSwatch = NSView()
    private let cullText = NSTextField(labelWithString: "")
    // Decision Band (docked left of the filmstrip): cull state, focus
    // verdict, eyes, frame position - one baseline, one glance. Kills the
    // reviewer's "my eyes have to bounce" tour for good.
    private let focusKeyLabel = NSTextField(labelWithString: "FOCUS")
    private let focusValueLabel = NSTextField(labelWithString: "—")
    private let eyesKeyLabel = NSTextField(labelWithString: "EYES")
    private let eyesValueLabel = NSTextField(labelWithString: "—")
    private let frameKeyLabel = NSTextField(labelWithString: "FRAME")
    private let frameValueLabel = NSTextField(labelWithString: "")
    /// On-frame per-face triage badges (exceptions only). Pooled + repositioned.
    private var faceBadges: [RangefinderBadgeView] = []
    /// Per-photo retry budget for transient per-face score failures.
    private var faceScoreRetries = 0
    /// Crop retries for the photo currently on stage. Reset on navigation.
    private var faceCropRetries = 0
    /// Whose crops `currentFacePairs` belongs to. Keeps the previous photo's
    /// faces from staying on screen after an arrow, and keeps a refresh from
    /// tearing the panel down when it's already showing this photo.
    private var currentFaceAssetID: String?
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
    /// The user trashed a frame from the expanded view - the grid reloads
    /// its folder while the overlay carries on with its own trimmed roll.
    var onTrashed: (() -> Void)?

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

        // Caption bar under the stage: filename lives on the left (infoLabel),
        // color square and stars on the right. Nothing sits on the photograph.
        // Focus, eyes, and frame stay in the info rail.
        cullPlate.wantsLayer = true
        cullPlate.layer?.backgroundColor = Theme.bg1.cgColor
        cullPlate.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cullPlate)
        let captionLine = NSView()
        captionLine.wantsLayer = true
        captionLine.layer?.backgroundColor = Theme.line.cgColor
        captionLine.translatesAutoresizingMaskIntoConstraints = false
        cullPlate.addSubview(captionLine)
        cullSwatch.wantsLayer = true
        cullSwatch.translatesAutoresizingMaskIntoConstraints = false
        cullText.font = Theme.monoCaption
        cullText.textColor = Theme.accent
        let cullGroup = NSStackView(views: [cullSwatch, cullText])
        cullGroup.orientation = .horizontal
        cullGroup.spacing = 6
        cullGroup.alignment = .centerY
        cullGroup.translatesAutoresizingMaskIntoConstraints = false
        cullPlate.addSubview(cullGroup)
        NSLayoutConstraint.activate([
            cullSwatch.widthAnchor.constraint(equalToConstant: 8),
            cullSwatch.heightAnchor.constraint(equalToConstant: 8),
            captionLine.leadingAnchor.constraint(equalTo: cullPlate.leadingAnchor),
            captionLine.trailingAnchor.constraint(equalTo: cullPlate.trailingAnchor),
            captionLine.topAnchor.constraint(equalTo: cullPlate.topAnchor),
            captionLine.heightAnchor.constraint(equalToConstant: 1),
            cullGroup.trailingAnchor.constraint(equalTo: cullPlate.trailingAnchor, constant: -12),
            cullGroup.centerYAnchor.constraint(equalTo: cullPlate.centerYAnchor),
            cullPlate.heightAnchor.constraint(equalToConstant: 28),
        ])

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
        infoPanel.layer?.backgroundColor = Theme.bg1.cgColor
        infoPanel.layer?.cornerRadius = 0
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
        facesPanel.layer?.backgroundColor = Theme.bg1.cgColor
        facesPanel.layer?.cornerRadius = 0
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
        cullPlate.addSubview(infoLabel)
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

            zoomLabel.trailingAnchor.constraint(equalTo: hintLabel.leadingAnchor, constant: -16),
            zoomLabel.centerYAnchor.constraint(equalTo: footerBand.centerYAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: footerBand.trailingAnchor, constant: -14),
            hintLabel.centerYAnchor.constraint(equalTo: footerBand.centerYAnchor),

            // Caption bar sits under the stage: filename left, color and
            // stars right. The filmstrip runs full width beneath it.
            // infoLabel was added before the bar; lift it above the bar fill.
            cullPlate.leadingAnchor.constraint(equalTo: leadingAnchor),
            cullPlate.trailingAnchor.constraint(equalTo: trailingAnchor),
            cullPlate.bottomAnchor.constraint(equalTo: filmstripHandle.topAnchor, constant: -4),
            infoLabel.leadingAnchor.constraint(equalTo: cullPlate.leadingAnchor, constant: 12),
            infoLabel.centerYAnchor.constraint(equalTo: cullPlate.centerYAnchor),
            infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: cullGroup.leadingAnchor, constant: -12),

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
            stageScroll.bottomAnchor.constraint(equalTo: cullPlate.topAnchor),

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
        // Clamp to the collection view's REAL height when it's laid out: the
        // scroll frame minus scroller/insets can be a few points shorter than
        // the constraint, and a flow-layout item taller than its collection
        // view triggers the "behavior is not defined" console warning on
        // every layout pass.
        var itemH = height - 4
        let visible = filmstripView.bounds.height
        if visible > 8 { itemH = min(itemH, visible - 2) }
        guard itemH > 8 else { return }   // mid-layout zero-height pass: skip
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
        // display() fails when the cached NSImage can't produce a CGImage
        // (zero-size images built off the main thread). Falling through to
        // a fresh request is what stops the stage staying on the PREVIOUS
        // photo while the filmstrip moves on.
        let previewShown = ThumbnailLoader.shared.cachedImage(for: url, maxPixel: ThumbnailLoader.previewPixelSize)
            .map { display($0) } ?? false
        if !previewShown {
            if let thumb = ThumbnailLoader.shared.cachedImage(for: url, maxPixel: ThumbnailLoader.thumbnailPixelSize) {
                _ = display(thumb)
            }
            // Retry on nil: a decode can be CANCELLED under rapid arrowing
            // (or fail transiently on a busy drive), and giving up stranded
            // the stage on the blurry grid thumb until the user left and
            // came back. Generation/fit guards cancel the chain on move.
            func requestPreview(_ attempt: Int) {
                ThumbnailLoader.shared.request(url, maxPixel: ThumbnailLoader.previewPixelSize) { [weak self] image in
                    guard let self, self.showGeneration == gen, self.atFit, !self.fullResLoaded else { return }
                    if let image, self.display(image) {
                        // shown
                    } else if attempt < 3 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                            guard let self, self.showGeneration == gen, self.atFit, !self.fullResLoaded else { return }
                            requestPreview(attempt + 1)
                        }
                    }
                }
            }
            requestPreview(0)
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
        // Already-settled photos are drawn by the debounced refresh. The poll
        // only covers a verdict that lands after that refresh gave up.
        if case .pending = FaceAnalyzer.shared.phase(for: asset.id),
           !FileOps.isMemoryCard(asset.url) {
            pollFacesIfNeeded(attempt: 0, generation: gen, assetID: asset.id)
        }
        refreshInfoPanel()
        refreshFilmstrip()
        faceScoreRetries = 0
        updateFaceBadges()
        refreshCullPlate()
        frameValueLabel.stringValue = "\(index + 1) / \(assets.count)"
        updateFocusReadout()
        updateEyesReadout()
        adoptSidecarForCurrentIfPending()

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

    @discardableResult
    private func display(_ image: NSImage) -> Bool {
        guard let cg = image.quickCullCGImage() else { return false }
        stageView.setImage(cg)
        stageView.frame = NSRect(x: 0, y: 0, width: cg.width, height: cg.height)
        if atFit { fitToWindow() }
        return true
    }

    // MARK: - Zoom

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }

    private func fitToWindow() {
        atFit = true
        // magnify(toFit:) animates by default. The thumb→preview handoff
        // called it twice per frame and the stage zoomed visibly.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        stageScroll.magnify(toFit: stageView.frame)
        NSAnimationContext.endGrouping()
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
            guard let image, let cg = image.quickCullCGImage() else { return }
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
        updateFaceBadges()
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
        updateFaceBadges()
        updateEyesReadout()
    }

    /// Position an on-frame badge over EVERY prominent face - eye state plus
    /// the rangefinder split graded per face - faded out as
    /// you push past 1:1. Rides the F toggle with the rest of the face system.
    /// Cheap: reads cached analysis, converts each face box through the live
    /// zoom/pan transform. Hidden entirely when F is off or nothing's flagged.
    private func updateFaceBadges() {
        guard showFacesPanel, FaceAnalyzer.shared.isEnabled, index < assets.count,
              let analysis = FaceAnalyzer.shared.result(for: assets[index].id),
              !analysis.faces.isEmpty else {
            faceBadges.forEach { $0.isHidden = true }
            return
        }
        // Grade EVERY face, not just problems: a clean aligned green mark says
        // "checked, and it's good" - absence only meant "didn't look." (Marco:
        // seeing green on the keepers is the reassurance.) Cap to the 8 most
        // prominent so a background crowd never sprouts marks.
        //
        // The split is driven by REAL per-face acutance (same metric as the
        // Focus row), never Vision quality - quality rates a soft face "good"
        // and drew an aligned green split on an out-of-focus subject. Until the
        // scores land (sub-second, then memoized) the badges stay hidden; the
        // completion re-runs this.
        guard let scores = SharpnessAnalyzer.shared.cachedFaceScores(for: assets[index]) else {
            faceBadges.forEach { $0.isHidden = true }
            let gen = showGeneration
            SharpnessAnalyzer.shared.faceScores(for: assets[index]) { [weak self] result in
                // Re-run only when scores arrived - a nil result can be
                // delivered SYNCHRONOUSLY, and re-running on nil in the same
                // stack frame was the infinite-recursion crash (2026-07-28).
                // A nil here is a transient decode failure (cold/busy drive):
                // retry a few times DELAYED (async, so it can't recurse),
                // generation-guarded so leaving the photo cancels the chain.
                // Without this, badges just never appeared until the user
                // backed out and re-entered.
                guard let self, self.showGeneration == gen else { return }
                if result != nil {
                    self.updateFaceBadges()
                } else if self.faceScoreRetries < 3 {
                    self.faceScoreRetries += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        guard let self, self.showGeneration == gen else { return }
                        self.updateFaceBadges()
                    }
                }
            }
            return
        }
        let graded = Array(analysis.faces.enumerated()
            .sorted { ($0.element.rect.width * $0.element.rect.height) > ($1.element.rect.width * $1.element.rect.height) }
            .prefix(8))
        let imgW = stageView.bounds.width, imgH = stageView.bounds.height
        guard imgW > 0, imgH > 0 else { faceBadges.forEach { $0.isHidden = true }; return }
        // Survey aid: fade out between 1:1 and ~1.6:1 as you pixel-peep one face.
        let zoom = stageScroll.magnification * backingScale
        let fade = max(0, min(1, 1 - (zoom - 1.0) / 0.6))
        while faceBadges.count < graded.count {
            let b = RangefinderBadgeView(frame: .zero)
            addSubview(b, positioned: .below, relativeTo: infoPanel)
            faceBadges.append(b)
        }
        let stageFrame = stageScroll.frame.insetBy(dx: -24, dy: -24)
        let sz = RangefinderBadgeView.badgeSize
        for (i, badge) in faceBadges.enumerated() {
            guard i < graded.count, fade > 0.02 else { badge.isHidden = true; continue }
            let (faceIndex, face) = graded[i]
            // face.rect is Vision-normalized, bottom-left; stageView is sized to
            // image pixels, also bottom-left. maxY = top of the face.
            let topCenter = NSPoint(x: face.rect.midX * imgW, y: face.rect.maxY * imgH)
            let p = stageView.convert(topCenter, to: self)
            guard stageFrame.contains(p) else { badge.isHidden = true; continue }
            let focus = faceIndex < scores.count ? scores[faceIndex] : -1
            guard focus >= 0 else { badge.isHidden = true; continue }
            badge.configure(quality: CGFloat(focus),
                            blinking: face.blinking, squinting: face.squinting)
            badge.setFrameSize(sz)
            badge.setFrameOrigin(NSPoint(x: p.x - sz.width / 2, y: p.y + 4))
            badge.alphaValue = fade
            badge.isHidden = false
        }
    }

    /// Debounce the crop fetch while the user is flying through frames.
    /// The previous photo's faces are cleared immediately — holding that
    /// layout (the old dimmed panel) showed the wrong people on the new frame.
    private var facesRefreshTimer: Timer?

    private func scheduleFacesRefresh() {
        let assetID = index < assets.count ? assets[index].id : nil
        if currentFaceAssetID != assetID {
            currentFacePairs = []
            currentFaces = []
            currentFaceAssetID = assetID
            faceCropRetries = 0
            layoutFacesGrid()
        }
        facesPanel.alphaValue = 1
        facesRefreshTimer?.invalidate()
        facesRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.28, repeats: false) { [weak self] _ in
            self?.rebuildFacesRow()
        }
    }

    /// The result callback can be missed (a tab closed out from under the
    /// old single-observer slot, or the decode landed in the gap before the
    /// debounced refresh). Keep asking until the verdict settles or the
    /// user has moved on. Generation-guarded, so it can't update a stale frame.
    private func pollFacesIfNeeded(attempt: Int, generation: Int, assetID: String) {
        guard attempt < 20 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.showGeneration == generation, self.index < self.assets.count,
                  self.assets[self.index].id == assetID else { return }
            switch FaceAnalyzer.shared.phase(for: assetID) {
            case .pending:
                self.pollFacesIfNeeded(attempt: attempt + 1, generation: generation, assetID: assetID)
            case .faces, .noFaces, .unavailable:
                if self.facesRefreshTimer?.isValid != true {
                    self.rebuildFacesRow()
                }
                self.updateFaceBadges()
                self.updateEyesReadout()
            }
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
        updateFaceBadges()
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
        // score() returns nil when the preview hasn't decoded yet (cold
        // folder) - its doc says "caller can retry once the preview lands",
        // and this caller never did: the row just silently missed until the
        // user backed out and re-entered. Retry a few times, generation-
        // guarded so leaving the photo cancels the chain.
        func scoreFocus(_ attempt: Int) {
            SharpnessAnalyzer.shared.score(for: asset) { [weak self] acutance in
                guard let self, self.infoGeneration == gen else { return }
                guard let acutance else {
                    if attempt < 4 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                            guard let self, self.infoGeneration == gen else { return }
                            scoreFocus(attempt + 1)
                        }
                    }
                    return
                }
                self.focusRowLanded(acutance)
            }
        }
        scoreFocus(0)
    }

    /// Insert the scored Focus row (split out so the retry chain stays small).
    private func focusRowLanded(_ acutance: Double) {
            let f = SharpnessAnalyzer.focusFraction(acutance)
            // Color-coded so focus quality reads at a glance - and the tint
            // advertises the metric exists: >=80% green, >=50% amber, else red.
            let word: String
            let tint: NSColor
            if f >= 0.80 { word = "crisp"; tint = NSColor(srgbRed: 0.32, green: 0.74, blue: 0.42, alpha: 1) }
            else if f >= 0.50 { word = "fair"; tint = Theme.accent }
            else { word = "soft"; tint = Theme.red }
            let row = infoRow("Focus", "\(Int(f * 100))%  \(word)", valueColor: tint)
            infoStack.insertArrangedSubview(row, at: 0)
            infoFocusRow = row
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
        guard showFacesPanel, FaceAnalyzer.shared.isEnabled, index < assets.count else {
            currentFaces = []
            currentFacePairs = []
            currentFaceAssetID = nil
            layoutFacesGrid()
            return
        }
        let asset = assets[index]
        if currentFaceAssetID != asset.id {
            currentFaces = []
            currentFacePairs = []
            currentFaceAssetID = asset.id
            faceCropRetries = 0
            layoutFacesGrid()
        }
        let gen = showGeneration
        FaceCropper.shared.crops(for: asset, maxFaces: 40) { [weak self] pairs in
            guard let self, self.showGeneration == gen, self.index < self.assets.count,
                  self.assets[self.index].id == asset.id else { return }
            if pairs.isEmpty {
                // Crops can fail transiently (the analysis image was busy)
                // even after a verdict with faces landed. Retry; a true
                // "no faces" settles through layoutFacesGrid.
                if case .faces = FaceAnalyzer.shared.phase(for: asset.id), self.faceCropRetries < 3 {
                    self.faceCropRetries += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        guard let self, self.showGeneration == gen else { return }
                        self.rebuildFacesRow()
                    }
                    self.layoutFacesGrid()
                    return
                }
                self.currentFacePairs = []
                self.currentFaces = []
                self.layoutFacesGrid()
                return
            }
            self.faceCropRetries = 0
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

        // No crops yet: distinguish "still scanning" from "couldn't read"
        // (retry budget spent — not cached, so a reload tries again) from
        // "faces known, crops in flight" from "scanned, no faces".
        // A known-but-not-yet-cropped face used to take the "no faces" branch
        // and hide the panel until the user left and came back.
        if pairs.isEmpty {
            let phase = index < assets.count
                ? FaceAnalyzer.shared.phase(for: assets[index].id)
                : FacePanelPhase.pending
            switch phase {
            case .noFaces:
                facesPanelWidth.constant = 0
                facesPanel.isHidden = true
            case .pending:
                facesHeaderLabel.attributedStringValue = Theme.sectionTitle("Faces")
                if index < assets.count, FileOps.isMemoryCard(assets[index].url) {
                    facesFooterLabel.stringValue = "scans after ingest\nto a local drive"
                } else {
                    facesFooterLabel.stringValue = "scanning…"
                }
                facesFooterLabel.textColor = Theme.tx2
                facesPanelWidth.constant = Self.railWidth
                facesPanel.isHidden = false
            case .unavailable:
                facesHeaderLabel.attributedStringValue = Theme.sectionTitle("Faces")
                facesFooterLabel.stringValue = "couldn't read this photo\nRescan Faces to retry"
                facesFooterLabel.textColor = Theme.tx2
                facesPanelWidth.constant = Self.railWidth
                facesPanel.isHidden = false
            case .faces:
                facesHeaderLabel.attributedStringValue = Theme.sectionTitle("Faces")
                facesFooterLabel.stringValue = "loading faces…"
                facesFooterLabel.textColor = Theme.tx2
                facesPanelWidth.constant = Self.railWidth
                facesPanel.isHidden = false
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
        refreshCullPlate(flash: true)
        onCullChanged?()
    }

    /// The cull readout can BEAT the sidecar stream: a cold 6k folder adopts
    /// Lightroom/PM sidecar ratings in display order over several seconds, so
    /// a frame deep in the folder showed "no rating" for 5-10 s after opening.
    /// Read THIS frame's sidecar immediately (one tiny text file, off-main)
    /// and adopt it, so the plate is truthful the moment you land. Frames the
    /// store already knows skip the read; unrated frames cost one stat-miss.
    private func adoptSidecarForCurrentIfPending() {
        guard index < assets.count else { return }
        let asset = assets[index]
        guard asset.isRAW else { return }
        let store = RatingsStore.shared
        guard store.rating(for: asset.id) == 0,
              store.colorLabel(for: asset.id) == 0,
              !store.isRejected(asset.id) else { return }
        let gen = showGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (rating, label) = XMPSidecar.read(for: asset.url)
            guard rating != nil || label != nil else { return }
            DispatchQueue.main.async {
                guard let self, self.showGeneration == gen else { return }
                if RatingsStore.shared.adopt(rating: rating, label: label, for: asset.id) {
                    self.refreshCullPlate()
                    self.refreshFilmstrip()
                }
            }
        }
    }

    /// Color square and stars on the right of the caption bar. The bar itself
    /// stays up — the filename lives there. Focus and eyes stay in the rail.
    private func refreshCullPlate(flash: Bool = false) {
        guard index < assets.count else { return }
        let store = RatingsStore.shared
        let id = assets[index].id
        let caption = CellCaption.make(
            filename: "", format: "",
            rating: store.rating(for: id),
            rejected: store.isRejected(id),
            colorLabel: store.colorLabel(for: id)
        )
        cullSwatch.isHidden = !caption.showsColorDot
        if caption.showsColorDot {
            cullSwatch.layer?.backgroundColor = Theme.labelColors[caption.colorLabel].cgColor
        }
        cullText.stringValue = caption.mark
        cullText.textColor = caption.rejected ? Theme.red : Theme.accent
        if flash, !caption.mark.isEmpty {
            cullText.layer?.removeAllAnimations()
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.35
            pulse.toValue = 1.0
            pulse.duration = 0.22
            pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
            cullText.layer?.add(pulse, forKey: "pulse")
        }
    }

    /// Decision Band: focus verdict for the frame on stage (same bands and
    /// tints as the info-rail Focus row).
    private func updateFocusReadout() {
        focusValueLabel.stringValue = "—"
        focusValueLabel.textColor = Theme.tx2
        guard index < assets.count else { return }
        let gen = showGeneration
        SharpnessAnalyzer.shared.score(for: assets[index]) { [weak self] acutance in
            guard let self, self.showGeneration == gen, let acutance else { return }
            let f = SharpnessAnalyzer.focusFraction(acutance)
            if f >= 0.80 {
                self.focusValueLabel.textColor = NSColor(srgbRed: 0.32, green: 0.74, blue: 0.42, alpha: 1)
            } else if f >= 0.50 {
                self.focusValueLabel.textColor = Theme.accent
            } else {
                self.focusValueLabel.textColor = Theme.red
            }
            self.focusValueLabel.stringValue = "\(Int(f * 100))%"
        }
    }

    /// Decision Band: eyes verdict - blinks outrank squints outrank open.
    private func updateEyesReadout() {
        guard index < assets.count,
              let analysis = FaceAnalyzer.shared.result(for: assets[index].id),
              !analysis.faces.isEmpty else {
            eyesValueLabel.stringValue = "—"
            eyesValueLabel.textColor = Theme.tx2
            return
        }
        let blinks = analysis.faces.filter { $0.blinking }.count
        let squints = analysis.faces.filter { $0.squinting }.count
        if blinks > 0 {
            eyesValueLabel.stringValue = blinks == 1 ? "1 blink" : "\(blinks) blinks"
            eyesValueLabel.textColor = Theme.red
        } else if squints > 0 {
            eyesValueLabel.stringValue = squints == 1 ? "1 squint" : "\(squints) squints"
            eyesValueLabel.textColor = Theme.accent
        } else {
            eyesValueLabel.stringValue = "open"
            eyesValueLabel.textColor = NSColor(srgbRed: 0.32, green: 0.74, blue: 0.42, alpha: 1)
        }
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
        case 51 where event.modifierFlags.contains(.command):
            trashCurrent(); return true       // ⌘⌫ - same gesture as the grid
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

    /// ⌘⌫ - trash the frame on screen without leaving the flow: the photo
    /// leaves the roll, the next frame takes the stage. Sound fires ON the
    /// gesture (Finder feel); the actual trash runs off-main.
    private func trashCurrent() {
        guard index < assets.count else { return }
        let asset = assets.remove(at: index)
        PhotoGridViewController.trashSound?.stop()
        PhotoGridViewController.trashSound?.play()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = FileOps.trash([asset.url])
            DispatchQueue.main.async {
                FileOpsHistory.push("move to Trash", result.records)
                self?.onTrashed?()
            }
        }
        guard !assets.isEmpty else { close(); return }
        if index >= assets.count { index = assets.count - 1 }
        filmstripView.reloadData()
        showCurrent()
    }

    override func layout() {
        super.layout()
        // Window got shorter than the current filmstrip allows → shrink it
        // back into bounds so the layout never over-demands height.
        let maxFilm = maxFilmstripHeight()
        if filmstripHeightConstraint != nil, filmstripHeightConstraint.constant > maxFilm {
            filmstripHeightConstraint.constant = maxFilm
            applyFilmstripItemSize(for: maxFilm)
        } else if filmstripHeightConstraint != nil,
                  filmstripView.bounds.height > 8,
                  filmstripLayout.itemSize.height > filmstripView.bounds.height {
            // The collection view came out shorter than the item (scroller,
            // rounding, first pass) - re-clamp so the flow layout stays legal.
            applyFilmstripItemSize(for: filmstripHeightConstraint.constant)
        }
        if atFit { stageScroll.magnify(toFit: stageView.frame) }
        updateFaceBadges()
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

extension PreviewOverlayView: NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {

    /// Item size consulted AT LAYOUT TIME and clamped to the collection
    /// view's real height, so the item can never exceed it - which is what
    /// fired the "UICollectionViewFlowLayout behavior is not defined"
    /// console warning on every pass where the strip and its scroller
    /// disagreed with the constraint-derived size.
    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize {
        let desired = filmstripLayout.itemSize
        let maxH = collectionView.bounds.height
        guard maxH > 8, desired.height > maxH else { return desired }
        let h = (maxH - 1).rounded(.down)
        return NSSize(width: (h * 1.5).rounded(), height: h)
    }

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

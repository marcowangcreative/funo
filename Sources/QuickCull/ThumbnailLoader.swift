import AppKit
import ImageIO
import QuickCullCore

/// The heart of the prototype: turn a file URL into pixels on screen as fast
/// as physically possible, by preferring the camera's own embedded preview
/// over decoding RAW sensor data.
///
/// Strategy per request:
///   1. Memory cache hit → instant.
///   2. Ask ImageIO for an EMBEDDED thumbnail only (no full decode).
///   3. If that's missing or too small, force-generate one (full decode,
///      but downsampled during decode - never a 60MP bitmap in memory).
final class ThumbnailLoader {

    static let shared = ThumbnailLoader()

    /// Grid thumbnails.
    static let thumbnailPixelSize: CGFloat = 512
    /// Full-window previews - roughly a Retina display's backing store.
    static let previewPixelSize: CGFloat = 3200
    /// 100% zoom - full native resolution (CR3s: the 6000×4000 embedded JPEG).
    static let fullPixelSize: CGFloat = 8192

    /// Three tiers so they can't starve each other: a zooming session's
    /// ~96 MB full-res bitmaps must never evict the grid's thumbnails
    /// (that eviction is what makes other apps feel like they "come back
    /// slow" after heavy use).
    private let thumbCache = NSCache<NSString, NSImage>()   // grid thumbs
    private let previewCache = NSCache<NSString, NSImage>() // fit-to-screen previews
    private let fullCache = NSCache<NSString, NSImage>()    // 100% zoom decodes

    /// Pending decodes keyed by cache key. Touched from the main thread only.
    private var pending: [String: ThumbTicket] = [:]

    private final class ThumbTicket {
        var job = 0
        var cancelled = false
        var tier: Int = 0
    }

    private init() {
        thumbCache.totalCostLimit = 500 * 1_024 * 1_024   // thousands of thumbs
        previewCache.totalCostLimit = 500 * 1_024 * 1_024 // ~12 screen-size previews
        fullCache.countLimit = 3                          // current + neighbors, hard cap
    }

    private func cache(for maxPixel: CGFloat) -> NSCache<NSString, NSImage> {
        if maxPixel <= Self.thumbnailPixelSize { return thumbCache }
        if maxPixel <= Self.previewPixelSize { return previewCache }
        return fullCache
    }

    /// User rotation is part of the cache key, so a rotated photo re-decodes
    /// once and every surface (grid, preview, filmstrip, inspector) agrees.
    private func cacheKey(_ url: URL, _ maxPixel: CGFloat) -> String {
        let rotation = RatingsStore.shared.rotation(for: url.path)
        return "\(url.path)#\(Int(maxPixel))#\(rotation)"
    }

    func cachedImage(for url: URL, maxPixel: CGFloat) -> NSImage? {
        cache(for: maxPixel).object(forKey: cacheKey(url, maxPixel) as NSString)
    }

    /// Testing aid: drop every decoded image held in memory.
    func clearMemoryCaches() {
        thumbCache.removeAllObjects()
        previewCache.removeAllObjects()
        fullCache.removeAllObjects()
    }

    /// Waiters per cache key: every caller wanting this decode gets called
    /// back when it lands. Replaces the old polling loop, which could
    /// strand a visible cell blank forever if its decode was cancelled
    /// mid-poll (very visible on slow memory cards).
    private var waiters: [String: [(NSImage?) -> Void]] = [:] // main thread

    /// Drop every queued decode for files on `volumePath` before an eject.
    func cancelPending(underVolumePath volumePath: String) {
        assert(Thread.isMainThread)
        for (key, ticket) in pending {
            let path = key.split(separator: "#").first.map(String.init) ?? ""
            let volume = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeURLKey]))?.volume?.path
            guard volume == volumePath else { continue }
            ticket.cancelled = true
            pending[key] = nil
        }
        WorkRunner.shared.cancel(volume: volumePath)
    }

    func request(_ url: URL, maxPixel: CGFloat, completion: @escaping (NSImage?) -> Void) {
        let key = cacheKey(url, maxPixel)
        if let hit = cache(for: maxPixel).object(forKey: key as NSString) {
            completion(hit)
            return
        }
        waiters[key, default: []].append(completion)
        // A visible caller is waiting - promote an already-queued op (e.g.
        // from a prefetch) over the backlog. Previews go all the way to
        // .veryHigh: the frame on screen preempts everything else.
        let want: WorkLane = maxPixel > Self.thumbnailPixelSize ? .selected : .visible
        if let existing = pending[key] {
            WorkRunner.shared.setLane(existing.job, want)
        }
        ensureOperation(key: key, url: url, maxPixel: maxPixel)
    }

    /// Warm the cache without registering a waiter - cancellable freely.
    func prefetch(_ url: URL, maxPixel: CGFloat) {
        let key = cacheKey(url, maxPixel)
        guard cache(for: maxPixel).object(forKey: key as NSString) == nil else { return }
        ensureOperation(key: key, url: url, maxPixel: maxPixel)
    }

    /// The scroll position moved: THESE files are on screen now. Their
    /// pending thumbnail decodes jump the line; every other queued thumb
    /// drops to low. Without this, on a slow card, requests from screens
    /// you scrolled PAST run first-come-first-served and the screen you're
    /// looking at starves blank behind them.
    func focusVisible(_ urls: [URL], maxPixel: CGFloat) {
        let tier = Int(maxPixel)
        let visibleKeys = Set(urls.map { cacheKey($0, maxPixel) })
        guard !visibleKeys.isEmpty else { return }
        let floor: WorkLane = maxPixel > Self.thumbnailPixelSize ? .selected : .visible
        for (key, ticket) in pending where ticket.tier == tier {
            let waited = !(waiters[key]?.isEmpty ?? true)
            if visibleKeys.contains(key) || waited {
                WorkRunner.shared.setLane(ticket.job, floor)
            } else {
                WorkRunner.shared.setLane(ticket.job, .prefetch)
            }
        }
    }

    /// Cancel a decode that scrolled out of relevance - unless a visible
    /// caller is waiting on it.
    func cancel(_ url: URL, maxPixel: CGFloat) {
        let key = cacheKey(url, maxPixel)
        guard waiters[key]?.isEmpty ?? true else { return }
        if let ticket = pending[key] {
            ticket.cancelled = true
            WorkRunner.shared.cancel(id: ticket.job)
        }
        pending[key] = nil
    }

    private func ensureOperation(key: String, url: URL, maxPixel: CGFloat) {
        guard pending[key] == nil else { return }
        let userRotation = RatingsStore.shared.rotation(for: url.path)
        let ticket = ThumbTicket()
        ticket.tier = Int(maxPixel)
        let hasWaiter = !(waiters[key]?.isEmpty ?? true)
        let lane: WorkLane = hasWaiter
            ? (maxPixel > Self.thumbnailPixelSize ? .selected : .visible)
            : .prefetch
        pending[key] = ticket
        let place = WorkRunner.shared.classify(url)
        WorkRunner.shared.submit(
            group: "thumb", name: url.lastPathComponent, lane: lane,
            volume: place.volume, pace: place.pace, generation: 0,
            onQueued: { ticket.job = $0 }
        ) { [weak self, weak ticket] isCancelled in
            guard let ticket else { return }
            if isCancelled() || ticket.cancelled {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard ThumbnailDelivery.shouldPublish(pendingOpIsSelf: self.pending[key] === ticket) else { return }
                    self.pending[key] = nil
                    let stranded = self.waiters.removeValue(forKey: key) ?? []
                    stranded.forEach { $0(nil) }
                }
                return
            }

            // Disk cache (grid thumbnails only): second open of a folder
            // skips decoding entirely.
            // Disk-cache thumbnails AND previews (not the 8192 full-res -
            // too big, rarely revisited). The LRU cache bounds the growth,
            // so a revisited photo in expanded view is sharp INSTANTLY with
            // no lower-res buffer flash.
            var diskKey: String?
            if maxPixel <= Self.previewPixelSize, let identity = CacheDB.identity(for: url) {
                diskKey = identity + "|t\(Int(maxPixel))|r\(userRotation)"
            }
            var image: NSImage?
            if let diskKey, let data = CacheDB.shared.get(diskKey) {
                // Force-decode NOW, on this background lane. NSImage(data:)
                // keeps the JPEG compressed and pays decompression on MAIN
                // at first draw - 25-100ms hitches per screenful of warm
                // cells, and a per-arrow-press hitch on cached previews.
                image = Self.decodeImmediate(data)
            }
            var freshlyDecoded = false
            if image == nil {
                image = Self.decode(url: url, maxPixel: maxPixel, userRotation: userRotation)
                freshlyDecoded = image != nil
            }
            // Persist AFTER delivery, off the decode lane: the JPEG encode
            // of a 3200px preview is 50-150ms the viewer used to wait out
            // before pixels appeared, and it held the lane the next decode
            // needed.
            if freshlyDecoded, let image, let diskKey {
                DispatchQueue.global(qos: .utility).async {
                    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                    let rep = NSBitmapImageRep(cgImage: cg)
                    if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) {
                        CacheDB.shared.set(diskKey, jpeg)
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                // Same rule as the cancel path. A decode that already passed
                // its isCancelled check can still finish AFTER cancel() nils
                // this slot and a visible cell starts a replacement op.
                // Publishing here stole the new waiters (nil or a stale
                // image) and the replacement completed into silence — blank
                // or stuck cells while scrolling and after reloads.
                let authoritative = ThumbnailDelivery.shouldPublish(pendingOpIsSelf: self.pending[key] === ticket)
                guard authoritative else { return }
                self.pending[key] = nil
                if let image {
                    let cost = Int(image.size.width * image.size.height * 4)
                    self.cache(for: maxPixel).setObject(image, forKey: key as NSString, cost: cost)
                }
                let callbacks = self.waiters.removeValue(forKey: key) ?? []
                callbacks.forEach { $0(image) }
            }
        }
    }

    // MARK: - Decoding (background threads)

    /// Decode a cached JPEG blob to REAL pixels on the calling (background)
    /// thread. NSImage(data:) defers decompression to first draw on main.
    private static func decodeImmediate(_ data: Data) -> NSImage? {
        let opts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, opts) else {
            return NSImage(data: data)
        }
        return QuickCullImage.fromCGImage(cg)
    }

    private static func decode(url: URL, maxPixel: CGFloat, userRotation: Int = 0) -> NSImage? {
        guard let image = decodeOriented(url: url, maxPixel: maxPixel) else { return nil }
        guard userRotation != 0 else { return image }
        guard let cg = image.quickCullCGImage() else { return image }
        return QuickCullImage.fromCGImage(ImageTransform.rotate(cg, degreesCW: userRotation))
    }

    /// Decode with EXIF/container orientation applied (no user rotation yet).
    private static func decodeOriented(url: URL, maxPixel: CGFloat) -> NSImage? {
        // Canon CR3: for large previews, pull the camera's full-resolution
        // embedded JPEG straight out of the container. ImageIO only exposes
        // the 1620×1080 PRVW; this gets us the 6000×4000 rendition with a
        // cheap JPEG decode instead of a RAW develop.
        if maxPixel > 1024, url.pathExtension.lowercased() == "cr3",
           let image = CR3PreviewExtractor.decodePreview(url: url, maxPixel: maxPixel) {
            return image
        }

        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }

        // Pass 1: embedded preview only. This is the Photo Mechanic trick -
        // the camera already made us a JPEG; just use it.
        let embeddedOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, embeddedOptions as CFDictionary) {
            let biggestSide = CGFloat(max(cg.width, cg.height))
            // Acceptance bar scales with the COST of rejecting:
            // · JPEG/HEIC: pass 2 is a cheap direct decode, so demand at
            //   least half the requested size. (The old flat 240px bar let
            //   a JPEG's 320px EXIF thumbnail stand in for a 3200px screen
            //   preview - "perfectly fine JPEGs render blurry.")
            // · RAW: pass 2 is a full develop (seconds on some formats) -
            //   accept any real preview ≥1280px; a 2× upscale beats a
            //   beach ball, and face-aware focus judges sharpness anyway.
            let isRAW = PhotoAsset.rawExtensions.contains(url.pathExtension.lowercased())
            let bar = isRAW ? min(maxPixel * 0.5, 1280) : maxPixel * 0.5
            if biggestSide >= bar {
                return QuickCullImage.fromCGImage(cg)
            }
        }

        // Pass 2: no usable embedded preview - decode, but downsample on the way in.
        let forcedOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, forcedOptions as CFDictionary) {
            return QuickCullImage.fromCGImage(cg)
        }
        return nil
    }
}

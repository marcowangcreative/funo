import AppKit
import ImageIO

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

    /// Pending operations keyed by cache key. Touched from the main thread only.
    private var pending: [String: Operation] = [:]

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

    /// Per-volume decode queues: an internal SSD takes all cores, but a
    /// memory card gets TWO lanes - fifteen parallel readers on one slow
    /// USB card thrash it into delivering less than two would.
    private var volumeQueues: [String: OperationQueue] = [:] // main thread

    /// Directory → decode queue memo. queue(for:) runs on the MAIN thread for
    /// every thumbnail request; resolving .volumeURLKey is a stat, and doing
    /// one per visible cell against a waking external drive froze the click.
    /// Every file in a folder shares a volume - the first answers for all.
    private var dirQueueMemo: [String: OperationQueue] = [:] // main thread

    private func queue(for url: URL) -> OperationQueue {
        let dir = url.deletingLastPathComponent().path
        if let memoed = dirQueueMemo[dir] { return memoed }
        let volumePath = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path ?? "/"
        if let existing = volumeQueues[volumePath] { dirQueueMemo[dir] = existing; return existing }
        let values = try? URL(fileURLWithPath: volumePath).resourceValues(
            forKeys: [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey])
        // A genuinely slow memory card (SD/CF/USB flash) is the only volume
        // that thrashes under parallelism; an external SSD/HDD is CPU-decode-
        // bound just like the internal, so throttling it to 2 lanes (the old
        // broad "removable" rule) starved the cores and read as load lag.
        let isCard = values?.volumeIsRemovable ?? false
        let isExternal = isCard
            || (values?.volumeIsEjectable ?? false)
            || !(values?.volumeIsInternal ?? true)
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let q = OperationQueue()
        q.name = "quickcull.decode.\(volumePath)"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = isCard
            ? 2                                // slow card: more lanes thrash it
            : (isExternal ? max(4, cores - 2)  // external SSD/HDD: nearly full
                          : max(4, cores - 1)) // internal SSD: all cores
        volumeQueues[volumePath] = q
        dirQueueMemo[dir] = q
        return q
    }

    /// Request an image. Completion always fires on the main thread.
    /// Calls are coalesced: many requests for the same file share one decode.
    /// Drop every queued decode for files on `volumePath` - ejecting a card
    /// fails while OUR reads hold it open. Executing decodes finish (they're
    /// short); queued ones never start. Main thread (queues dict is main-only).
    func cancelPending(underVolumePath volumePath: String) {
        assert(Thread.isMainThread)
        volumeQueues[volumePath]?.cancelAllOperations()
    }

    func request(_ url: URL, maxPixel: CGFloat, completion: @escaping (NSImage?) -> Void) {
        let key = cacheKey(url, maxPixel)
        if let hit = cache(for: maxPixel).object(forKey: key as NSString) {
            completion(hit)
            return
        }
        waiters[key, default: []].append(completion)
        // A visible caller is waiting - make sure an already-queued op
        // (e.g. from a prefetch) doesn't languish behind the backlog.
        if let existing = pending[key], existing.queuePriority.rawValue < Operation.QueuePriority.high.rawValue {
            existing.queuePriority = .high
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
        let tier = "\(Int(maxPixel))"
        let visibleKeys = Set(urls.map { cacheKey($0, maxPixel) })
        for (key, op) in pending where op.name == tier {
            op.queuePriority = visibleKeys.contains(key) ? .high : .low
        }
    }

    /// Cancel a decode that scrolled out of relevance - unless a visible
    /// caller is waiting on it.
    func cancel(_ url: URL, maxPixel: CGFloat) {
        let key = cacheKey(url, maxPixel)
        guard waiters[key]?.isEmpty ?? true else { return }
        pending[key]?.cancel()
        pending[key] = nil
    }

    private func ensureOperation(key: String, url: URL, maxPixel: CGFloat) {
        guard pending[key] == nil else { return }
        let userRotation = RatingsStore.shared.rotation(for: url.path)

        let op = BlockOperation()
        op.name = "\(Int(maxPixel))" // tier tag for focusVisible()
        // Priority tiers: the big preview the user is LOOKING AT preempts
        // the thumbnail backlog (critical on slow cards, where hundreds of
        // queued thumbs used to starve the sharp render for minutes).
        if maxPixel > Self.thumbnailPixelSize {
            op.queuePriority = .veryHigh
        } else if !(waiters[key]?.isEmpty ?? true) {
            op.queuePriority = .high   // visible cell
        } else {
            op.queuePriority = .normal // prefetch
        }
        op.addExecutionBlock { [weak self, weak op] in
            guard let op, !op.isCancelled else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.pending[key] === op { self.pending[key] = nil }
                    // Shouldn't happen (cancel spares keys with waiters), but
                    // never strand a caller.
                    let stranded = self.waiters.removeValue(forKey: key) ?? []
                    stranded.forEach { $0(nil) }
                }
                return
            }

            // Disk cache (grid thumbnails only): second open of a folder
            // skips decoding entirely.
            var diskKey: String?
            if maxPixel <= Self.thumbnailPixelSize, let identity = CacheDB.identity(for: url) {
                diskKey = identity + "|t\(Int(maxPixel))|r\(userRotation)"
            }
            var image: NSImage?
            if let diskKey, let data = CacheDB.shared.get(diskKey) {
                image = NSImage(data: data)
            }
            if image == nil {
                image = Self.decode(url: url, maxPixel: maxPixel, userRotation: userRotation)
                if let image, let diskKey,
                   let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) {
                        CacheDB.shared.set(diskKey, jpeg)
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if self.pending[key] === op { self.pending[key] = nil }
                if let image {
                    let cost = Int(image.size.width * image.size.height * 4)
                    self.cache(for: maxPixel).setObject(image, forKey: key as NSString, cost: cost)
                }
                let callbacks = self.waiters.removeValue(forKey: key) ?? []
                callbacks.forEach { $0(image) }
            }
        }
        pending[key] = op
        queue(for: url).addOperation(op)
    }

    // MARK: - Decoding (background threads)

    private static func decode(url: URL, maxPixel: CGFloat, userRotation: Int = 0) -> NSImage? {
        guard let image = decodeOriented(url: url, maxPixel: maxPixel) else { return nil }
        guard userRotation != 0 else { return image }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        return NSImage(cgImage: ImageTransform.rotate(cg, degreesCW: userRotation), size: .zero)
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
                return NSImage(cgImage: cg, size: .zero)
            }
        }

        // Pass 2: no usable embedded preview - decode, but downsample on the way in.
        let forcedOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, forcedOptions as CFDictionary) {
            return NSImage(cgImage: cg, size: .zero)
        }
        return nil
    }
}

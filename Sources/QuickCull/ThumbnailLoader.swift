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
///   4. Whatever comes back is copied into an 8-bit buffer no larger than
///      the size that was asked for, then ImageIO's own cache is dropped.
///      The previous cache kept those full frames: NSCache does not enforce
///      its cost limit on macOS, so a Release-speed scroll retained every
///      one of them (tens of GB). The caches below evict before insert
///      returns.
final class ThumbnailLoader {

    static let shared = ThumbnailLoader()

    /// Grid thumbnails.
    static let thumbnailPixelSize: CGFloat = 512
    /// Full-window previews - roughly a Retina display's backing store.
    static let previewPixelSize: CGFloat = 3200
    /// 100% zoom - full native resolution (CR3s: the 6000×4000 embedded JPEG).
    static let fullPixelSize: CGFloat = 8192

    /// Hard ceilings, enforced on insert. See BoundedCostCache.
    ///
    /// Thumbs: a 512px bitmap is ~0.5–1 MB, so 160 MB is a couple of
    /// screens of scrollback — flicking back does not re-decode.
    /// Previews: a 3200px frame is ~15–30 MB. Eight covers the loupe's
    /// ±2 window plus a little scrollback.
    /// Full-res: at most three zoomed frames, and never more than ~360 MB.
    private let thumbCache = BoundedCostCache<NSImage>(costLimit: 160 * 1_024 * 1_024, countLimit: 250)
    private let previewCache = BoundedCostCache<NSImage>(costLimit: 240 * 1_024 * 1_024, countLimit: 8)
    private let fullCache = BoundedCostCache<NSImage>(costLimit: 360 * 1_024 * 1_024, countLimit: 3)

    /// Pending operations keyed by cache key. Touched from the main thread only.
    private var pending: [String: Operation] = [:]

    private init() {}

    private func cache(for maxPixel: CGFloat) -> BoundedCostCache<NSImage> {
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
        cache(for: maxPixel).value(for: cacheKey(url, maxPixel))
    }

    /// "thumbs 40 MB, previews 48 MB, full 0 MB" — for the memory log.
    func cacheSummary() -> String {
        func mb(_ bytes: Int) -> String { String(format: "%.0f MB", Double(bytes) / 1_048_576) }
        let thumbs = thumbCache.currentCost
        let previews = previewCache.currentCost
        let full = fullCache.currentCost
        return "image-cache \(mb(thumbs + previews + full)) (thumbs \(mb(thumbs)), previews \(mb(previews)), full \(mb(full)), \(thumbCache.count + previewCache.count + fullCache.count) images)"
    }

    /// Throttled resident-memory line. No-op unless FUNO_MEMORY_LOG=1.
    func logMemory(_ context: String) {
        MemoryFootprint.log(context: context, cacheSummary: cacheSummary())
    }

    /// Testing aid: drop every decoded image held in memory.
    func clearMemoryCaches() {
        thumbCache.removeAll()
        previewCache.removeAll()
        fullCache.removeAll()
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
        if let hit = cache(for: maxPixel).value(for: key) {
            completion(hit)
            return
        }
        waiters[key, default: []].append(completion)
        // A visible caller is waiting - make sure an already-queued op
        // (e.g. from a prefetch) doesn't languish behind the backlog.
        if let existing = pending[key] {
            let wanted: Operation.QueuePriority = maxPixel > Self.thumbnailPixelSize ? .veryHigh : .high
            if existing.queuePriority.rawValue < wanted.rawValue {
                existing.queuePriority = wanted
            }
        }
        ensureOperation(key: key, url: url, maxPixel: maxPixel)
    }

    /// Warm the cache without registering a waiter - cancellable freely.
    func prefetch(_ url: URL, maxPixel: CGFloat) {
        let key = cacheKey(url, maxPixel)
        guard cache(for: maxPixel).value(for: key) == nil else { return }
        ensureOperation(key: key, url: url, maxPixel: maxPixel)
    }

    /// The scroll position moved: THESE files are on screen now. Their
    /// pending thumbnail decodes jump the line. Prefetches outside
    /// `prefetchWindow` are cancelled — a fast scroll used to leave a
    /// decode queued for every cell that briefly appeared, and in Release
    /// those all finished and stayed resident.
    func focusVisible(_ urls: [URL], prefetchWindow: [URL], maxPixel: CGFloat) {
        assert(Thread.isMainThread)
        let tier = "\(Int(maxPixel))"
        let visibleKeys = Set(urls.map { cacheKey($0, maxPixel) })
        let keepKeys = Set(prefetchWindow.map { cacheKey($0, maxPixel) })
        let keys = Array(pending.keys)
        for key in keys {
            guard let op = pending[key], op.name == tier else { continue }
            if visibleKeys.contains(key) {
                op.queuePriority = .high
            } else if keepKeys.contains(key) {
                if op.queuePriority.rawValue < Operation.QueuePriority.normal.rawValue {
                    op.queuePriority = .normal
                }
            } else if waiters[key]?.isEmpty ?? true {
                op.cancel()
                pending[key] = nil
            } else {
                op.queuePriority = .low
            }
        }
        if maxPixel <= Self.thumbnailPixelSize {
            thumbCache.touch(visibleKeys)
        }
    }

    /// Only these preview-sized decodes are still relevant (the loupe's
    /// current frame and its immediate neighbors, or the single grid
    /// selection). Everything else at that tier is cancelled, including
    /// in-flight requests whose waiter will see nil and ignore it because
    /// the photo is no longer on screen. Arrowing through a folder used to
    /// queue one ~30 MB preview per keystroke and never cancel them.
    func notePreviewWindow(_ urls: [URL]) {
        assert(Thread.isMainThread)
        let keep = Set(urls.map { cacheKey($0, Self.previewPixelSize) })
        cancelTier(Int(Self.previewPixelSize), except: keep, dropWaiters: true)
    }

    /// Navigation landed back at fit. A zoomed full-res decode for a photo
    /// we've already left is the biggest single buffer we allocate
    /// (~100 MB); don't finish it.
    func cancelFullResDecodes() {
        assert(Thread.isMainThread)
        cancelTier(Int(Self.fullPixelSize), except: [], dropWaiters: true)
    }

    /// Cancel a decode that scrolled out of relevance - unless a visible
    /// caller is waiting on it.
    func cancel(_ url: URL, maxPixel: CGFloat) {
        let key = cacheKey(url, maxPixel)
        guard waiters[key]?.isEmpty ?? true else { return }
        pending[key]?.cancel()
        pending[key] = nil
    }

    private func cancelTier(_ tierPixel: Int, except keep: Set<String>, dropWaiters: Bool) {
        let tier = "\(tierPixel)"
        var stranded: [(NSImage?) -> Void] = []
        for key in Array(pending.keys) {
            guard let op = pending[key], op.name == tier, !keep.contains(key) else { continue }
            if !dropWaiters && !(waiters[key]?.isEmpty ?? true) { continue }
            op.cancel()
            pending[key] = nil
            if dropWaiters, let callbacks = waiters.removeValue(forKey: key) {
                stranded.append(contentsOf: callbacks)
            }
        }
        guard !stranded.isEmpty else { return }
        // Async so a waiter that re-enters the loader (a retry) can't
        // mutate `pending` under this loop.
        DispatchQueue.main.async {
            stranded.forEach { $0(nil) }
        }
    }

    private func ensureOperation(key: String, url: URL, maxPixel: CGFloat) {
        guard pending[key] == nil else { return }
        let userRotation = RatingsStore.shared.rotation(for: url.path)

        let op = BlockOperation()
        op.name = "\(Int(maxPixel))" // tier tag for focusVisible()
        // Priority: a preview someone is LOOKING AT preempts the thumbnail
        // backlog. A speculative preview (grid selection, loupe neighbor)
        // does not — those used to be .veryHigh, so arrowing the contact
        // sheet starved the thumbs you were scrolling and flooded RAM with
        // screen-sized bitmaps.
        let hasWaiter = !(waiters[key]?.isEmpty ?? true)
        if hasWaiter && maxPixel > Self.thumbnailPixelSize {
            op.queuePriority = .veryHigh
        } else if hasWaiter {
            op.queuePriority = .high   // visible cell
        } else if maxPixel > Self.thumbnailPixelSize {
            op.queuePriority = .normal // nearby preview prefetch
        } else {
            op.queuePriority = .normal // thumbnail prefetch
        }
        op.addExecutionBlock { [weak self, weak op] in
            guard let op, !op.isCancelled else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // Only the AUTHORITATIVE op for this key may fail its
                    // waiters. A cancelled prefetch can lose this slot to a
                    // fresh visible-cell request (cancel() clears pending,
                    // request() re-creates the op); firing that NEW caller's
                    // waiters with nil from the dead op's corpse left grid
                    // cells permanently blank during fast scrolls.
                    guard self.pending[key] === op else { return }
                    self.pending[key] = nil
                    let stranded = self.waiters.removeValue(forKey: key) ?? []
                    stranded.forEach { $0(nil) }
                }
                return
            }

            // One pool per image. Release builds otherwise keep every
            // autoreleased ImageIO/AppKit temporary alive until the
            // operation queue drains its thread pool — and Release fills
            // that queue much faster than Debug. The bitmap is retained
            // into `decoded` before the pool drains; returning it directly
            // from the pool can drop it under optimization.
            var decoded: DecodedImage?
            autoreleasepool {
                // Disk cache (grid thumbnails AND previews, not the 8192
                // full-res — too big, rarely revisited). The LRU bounds the
                // RAM copy, so a revisited photo in expanded view is sharp
                // INSTANTLY with no lower-res buffer flash.
                var diskKey: String?
                if maxPixel <= Self.previewPixelSize, let identity = CacheDB.identity(for: url) {
                    diskKey = identity + "|t\(Int(maxPixel))|r\(userRotation)"
                }
                if let diskKey, let data = CacheDB.shared.get(diskKey),
                   let cached = Self.imageFromDiskJPEG(data, maxPixel: maxPixel) {
                    decoded = cached
                    return
                }
                guard let fresh = Self.decode(url: url, maxPixel: maxPixel, userRotation: userRotation) else {
                    return
                }
                if let diskKey, let cg = fresh.image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) {
                        CacheDB.shared.set(diskKey, jpeg)
                    }
                }
                decoded = fresh
            }
            // Cancelled while we were decoding (the user already scrolled
            // past). Drop the bitmap on the floor instead of caching it.
            if op.isCancelled {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.pending[key] === op else { return }
                    self.pending[key] = nil
                    let stranded = self.waiters.removeValue(forKey: key) ?? []
                    stranded.forEach { $0(nil) }
                }
                return
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let authoritative = self.pending[key] === op
                if authoritative { self.pending[key] = nil }
                if authoritative, let decoded {
                    self.cache(for: maxPixel).insert(decoded.image, for: key, cost: decoded.cost)
                }
                guard authoritative else { return }
                let callbacks = self.waiters.removeValue(forKey: key) ?? []
                callbacks.forEach { $0(decoded?.image) }
            }
        }
        pending[key] = op
        queue(for: url).addOperation(op)
    }

    // MARK: - Decoding (background threads)

    private struct DecodedImage {
        let image: NSImage
        let cost: Int
    }

    /// A disk blob is a JPEG we wrote earlier. Old blobs (from before the
    /// cache started downsampling) can be full-frame; scale them on the
    /// way back in instead of trusting the file.
    private static func imageFromDiskJPEG(_ data: Data, maxPixel: CGFloat) -> DecodedImage? {
        guard let source = ImageIODecode.makeSource(data: data) else { return nil }
        defer { ImageIODecode.dropCache(source) }
        guard let cg = ImageIODecode.thumbnail(source: source, maxPixel: maxPixel, embeddedOnly: false),
              let fitted = ImageIODecode.materialized(cg, maxPixel: maxPixel) else {
            return nil
        }
        let image = NSImage(cgImage: fitted, size: NSSize(width: fitted.width, height: fitted.height))
        return DecodedImage(image: image, cost: ImageIODecode.byteCost(fitted))
    }

    private static func decode(url: URL, maxPixel: CGFloat, userRotation: Int = 0) -> DecodedImage? {
        guard let image = decodeOriented(url: url, maxPixel: maxPixel) else { return nil }
        guard userRotation != 0 else {
            let cost = byteCost(of: image)
            return DecodedImage(image: image, cost: cost)
        }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return DecodedImage(image: image, cost: byteCost(of: image))
        }
        let rotated = ImageTransform.rotate(cg, degreesCW: userRotation)
        let turned = NSImage(cgImage: rotated, size: NSSize(width: rotated.width, height: rotated.height))
        return DecodedImage(image: turned, cost: ImageIODecode.byteCost(rotated))
    }

    private static func byteCost(of image: NSImage) -> Int {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return ImageIODecode.byteCost(cg)
        }
        return max(1, Int((image.size.width * image.size.height * 4).rounded()))
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

        guard let source = ImageIODecode.makeSource(url: url) else { return nil }
        defer { ImageIODecode.dropCache(source) }

        // Pass 1: embedded preview only. This is the Photo Mechanic trick -
        // the camera already made us a JPEG; just use it. If ImageIO hands
        // it back larger than we asked (it often ignores the max-pixel
        // ceiling for an existing preview), scale it ourselves. That is a
        // blit, not a RAW develop.
        let isRAW = PhotoAsset.rawExtensions.contains(url.pathExtension.lowercased())
        let bar = isRAW ? min(maxPixel * 0.5, 1280) : maxPixel * 0.5
        if let embedded = ImageIODecode.thumbnail(source: source, maxPixel: maxPixel, embeddedOnly: true) {
            let biggestSide = CGFloat(max(embedded.width, embedded.height))
            if biggestSide >= bar, let fitted = ImageIODecode.materialized(embedded, maxPixel: maxPixel) {
                return NSImage(cgImage: fitted, size: NSSize(width: fitted.width, height: fitted.height))
            }
        }

        // Pass 2: no usable embedded preview - decode, downsampled on the way in.
        guard let forced = ImageIODecode.thumbnail(source: source, maxPixel: maxPixel, embeddedOnly: false),
              let fitted = ImageIODecode.materialized(forced, maxPixel: maxPixel) else {
            return nil
        }
        return NSImage(cgImage: fitted, size: NSSize(width: fitted.width, height: fitted.height))
    }
}

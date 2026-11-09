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
        var lane: WorkLane = .prefetch
        var volumeQueued = false
    }

    private let statsLock = NSLock()
    private var cacheHitCount = 0
    private var embeddedCount = 0
    private var fullCount = 0
    private var countedCacheKeys = Set<String>()
    private var warmToken = 0
    private let cacheQueue = DispatchQueue(label: "funo.thumb.cache", qos: .userInitiated)

    struct Stats {
        var cache: Int
        var embedded: Int
        var full: Int
    }

    func resetStats() {
        statsLock.lock()
        cacheHitCount = 0
        embeddedCount = 0
        fullCount = 0
        countedCacheKeys.removeAll(keepingCapacity: true)
        statsLock.unlock()
    }

    func stats() -> Stats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return Stats(cache: cacheHitCount, embedded: embeddedCount, full: fullCount)
    }

    private func recordCacheHit(_ key: String) {
        statsLock.lock()
        if countedCacheKeys.insert(key).inserted { cacheHitCount += 1 }
        statsLock.unlock()
    }

    private func recordDecode(_ kind: DecodeKind) {
        statsLock.lock()
        switch kind {
        case .embedded: embeddedCount += 1
        case .full: fullCount += 1
        }
        statsLock.unlock()
    }

    func cancelWarm() {
        statsLock.lock()
        warmToken += 1
        statsLock.unlock()
    }

    private func bumpWarm() -> Int {
        statsLock.lock()
        warmToken += 1
        let token = warmToken
        statsLock.unlock()
        return token
    }

    private func warmIsCurrent(_ token: Int) -> Bool {
        statsLock.lock()
        defer { statsLock.unlock() }
        return warmToken == token
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
    func focusVisible(_ urls: [URL], ahead: [URL] = [], maxPixel: CGFloat) {
        let tier = Int(maxPixel)
        let visibleKeys = Set(urls.map { cacheKey($0, maxPixel) })
        let aheadKeys = Set(ahead.map { cacheKey($0, maxPixel) })
        guard !visibleKeys.isEmpty || !aheadKeys.isEmpty else { return }
        let floor: WorkLane = maxPixel > Self.thumbnailPixelSize ? .selected : .visible
        var lanes: [Int: WorkLane] = [:]
        for (key, ticket) in pending where ticket.tier == tier && ticket.job != 0 {
            let waited = !(waiters[key]?.isEmpty ?? true)
            let target: WorkLane
            if visibleKeys.contains(key) || waited {
                target = floor
            } else if aheadKeys.contains(key) {
                target = .lookahead
            } else {
                target = .prefetch
            }
            guard ticket.lane != target else { continue }
            ticket.lane = target
            lanes[ticket.job] = target
        }
        if !lanes.isEmpty { WorkRunner.shared.replaceLanes(lanes) }
    }

    /// Disk-cache warm for the open folder. The leading window (the screen
    /// plus the next few) is read first, in one query, and does not take a
    /// slot on the photo's volume. Misses are then decoded on that volume,
    /// leading window before the rest of the folder.
    func warmFolder(_ urls: [URL], leading: Int, maxPixel: CGFloat) {
        let token = bumpWarm()
        let capped = max(0, min(leading, urls.count))
        let planned: [(URL, String, Int)] = urls.map { url in
            let rotation = RatingsStore.shared.rotation(for: url.path)
            return (url, "\(url.path)#\(Int(maxPixel))#\(rotation)", rotation)
        }
        cacheQueue.async { [weak self] in
            guard let self else { return }
            self.resolveCached(Array(planned.prefix(capped)), token: token, maxPixel: maxPixel, lane: .lookahead)
            var index = capped
            while index < planned.count {
                if !self.warmIsCurrent(token) { return }
                let end = min(index + 400, planned.count)
                self.resolveCached(Array(planned[index..<end]), token: token, maxPixel: maxPixel, lane: .prefetch)
                index = end
            }
        }
    }

    private func resolveCached(_ rows: [(URL, String, Int)], token: Int, maxPixel: CGFloat, lane: WorkLane) {
        if !warmIsCurrent(token) { return }
        struct Row { var url: URL; var memoryKey: String; var diskKey: String; var rotation: Int }
        var pendingRows: [Row] = []
        pendingRows.reserveCapacity(rows.count)
        for (url, memoryKey, rotation) in rows {
            if cache(for: maxPixel).object(forKey: memoryKey as NSString) != nil { continue }
            guard let identity = CacheDB.identity(for: url) else { continue }
            pendingRows.append(Row(url: url, memoryKey: memoryKey, diskKey: identity + "|t\(Int(maxPixel))|r\(rotation)", rotation: rotation))
        }
        let blobs = CacheDB.shared.getMany(pendingRows.map(\.diskKey))
        final class Decoded { var image: NSImage? }
        let decoded = pendingRows.map { _ in Decoded() }
        DispatchQueue.concurrentPerform(iterations: pendingRows.count) { index in
            guard let data = blobs[pendingRows[index].diskKey] else { return }
            decoded[index].image = Self.decodeImmediate(data)
        }
        var hits: [(String, NSImage)] = []
        var misses: [(URL, String, Int)] = []
        for (index, row) in pendingRows.enumerated() {
            if let image = decoded[index].image {
                hits.append((row.memoryKey, image))
            } else {
                misses.append((row.url, row.memoryKey, row.rotation))
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.warmIsCurrent(token) else { return }
            for (key, image) in hits {
                self.recordCacheHit(key)
                let cost = Int(image.size.width * image.size.height * 4)
                self.cache(for: maxPixel).setObject(image, forKey: key as NSString, cost: cost)
                if let callbacks = self.waiters.removeValue(forKey: key) {
                    self.pending[key] = nil
                    callbacks.forEach { $0(image) }
                }
            }
            for (url, key, rotation) in misses {
                self.enqueueVolumeDecode(key: key, url: url, maxPixel: maxPixel, rotation: rotation, lane: lane)
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
            : .lookahead
        ticket.lane = lane
        pending[key] = ticket
        // The cache file is on the internal SSD. This probe does not take a
        // slot on the volume that holds the photo.
        WorkRunner.shared.submit(
            group: "thumb-cache", name: url.lastPathComponent, lane: lane,
            volume: DrivePacing.cacheVolume, pace: .internalDisk, generation: 0,
            onQueued: { ticket.job = $0 }
        ) { [weak self, weak ticket] isCancelled in
            guard let self, let ticket else { return }
            if isCancelled() || ticket.cancelled {
                self.publish(key: key, ticket: ticket, image: nil, maxPixel: maxPixel)
                return
            }
            if let cached = self.cache(for: maxPixel).object(forKey: key as NSString) {
                self.publish(key: key, ticket: ticket, image: cached, maxPixel: maxPixel)
                return
            }
            if maxPixel <= Self.previewPixelSize, let identity = CacheDB.identity(for: url) {
                let diskKey = identity + "|t\(Int(maxPixel))|r\(userRotation)"
                if let data = CacheDB.shared.get(diskKey), let image = Self.decodeImmediate(data) {
                    self.recordCacheHit(key)
                    self.publish(key: key, ticket: ticket, image: image, maxPixel: maxPixel)
                    return
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.enqueueVolumeDecode(key: key, url: url, maxPixel: maxPixel, rotation: userRotation, lane: lane)
            }
        }
    }

    /// Decode from the photo's own volume. Only called after the disk cache missed.
    private func enqueueVolumeDecode(key: String, url: URL, maxPixel: CGFloat, rotation: Int, lane: WorkLane) {
        assert(Thread.isMainThread)
        if cache(for: maxPixel).object(forKey: key as NSString) != nil {
            if let callbacks = waiters.removeValue(forKey: key) {
                pending[key] = nil
                let image = cache(for: maxPixel).object(forKey: key as NSString)
                callbacks.forEach { $0(image) }
            }
            return
        }
        let ticket = pending[key] ?? ThumbTicket()
        guard !ticket.volumeQueued else { return }
        ticket.volumeQueued = true
        ticket.tier = Int(maxPixel)
        let hasWaiter = !(waiters[key]?.isEmpty ?? true)
        let useLane: WorkLane = hasWaiter
            ? (maxPixel > Self.thumbnailPixelSize ? .selected : .visible)
            : lane
        ticket.lane = useLane
        pending[key] = ticket
        let place = WorkRunner.shared.classify(url)
        WorkRunner.shared.submit(
            group: "thumb", name: url.lastPathComponent, lane: useLane,
            volume: place.volume, pace: place.pace, generation: 0,
            onQueued: { ticket.job = $0 }
        ) { [weak self, weak ticket] isCancelled in
            guard let self, let ticket else { return }
            if isCancelled() || ticket.cancelled {
                self.publish(key: key, ticket: ticket, image: nil, maxPixel: maxPixel)
                return
            }
            let decoded = Self.decode(url: url, maxPixel: maxPixel, userRotation: rotation)
            if let decoded {
                self.recordDecode(decoded.kind)
            }
            let image = decoded?.image
            if let image, maxPixel <= Self.previewPixelSize, let identity = CacheDB.identity(for: url) {
                let diskKey = identity + "|t\(Int(maxPixel))|r\(rotation)"
                DispatchQueue.global(qos: .utility).async {
                    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                    let rep = NSBitmapImageRep(cgImage: cg)
                    if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) {
                        CacheDB.shared.set(diskKey, jpeg)
                    }
                }
            }
            self.publish(key: key, ticket: ticket, image: image, maxPixel: maxPixel)
        }
    }

    private func publish(key: String, ticket: ThumbTicket, image: NSImage?, maxPixel: CGFloat) {
        DispatchQueue.main.async { [weak self, weak ticket] in
            guard let self, let ticket else { return }
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

    private enum DecodeKind { case embedded, full }

    private static func decode(url: URL, maxPixel: CGFloat, userRotation: Int = 0) -> (image: NSImage, kind: DecodeKind)? {
        guard let decoded = decodeOriented(url: url, maxPixel: maxPixel) else { return nil }
        guard userRotation != 0 else { return decoded }
        guard let cg = decoded.image.quickCullCGImage() else { return decoded }
        return (QuickCullImage.fromCGImage(ImageTransform.rotate(cg, degreesCW: userRotation)), decoded.kind)
    }

    /// Decode with EXIF/container orientation applied (no user rotation yet).
    private static func decodeOriented(url: URL, maxPixel: CGFloat) -> (image: NSImage, kind: DecodeKind)? {
        // Canon CR3: for large previews, pull the camera's full-resolution
        // embedded JPEG straight out of the container. ImageIO only exposes
        // the 1620×1080 PRVW; this gets us the 6000×4000 rendition with a
        // cheap JPEG decode instead of a RAW develop.
        if maxPixel > 1024, url.pathExtension.lowercased() == "cr3",
           let image = CR3PreviewExtractor.decodePreview(url: url, maxPixel: maxPixel) {
            return (image, .embedded)
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
                return (QuickCullImage.fromCGImage(cg), .embedded)
            }
        }

        // Pass 2: no usable embedded preview - decode, but downsample on the way in.
        let forcedOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, forcedOptions as CFDictionary) {
            return (QuickCullImage.fromCGImage(cg), .full)
        }
        return nil
    }
}

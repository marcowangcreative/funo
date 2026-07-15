import AppKit

/// Focus/sharpness scoring — variance of the Laplacian over the central
/// region of a downscaled grayscale copy. High edge energy = crisp focus,
/// low = soft/blurred.
///
/// Honest scope: the ABSOLUTE number isn't comparable across scenes (a flat
/// wall scores low even in perfect focus). It's reliable as a RELATIVE
/// signal between similar frames — which is exactly the survey-mode
/// question ("which of these near-identical shots is sharpest"). Computed
/// lazily on demand from the already-decoded preview, then cached forever.
final class SharpnessAnalyzer {

    static let shared = SharpnessAnalyzer()

    private let queue = DispatchQueue(label: "quickcull.sharpness", qos: .utility)
    private var memo: [String: Double] = [:] // id → acutance, main-thread only
    private static let cacheVersion = "sharp-v4" // v4: subject-aware (face-region focus)

    /// Cached acutance if we already have it (main thread, instant).
    func cached(for asset: PhotoAsset) -> Double? { memo[asset.id] }

    /// Acutance for an asset — memo → CacheDB → compute from the decoded
    /// preview. Completion always on the main thread; nil if we couldn't
    /// get a decoded image yet (caller can retry once the preview lands).
    func score(for asset: PhotoAsset, completion: @escaping (Double?) -> Void) {
        if let v = memo[asset.id] { completion(v); return }
        let id = asset.id
        let url = asset.url

        // Subject-aware focus: measure the DETECTED FACE (the thing that has to
        // be sharp), not the whole frame. A whole-frame metric rewards a busy,
        // detailed scene and punishes a clean portrait with a soft background —
        // exactly backwards. Fall back to the frame when there are no faces
        // (landscape/product) or a memory card skipped the face pass. Rects are
        // read here on the main thread (FaceAnalyzer.results is main-only).
        let faceResult = FaceAnalyzer.shared.result(for: id)
        let largestFace = faceResult?.faces.max {
            $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height
        }
        // Face pass will run but hasn't yet: compute a provisional whole-frame
        // value WITHOUT caching, so it recomputes as subject-aware once faces
        // land (the expanded view re-scores on noteFaceResult).
        let facesPending = faceResult == nil
            && FaceAnalyzer.shared.isEnabled
            && !FileOps.isMemoryCard(url)
        let key = facesPending ? nil : CacheDB.identity(for: url).map { "\($0)|\(Self.cacheVersion)" }

        queue.async { [weak self] in
            if let key, let data = CacheDB.shared.get(key),
               let s = String(data: data, encoding: .utf8), let v = Double(s) {
                DispatchQueue.main.async { self?.memo[id] = v; completion(v) }
                return
            }
            var acutance: Double?
            // Prefer the largest face, decoded in the SAME space its rect lives
            // in (FaceAnalyzer.analysisDecode) so the crop lands correctly.
            if let face = largestFace,
               let cg = FaceAnalyzer.analysisDecode(url: url, maxPixel: 2048) {
                let W = CGFloat(cg.width), H = CGFloat(cg.height)
                let r = face.rect
                // Vision rects are bottom-left origin; CGImage crops top-left.
                var px = CGRect(x: r.minX * W, y: (1 - r.maxY) * H,
                                width: r.width * W, height: r.height * H)
                px = px.insetBy(dx: -px.width * 0.12, dy: -px.height * 0.12)
                    .intersection(CGRect(x: 0, y: 0, width: W, height: H))
                if !px.isNull, px.width > 8, let crop = cg.cropping(to: px) {
                    acutance = Self.acutance(from: crop)
                }
            }
            // No usable face: whole-frame metric on the cached preview.
            if acutance == nil {
                let image = ThumbnailLoader.shared.cachedImage(for: url, maxPixel: ThumbnailLoader.previewPixelSize)
                    ?? ThumbnailLoader.shared.cachedImage(for: url, maxPixel: ThumbnailLoader.thumbnailPixelSize)
                if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    acutance = Self.acutance(from: cg)
                }
            }
            guard let value = acutance else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            if let key { CacheDB.shared.set(key, Data(String(value).utf8)) }
            DispatchQueue.main.async {
                if !facesPending { self?.memo[id] = value }
                completion(value)
            }
        }
    }

    /// 0…1 focus fraction for a meter, from an empirical log scale. Blurry
    /// frames sit near 0, crisp ones near 1. For display only — the raw
    /// acutance is what's compared in survey mode.
    static func focusFraction(_ normalized: Double) -> Double {
        // `normalized` is edge-energy ÷ contrast (see acutance), now measured
        // on a ~1024px working image instead of 256px. At high resolution a
        // soft edge spreads over several pixels and its Laplacian collapses,
        // so blurred frames genuinely score low — dense text no longer aliases
        // into fake sharpness. Log-mapped; anchors calibrated for the hi-res
        // metric. Capped below 1.0 on purpose: an automated score shouldn't
        // claim absolute "100%" certainty — pixel-peep (Z) to confirm.
        let lg = log10(max(0.0001, normalized))
        let f = (lg - (-2.6)) / ((-0.9) - (-2.6))
        return min(0.99, max(0, f))
    }

    // MARK: - Metric

    /// Edge energy (variance of the Laplacian) DIVIDED by the image's own
    /// contrast (intensity variance). Plain Laplacian variance is fooled by
    /// high-contrast content — printed text has huge edge energy even when
    /// soft, so it always read "sharp." Normalizing by contrast asks the
    /// right question: how sharp are the edges *relative to* how much detail
    /// the scene has — which a soft-but-contrasty document now fails.
    private static func acutance(from cg: CGImage) -> Double {
        // Work at ~1024px, NOT 256px. The old 256px downscale was the whole
        // problem: shrinking a 3200px+ frame that far turns fine detail into
        // aliasing, and aliasing has huge Laplacian variance regardless of
        // focus — so any dense-detail subject (a photographed document above
        // all) pegged the meter. At ~1024px a soft edge stays soft: it spans
        // several pixels, its second derivative collapses, and the score
        // finally tracks real focus. Never upscale past the source.
        let dim = min(1024, max(cg.width, cg.height))
        let scale = Double(dim) / Double(max(cg.width, cg.height))
        let w = max(16, Int(Double(cg.width) * scale))
        let h = max(16, Int(Double(cg.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0 }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h)

        // Central 70% — subjects live near the middle; corners are often
        // intentionally soft (bokeh) and would poison a full-frame metric.
        let x0 = max(1, Int(Double(w) * 0.15)), x1 = min(w - 1, Int(Double(w) * 0.85))
        let y0 = max(1, Int(Double(h) * 0.15)), y1 = min(h - 1, Int(Double(h) * 0.85))
        guard x1 > x0, y1 > y0 else { return 0 }

        var lapSum = 0.0, lapSumSq = 0.0        // Laplacian (edge) energy
        var intSum = 0.0, intSumSq = 0.0, n = 0.0 // intensity (contrast)
        for y in y0..<y1 {
            let row = y * w
            for x in x0..<x1 {
                let c = Int(px[row + x])
                let lap = 4 * c - Int(px[row + x - 1]) - Int(px[row + x + 1])
                                - Int(px[row - w + x]) - Int(px[row + w + x])
                let l = Double(lap)
                lapSum += l; lapSumSq += l * l
                let ci = Double(c)
                intSum += ci; intSumSq += ci * ci
                n += 1
            }
        }
        guard n > 0 else { return 0 }
        let lapVar = max(0, lapSumSq / n - (lapSum / n) * (lapSum / n))
        let intVar = max(1, intSumSq / n - (intSum / n) * (intSum / n))
        return lapVar / intVar
    }
}

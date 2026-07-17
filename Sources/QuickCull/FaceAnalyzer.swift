import AppKit
import Vision
import CoreImage
import ImageIO

/// One detected face and its grades.
struct FaceInfo: Codable {
    let rect: CGRect          // normalized, Vision coordinates (origin bottom-left)
    let eyeOpenness: CGFloat  // average of both eyes; < 0.17 ≈ blink
    let quality: Float?       // Vision face-capture quality 0–1
    let smileScore: CGFloat?  // mouth-corner lift; > ~0.015 ≈ smiling

    var smiling: Bool { (smileScore ?? 0) > 0.015 }
    var lowQuality: Bool { (quality ?? 1) < 0.25 }

    /// Blink = eye aperture below a floor. The floor is smile-aware: a real
    /// smile squints the eyes (raised cheeks push the lower lid up), so a
    /// grinning subject's eyes are genuinely narrower than a neutral face's.
    /// Judging a smiling squint by the neutral threshold produced constant
    /// false blinks - a laughing subject in glasses reads identical to a
    /// closed eye. So when the face is clearly smiling we drop the line to
    /// 0.14; neutral faces keep the stricter 0.17. Real blinks still trip it
    /// (a full blink collapses the aperture well below 0.14); it just stops
    /// punishing people for enjoying themselves.
    // Smiling faces get a LOW blink line (0.10): a joyful squint reads
    // nearly closed on any geometric measure, and red drives reject
    // decisions - a laughing kid shouldn't torpedo the frame. The squint
    // band above it (amber, "check") catches exactly that case instead.
    var blinking: Bool { eyeOpenness < (smiling ? 0.10 : 0.16) }
    /// Narrow-but-not-closed: a joyful squint is genuinely ambiguous - the UI
    /// shows it as its own state instead of guessing open/closed.
    var squinting: Bool { !blinking && eyeOpenness < 0.19 }
}

/// Per-photo face analysis.
struct FaceAnalysis: Codable {
    let faces: [FaceInfo]

    var faceCount: Int { faces.count }
    var eyesClosedCount: Int { faces.filter { $0.blinking }.count }
    var hasClosedEyes: Bool { eyesClosedCount > 0 }
    var minFaceQuality: Float? { faces.compactMap { $0.quality }.min() }
    var lowQualityFace: Bool { (minFaceQuality ?? 1) < 0.25 }
}

/// Cuts face crops for display panels. Cached per photo so flipping between
/// frames of the same group doesn't re-decode; crops are cut ONLY for photos
/// actually being inspected - never for the whole folder.
final class FaceCropper {
    static let shared = FaceCropper()
    private let cache = NSCache<NSString, NSArray>()

    private init() {
        cache.countLimit = 24 // two dozen photos' worth of tiny crops
    }

    /// Completion fires on the main thread with (crop, info) pairs in
    /// left-to-right photo order. Empty when unanalyzed or no faces.
    func crops(for asset: PhotoAsset, maxFaces: Int = 16, completion: @escaping ([(NSImage, FaceInfo)]) -> Void) {
        guard let analysis = FaceAnalyzer.shared.result(for: asset.id), !analysis.faces.isEmpty else {
            completion([])
            return
        }
        let faces = Array(analysis.faces.prefix(maxFaces))
        if let cached = cache.object(forKey: asset.id as NSString) as? [NSImage], cached.count == faces.count {
            completion(Array(zip(cached, faces)))
            return
        }
        let url = asset.url
        let id = asset.id
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var images: [NSImage] = []
            var pairs: [(NSImage, FaceInfo)] = []
            if let cg = FaceAnalyzer.analysisDecode(url: url, maxPixel: 2048) {
                let W = CGFloat(cg.width), H = CGFloat(cg.height)
                for face in faces {
                    let r = face.rect
                    // Vision rects are bottom-left origin; CGImage crops top-left.
                    var px = CGRect(x: r.minX * W, y: (1 - r.maxY) * H, width: r.width * W, height: r.height * H)
                    px = px.insetBy(dx: -px.width * 0.18, dy: -px.height * 0.18)
                        .intersection(CGRect(x: 0, y: 0, width: W, height: H))
                    guard !px.isNull, px.width > 4, let crop = cg.cropping(to: px) else { continue }
                    let image = NSImage(cgImage: crop, size: .zero)
                    images.append(image)
                    pairs.append((image, face))
                }
            }
            DispatchQueue.main.async {
                if pairs.count == faces.count {
                    self?.cache.setObject(images as NSArray, forKey: id as NSString)
                }
                completion(pairs)
            }
        }
    }
}

/// AI as an ANNOTATOR, never a gatekeeper. Everything here runs on a single
/// background-QoS operation - macOS scheduling guarantees it yields to the
/// user-initiated thumbnail/preview decodes, so culling speed is untouched.
/// Results trickle onto thumbnails as they land; if you cull faster than the
/// analyzer, you simply beat it. Uses Apple's on-device Vision + CoreImage -
/// nothing is downloaded, nothing leaves the machine.
final class FaceAnalyzer {

    static let shared = FaceAnalyzer()

    /// Fired on the main thread as each photo's analysis lands (asset id).
    var onResult: ((String) -> Void)?
    /// Fired on the main thread with (done, total) for the current folder.
    var onProgress: ((Int, Int) -> Void)?

    private var results: [String: FaceAnalysis] = [:] // main thread only
    private let queue: OperationQueue
    private var generation = 0
    private var done = 0
    private(set) var total = 0

    /// Pending operations by asset id - lets the UI bump the photo the user
    /// is actually looking at to the front of the queue.
    private var pendingOps: [String: Operation] = [:] // main thread only

    private init() {
        // Serial: one lane can never crowd the decode queues. .utility (not
        // .background) so macOS doesn't starve it indefinitely under load -
        // "the scan never happens" was background-QoS starvation.
        queue = OperationQueue()
        queue.name = "quickcull.faceanalysis"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
    }

    var isScanning: Bool { total > 0 && done < total }

    /// The user is looking at this photo - analyze it next.
    func prioritize(_ id: String) {
        pendingOps[id]?.queuePriority = .veryHigh
    }

    func result(for id: String) -> FaceAnalysis? { results[id] }
    var doneCount: Int { done }

    /// Force a fresh scan of specific photos (a verdict went rogue).
    func rescan(_ assets: [PhotoAsset]) {
        for asset in assets {
            results.removeValue(forKey: asset.id)
            if let identity = CacheDB.identity(for: asset.url) {
                CacheDB.shared.delete(identity + "|faces-v9")
            }
        }
        analyzeFolder(assets)
        for asset in assets { prioritize(asset.id) }
    }

    /// Testing aid: forget every in-memory verdict.
    func clearResults() {
        generation += 1
        queue.cancelAllOperations()
        pendingOps.removeAll()
        results.removeAll()
        done = 0
        total = 0
        onProgress?(0, 0)
    }

    /// THE faces switch - deliberately the same preference as the expanded
    /// view's faces panel (Tab). The panel IS the feature: panel open →
    /// scanning runs; panel closed → no watts spent looking. One concept,
    /// one control, no separate toolbar toggle.
    var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "QuickCullShowFaces") == nil
                ? true
                : UserDefaults.standard.bool(forKey: "QuickCullShowFaces")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "QuickCullShowFaces")
            if !newValue {
                queue.cancelAllOperations()
                done = 0
                total = 0
                onProgress?(0, 0)
            }
        }
    }

    /// Queue analysis for a folder. Photos analyzed in a previous session of
    /// this folder are skipped (results are keyed by path and kept).
    func analyzeFolder(_ assets: [PhotoAsset]) {
        generation += 1
        let gen = generation
        queue.cancelAllOperations()
        pendingOps.removeAll()
        guard isEnabled else {
            done = 0
            total = 0
            onProgress?(0, 0)
            return
        }

        // Never scan photos still on a memory card - every analysis is a
        // multi-MB read stealing bandwidth from the thumbnails the user is
        // actually waiting on. Cards get analyzed after ingest, from the SSD.
        let pending = assets.filter { results[$0.id] == nil && !FileOps.isMemoryCard($0.url) }
        done = 0
        total = pending.count
        guard !pending.isEmpty else {
            onProgress?(0, 0)
            return
        }

        for asset in pending {
            let id = asset.id
            let url = asset.url
            let op = BlockOperation()
            op.addExecutionBlock { [weak self, weak op] in
                guard let self, let op, !op.isCancelled else { return }
                // Persistent cache: bump "v" when the detector changes so old
                // verdicts re-derive.
                let cacheKey = CacheDB.identity(for: url).map { $0 + "|faces-v9" }
                var analysis: FaceAnalysis?
                if let cacheKey, let data = CacheDB.shared.get(cacheKey) {
                    analysis = try? JSONDecoder().decode(FaceAnalysis.self, from: data)
                }
                if analysis == nil {
                    analysis = Self.analyze(url: url)
                    if let cacheKey, let analysis, let data = try? JSONEncoder().encode(analysis) {
                        CacheDB.shared.set(cacheKey, data)
                    }
                }
                let final = analysis ?? FaceAnalysis(faces: [])
                DispatchQueue.main.async {
                    guard gen == self.generation else { return }
                    self.pendingOps[id] = nil
                    self.results[id] = final
                    self.done += 1
                    self.onResult?(id)
                    self.onProgress?(self.done, self.total)
                }
            }
            pendingOps[id] = op
            queue.addOperation(op)
        }
    }

    // MARK: - The actual analysis (background thread)

    private struct DetectedFace {
        let rect: CGRect       // full-image normalized, bottom-left origin
        let openness: CGFloat
        let smile: CGFloat?
    }

    private static func analyze(url: URL) -> FaceAnalysis {
        autoreleasepool {
            guard let cg = analysisDecode(url: url, maxPixel: 3072) else {
                return FaceAnalysis(faces: [])
            }
            let W = CGFloat(cg.width), H = CGFloat(cg.height)

            // Pass 1: whole frame.
            var found = detectFaces(in: cg, mappedTo: CGRect(x: 0, y: 0, width: 1, height: 1))

            // Pass 2: four overlapping quadrants at full analysis resolution.
            // A kid's face that spans 40px in the whole frame spans ~110px in
            // its quadrant. Triggered by ANY hint of a group - two faces, or
            // one small face - so a weak whole-frame pass can't silently
            // disable its own rescue (the "found 2 of 25" failure mode).
            let smallFacePresent = found.contains { $0.rect.height < 0.14 }
            if found.count >= 2 || smallFacePresent {
                let frac: CGFloat = 0.6
                let corners: [(CGFloat, CGFloat)] = [(0, 0), (1 - frac, 0), (0, 1 - frac), (1 - frac, 1 - frac)]
                for (fx, fy) in corners { // fx, fy in CG top-left normalized
                    let pixelRect = CGRect(x: fx * W, y: fy * H, width: frac * W, height: frac * H).integral
                    guard let tile = cg.cropping(to: pixelRect) else { continue }
                    // The tile's region expressed in bottom-left normalized coords:
                    let region = CGRect(x: fx, y: 1 - fy - frac, width: frac, height: frac)
                    for face in detectFaces(in: tile, mappedTo: region) {
                        if !found.contains(where: { overlap($0.rect, face.rect) > 0.3 }) {
                            found.append(face)
                        }
                    }
                }
            }

            // Pass 3: per-face landmark REFINEMENT for small faces. In a
            // group shot a face can be ~100px tall in the analysis image,
            // leaving the eye region ~25px wide - the landmark net is fitting
            // a contour through noise, and eye-state judgments downstream
            // (blink/squint, and glasses especially) inherit that noise.
            // Re-running landmarks on a tight crop lets the face fill the
            // model's input, so the eye geometry is measured at full fidelity.
            // Keep the frame-level rect (more stable); adopt refined
            // openness/smile only when the crop pass confidently re-finds
            // the same face.
            for i in found.indices where found[i].rect.height * H < 320 {
                let r = found[i].rect
                var px = CGRect(x: r.minX * W, y: (1 - r.maxY) * H,
                                width: r.width * W, height: r.height * H)
                px = px.insetBy(dx: -px.width * 0.35, dy: -px.height * 0.35)
                    .intersection(CGRect(x: 0, y: 0, width: W, height: H))
                    .integral
                guard !px.isNull, px.width > 16, let crop = cg.cropping(to: px) else { continue }
                let region = CGRect(x: px.minX / W, y: 1 - (px.minY + px.height) / H,
                                    width: px.width / W, height: px.height / H)
                let refined = detectFaces(in: crop, mappedTo: region)
                if let best = refined.max(by: { overlap($0.rect, r) < overlap($1.rect, r) }),
                   overlap(best.rect, r) > 0.3 {
                    found[i] = DetectedFace(rect: r, openness: best.openness,
                                            smile: best.smile ?? found[i].smile)
                }
            }

            // Face quality from the whole frame, matched per face.
            let qualityRequest = VNDetectFaceCaptureQualityRequest()
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([qualityRequest])
            let qualityObservations = qualityRequest.results ?? []

            var infos: [FaceInfo] = []
            for face in found {
                var quality: Float?
                if let best = qualityObservations.max(by: {
                    overlap($0.boundingBox, face.rect) < overlap($1.boundingBox, face.rect)
                }), overlap(best.boundingBox, face.rect) > 0.1 {
                    quality = best.faceCaptureQuality
                }
                infos.append(FaceInfo(rect: face.rect, eyeOpenness: face.openness,
                                      quality: quality, smileScore: face.smile))
            }
            infos.sort { $0.rect.minX < $1.rect.minX } // left-to-right, like the photo
            return FaceAnalysis(faces: infos)
        }
    }

    /// Run landmark detection on an image (or tile) and map results into
    /// full-image coordinates via `mappedTo`.
    private static func detectFaces(in cg: CGImage, mappedTo region: CGRect) -> [DetectedFace] {
        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        var out: [DetectedFace] = []
        for observation in request.results ?? [] {
            // Pareidolia gate: Vision sometimes "finds" a face in skin-toned
            // texture - clasped hands, elbows, tree bark. Hallucinations
            // usually come back WITHOUT fitted eye landmarks, which then
            // defaulted to "eyes wide open, quality fine" and green-ringed a
            // hand. No eyes → nothing to triage → not a face we show.
            guard let landmarks = observation.landmarks,
                  let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye else { continue }
            // Pareidolia gate 2: landmarks EXISTING isn't enough - Vision
            // happily hallucinates "eyes" on toes, hands, and bokeh blobs
            // (a sandaled foot shipped a green ring to prove it). Demand the
            // landmarks be ARRANGED like a face: decent confidence, eyes
            // ordered left-to-right with real separation, roughly level, and
            // a mouth clearly below them. Real faces - even tilted, even in
            // profile-ish poses - pass with margin; body parts don't.
            guard landmarks.confidence >= 0.5 else { continue }
            let le = Self.centroid(leftEye)
            let re = Self.centroid(rightEye)
            guard abs(re.x - le.x) > 0.08,                  // truly separated
                  abs(le.y - re.y) < 0.35 else { continue } // level-ish (tilt-tolerant)
            if let lips = landmarks.outerLips {
                let mouth = Self.centroid(lips)
                let eyeMidY = (le.y + re.y) / 2
                guard eyeMidY - mouth.y > 0.08 else { continue } // mouth below eyes
            }
            let openness = (eyeOpenness(landmarks.leftEye) + eyeOpenness(landmarks.rightEye)) / 2
            let smile = smileScore(landmarks.outerLips)
            let b = observation.boundingBox
            let mapped = CGRect(x: region.minX + b.minX * region.width,
                                y: region.minY + b.minY * region.height,
                                width: b.width * region.width,
                                height: b.height * region.height)
            out.append(DetectedFace(rect: mapped, openness: openness, smile: smile))
        }
        return out
    }

    /// Mean point of a landmark region (face-normalized coordinates).
    private static func centroid(_ region: VNFaceLandmarkRegion2D) -> CGPoint {
        let pts = region.normalizedPoints
        guard !pts.isEmpty else { return .zero }
        let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(pts.count), y: sum.y / CGFloat(pts.count))
    }

    /// Intersection-over-union of two normalized rects.
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0 else { return 0 }
        let union = a.width * a.height + b.width * b.height - inter.width * inter.height
        return union > 0 ? (inter.width * inter.height) / union : 0
    }

    /// Mouth-corner lift relative to mouth center: positive = smile.
    private static func smileScore(_ region: VNFaceLandmarkRegion2D?) -> CGFloat? {
        guard let region, region.pointCount >= 6 else { return nil }
        var pts: [CGPoint] = []
        for i in 0..<region.pointCount { pts.append(region.normalizedPoints[i]) }
        guard let leftCorner = pts.min(by: { $0.x < $1.x }),
              let rightCorner = pts.max(by: { $0.x < $1.x }) else { return nil }
        let centerY = pts.reduce(0) { $0 + $1.y } / CGFloat(pts.count)
        let width = rightCorner.x - leftCorner.x
        guard width > 0.0001 else { return nil }
        // Closed-lip smile: corners lift above the lip centroid.
        let cornerLift = ((leftCorner.y + rightCorner.y) / 2 - centerY) / width
        // Open-mouth grin: corner-lift collapses toward zero when the mouth is
        // open (the corners sit near mid-mouth), so an obvious teeth-baring
        // smile read as "not smiling." Add a term for a mouth that is OPEN and
        // clearly wider than it is tall - a grin, not an O of surprise/speech.
        let ys = pts.map { $0.y }
        let openHeight = (ys.max() ?? centerY) - (ys.min() ?? centerY)
        let grin: CGFloat = (openHeight > 0.05 && width > openHeight * 1.4) ? (openHeight - 0.05) * 0.6 : 0
        return max(cornerLift, grin)
    }

    /// Height/width ratio of the eye outline in face-normalized coordinates.
    private static func eyeOpenness(_ region: VNFaceLandmarkRegion2D?) -> CGFloat {
        // Spread of the lid points around the corner-to-corner CHORD - not the
        // bounding box. The bbox conflated opening with curvature: a fully
        // closed eye arced upward by a big smile has bbox height from the arc
        // alone, so it read "open" (the green-ringed closed-eyed kid). An open
        // eye has points on BOTH sides of the chord (upper lid above, lower
        // below); a closed eye - however curved - has all its points on one
        // arc, so its above/below spread collapses toward zero.
        guard let region, region.pointCount >= 4 else { return 1 }
        var pts: [CGPoint] = []
        for i in 0..<region.pointCount { pts.append(region.normalizedPoints[i]) }
        guard let left = pts.min(by: { $0.x < $1.x }),
              let right = pts.max(by: { $0.x < $1.x }) else { return 1 }
        let dx = right.x - left.x, dy = right.y - left.y
        let chord = sqrt(dx * dx + dy * dy)
        guard chord > 0.0001 else { return 1 }
        var maxOff: CGFloat = 0, minOff: CGFloat = 0
        for p in pts {
            // Signed perpendicular distance from the chord (cross product).
            let off = (dx * (p.y - left.y) - dy * (p.x - left.x)) / chord
            maxOff = max(maxOff, off); minOff = min(minOff, off)
        }
        return (maxOff - minOff) / chord
    }

    /// Small standalone decode - deliberately does NOT touch ThumbnailLoader's
    /// caches or queues, so analysis can never evict or delay UI pixels.
    /// Also used by the inspector to cut face crops (same orientation as the
    /// rects were computed in).
    static func analysisDecode(url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let embedded: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        let embeddedResult = CGImageSourceCreateThumbnailAtIndex(source, 0, embedded as CFDictionary)

        // QUALITY FLOOR: ImageIO sometimes hands back the RAW's tiny 160px
        // thumbnail instead of the big preview. Faces analyzed at that size
        // silently vanish (the "found 2 of 25" bug). If the embedded result
        // is too small to trust, pay for a real decode.
        if let cg = embeddedResult, CGFloat(max(cg.width, cg.height)) >= min(1200, maxPixel * 0.4) {
            return cg
        }
        let forced: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, forced as CFDictionary) ?? embeddedResult
    }
}

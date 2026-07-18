import Foundation

/// Prototype ratings store: optimistic in-memory state, debounced JSON
/// persistence in Application Support. The real product writes XMP
/// (embedded or sidecar) so ratings travel to Lightroom/Capture One -
/// this store is deliberately invisible plumbing, not a catalog.
final class RatingsStore {

    static let shared = RatingsStore()

    private(set) var ratings: [String: Int] = [:]   // asset id → 1...5
    private(set) var rejected: Set<String> = []
    private(set) var colorLabels: [String: Int] = [:] // asset id → 1...5 class
    private(set) var rotations: [String: Int] = [:]   // asset id → degrees CW (0/90/180/270)

    /// Tombstones: the user EXPLICITLY cleared this value. Without these,
    /// adopt() can't tell "never rated here" from "deliberately cleared",
    /// and a stale sidecar (foreign, or ours mid-flush) resurrects the old
    /// value on the next folder scan - the "cleared reds come back" bug.
    private var clearedRatings: Set<String> = []
    private var clearedLabels: Set<String> = []

    private var saveScheduled = false

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("QuickCull", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ratings.json")
    }

    private init() {
        load()
    }

    func rating(for id: String) -> Int { ratings[id] ?? 0 }
    func isRejected(_ id: String) -> Bool { rejected.contains(id) }
    func colorLabel(for id: String) -> Int { colorLabels[id] ?? 0 }

    // MARK: - Cull input mode (color-first)

    /// Broadcast (main thread) whenever `colorFirstRating` flips, so footers,
    /// hint labels and the menu checkmark can refresh.
    static let cullModeChanged = Notification.Name("QuickCullCullModeChanged")
    private static let colorFirstKey = "QuickCullColorFirstRating"

    /// When true (DEFAULT), the bare number keys 1–5 apply COLOR labels and
    /// ⌃1–5 apply star ratings; when false it's the reverse. Persisted so the
    /// choice survives launches; posts `cullModeChanged` on change.
    var colorFirstRating: Bool {
        get {
            // Default to color-first when the user has never chosen.
            if UserDefaults.standard.object(forKey: Self.colorFirstKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.colorFirstKey)
        }
        set {
            guard newValue != UserDefaults.standard.bool(forKey: Self.colorFirstKey) else { return }
            UserDefaults.standard.set(newValue, forKey: Self.colorFirstKey)
            NotificationCenter.default.post(name: Self.cullModeChanged, object: nil)
        }
    }

    /// Whether a digit press with the given Control state should set a STAR
    /// rating (vs a color label), honoring color-first mode. Normal mode:
    /// bare digit = star, ⌃digit = color. Color-first mode: reversed.
    func digitSetsStar(control: Bool) -> Bool {
        colorFirstRating ? control : !control
    }

    func setRating(_ value: Int, for id: String) {
        if value <= 0 {
            if ratings[id] != nil { clearedRatings.insert(id) }
            ratings[id] = nil
        } else {
            ratings[id] = min(value, 5)
            clearedRatings.remove(id)
            rejected.remove(id) // rating a photo un-rejects it
        }
        scheduleSave()
        markXMPDirty(id)
    }

    func toggleRejected(_ id: String) {
        if rejected.contains(id) {
            rejected.remove(id)
        } else {
            rejected.insert(id)
            ratings[id] = nil
        }
        scheduleSave()
    }

    func setColorLabel(_ value: Int, for id: String) {
        if value <= 0 {
            if colorLabels[id] != nil { clearedLabels.insert(id) }
            colorLabels[id] = nil
        } else {
            colorLabels[id] = min(value, 5)
            clearedLabels.remove(id)
        }
        scheduleSave()
        markXMPDirty(id)
    }

    func rotation(for id: String) -> Int { rotations[id] ?? 0 }

    func rotate(_ id: String, by degrees: Int) {
        let next = (((rotations[id] ?? 0) + degrees) % 360 + 360) % 360
        rotations[id] = next == 0 ? nil : next
        scheduleSave()
        markXMPDirty(id)
    }

    /// A file was renamed: its cull data follows it to the new identity.
    func migrate(from oldID: String, to newID: String) {
        if let rating = ratings.removeValue(forKey: oldID) { ratings[newID] = rating }
        if rejected.remove(oldID) != nil { rejected.insert(newID) }
        if let color = colorLabels.removeValue(forKey: oldID) { colorLabels[newID] = color }
        if let rotation = rotations.removeValue(forKey: oldID) { rotations[newID] = rotation }
        if clearedRatings.remove(oldID) != nil { clearedRatings.insert(newID) }
        if clearedLabels.remove(oldID) != nil { clearedLabels.insert(newID) }
        scheduleSave()
    }

    /// A COPY inherits the original's cull values - the original keeps its
    /// own. (Without this, ⌘C/⌘V produced an unrated duplicate: move carried
    /// values via transfer(), copy carried nothing.) Tombstones don't copy -
    /// a fresh file has nothing "deliberately cleared" yet - and no XMP write
    /// is queued: the RAW's sidecar was copied along with it on disk.
    func copyValues(from sourceID: String, to newID: String) {
        guard sourceID != newID else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.copyValues(from: sourceID, to: newID) }
            return
        }
        var changed = false
        if let v = ratings[sourceID] { ratings[newID] = v; changed = true }
        if let v = colorLabels[sourceID] { colorLabels[newID] = v; changed = true }
        if let v = rotations[sourceID] { rotations[newID] = v; changed = true }
        if rejected.contains(sourceID) { rejected.insert(newID); changed = true }
        if changed { scheduleSave() }
    }

    /// A photo's identity is its PATH - so when a file MOVES, every cull
    /// value must move with it or the label silently stays behind under the
    /// old path (the "moved photos vanish from a color filter" bug). Also
    /// carries the cleared-tombstones so a deliberate clear survives a move,
    /// and the dirty/in-flight XMP markers so a pending sidecar write isn't
    /// orphaned. No XMP rewrite: the sidecar traveled with the file.
    func transfer(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
        // Callers can be on a background queue - the sidebar drop runs
        // FileOps.move off-main so a 2,000-photo drop can't beach-ball -
        // but this store's state is main-thread-only. Hop if needed.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.transfer(from: oldID, to: newID) }
            return
        }
        var changed = false
        if let v = ratings.removeValue(forKey: oldID) { ratings[newID] = v; changed = true }
        if let v = colorLabels.removeValue(forKey: oldID) { colorLabels[newID] = v; changed = true }
        if let v = rotations.removeValue(forKey: oldID) { rotations[newID] = v; changed = true }
        if rejected.remove(oldID) != nil { rejected.insert(newID); changed = true }
        if clearedRatings.remove(oldID) != nil { clearedRatings.insert(newID); changed = true }
        if clearedLabels.remove(oldID) != nil { clearedLabels.insert(newID); changed = true }
        if xmpDirty.remove(oldID) != nil { xmpDirty.insert(newID) }
        if changed { scheduleSave() }
    }

    /// Adopt values found in a sidecar written by another app (Lightroom,
    /// Photo Mechanic). Local values win; adoption never triggers a rewrite.
    /// Values the user explicitly cleared, and values whose sidecar write is
    /// still in flight, are never adopted - local truth outranks stale disk.
    @discardableResult
    func adopt(rating: Int?, label: Int?, for id: String) -> Bool {
        guard !xmpDirty.contains(id), !xmpInFlight.contains(id) else { return false }
        var changed = false
        if let rating, rating > 0, ratings[id] == nil, !clearedRatings.contains(id) {
            ratings[id] = min(rating, 5)
            changed = true
        }
        if let label, label > 0, colorLabels[id] == nil, !clearedLabels.contains(id) {
            colorLabels[id] = min(label, 5)
            changed = true
        }
        if changed { scheduleSave() }
        return changed
    }

    // MARK: - XMP sidecar writing (debounced, background, RAW-only)

    /// Posted (on main) whenever a sidecar flush touches disk - the grid
    /// uses it to ignore the folder-watcher events our own writes cause.
    static let xmpFlushActivity = Notification.Name("QuickCullXMPFlushActivity")

    private var xmpDirty: Set<String> = []
    private var xmpInFlight: Set<String> = []
    private var xmpFlushScheduled = false
    /// SERIAL queue: two overlapping bulk edits (all→red, then all→none)
    /// must flush in order - concurrent batches interleave per-file and an
    /// old value can land after the new one.
    private let xmpQueue = DispatchQueue(label: "quickcull.xmpflush", qos: .utility)

    private func markXMPDirty(_ id: String) {
        xmpDirty.insert(id)
        guard !xmpFlushScheduled else { return }
        xmpFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.xmpFlushScheduled = false
            let batch = self.xmpDirty.map { id in
                (id, self.rating(for: id), self.colorLabel(for: id), self.rotation(for: id))
            }
            self.xmpDirty.removeAll()
            self.xmpInFlight.formUnion(batch.map { $0.0 })
            NotificationCenter.default.post(name: Self.xmpFlushActivity, object: nil)
            self.xmpQueue.async {
                for (id, rating, label, rotationDegrees) in batch {
                    let url = URL(fileURLWithPath: id)
                    // Sidecars for RAW files only - Lightroom ignores JPEG
                    // sidecars, and we never rewrite originals.
                    guard PhotoAsset.rawExtensions.contains(url.pathExtension.lowercased()),
                          FileManager.default.fileExists(atPath: url.path) else { continue }
                    var orientation: Int?
                    if rotationDegrees != 0 {
                        orientation = XMPSidecar.orientationCode(
                            containerOrientation: ImageTransform.containerOrientation(of: url),
                            plusDegreesCW: rotationDegrees)
                    }
                    XMPSidecar.write(rating: rating, label: label, orientation: orientation, for: url)
                }
                DispatchQueue.main.async {
                    self.xmpInFlight.subtract(batch.map { $0.0 })
                    NotificationCenter.default.post(name: Self.xmpFlushActivity, object: nil)
                }
            }
        }
    }

    /// SYNCHRONOUS sidecar drain - every pending XMP hits disk before this
    /// returns. Called before hand-offs (→ Lightroom/Photoshop import the
    /// files IMMEDIATELY; the 0.8 s debounce meant rate-then-send lost the
    /// last edits - "my red labels aren't in Lightroom") and at quit.
    func flushXMPNow() {
        assert(Thread.isMainThread)
        let batch = xmpDirty.map { id in
            (id, rating(for: id), colorLabel(for: id), rotation(for: id))
        }
        xmpDirty.removeAll()
        // Drain any in-flight background flush first so we can't interleave.
        xmpQueue.sync {}
        for (id, rating, label, rotationDegrees) in batch {
            let url = URL(fileURLWithPath: id)
            guard PhotoAsset.rawExtensions.contains(url.pathExtension.lowercased()),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            var orientation: Int?
            if rotationDegrees != 0 {
                orientation = XMPSidecar.orientationCode(
                    containerOrientation: ImageTransform.containerOrientation(of: url),
                    plusDegreesCW: rotationDegrees)
            }
            XMPSidecar.write(rating: rating, label: label, orientation: orientation, for: url)
        }
    }

    /// Quit-time flush: pending sidecars + the JSON store, synchronously.
    func flushForTermination() {
        flushXMPNow()
        // 2. The JSON store, synchronously.
        let snap = Snapshot(ratings: ratings, rejected: Array(rejected),
                            colorLabels: colorLabels, rotations: rotations,
                            clearedRatings: Array(clearedRatings),
                            clearedLabels: Array(clearedLabels))
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var ratings: [String: Int]
        var rejected: [String]
        var colorLabels: [String: Int]
        var rotations: [String: Int]? // optional: reads pre-rotation files
        var clearedRatings: [String]? // optional: reads pre-tombstone files
        var clearedLabels: [String]?
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        ratings = snap.ratings
        rejected = Set(snap.rejected)
        colorLabels = snap.colorLabels
        rotations = snap.rotations ?? [:]
        clearedRatings = Set(snap.clearedRatings ?? [])
        clearedLabels = Set(snap.clearedLabels ?? [])
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            // Snapshot on main (state is main-only); encode + write on a
            // background queue - during a rating burst this fires every
            // 0.5 s, and a big store shouldn't cost the keyboard rhythm.
            let snap = Snapshot(ratings: self.ratings, rejected: Array(self.rejected),
                                colorLabels: self.colorLabels, rotations: self.rotations,
                                clearedRatings: Array(self.clearedRatings),
                                clearedLabels: Array(self.clearedLabels))
            let dest = self.fileURL
            DispatchQueue.global(qos: .utility).async {
                if let data = try? JSONEncoder().encode(snap) {
                    try? data.write(to: dest, options: .atomic)
                }
            }
        }
    }
}

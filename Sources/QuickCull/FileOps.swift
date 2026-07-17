import Foundation

/// File operations for culling: move and trash, always carrying a photo's
/// companions along (paired JPEG, XMP sidecar) so pairs never split.
/// The directory stays the source of truth - no database to update.
enum FileOps {

    /// Cached per volume. Main thread only.
    private static var removableCache: [String: Bool] = [:]

    /// Posted on the main thread after a move WE initiated completes, with
    /// userInfo["sources"] = the folders files LEFT. The grid reloads the
    /// affected folder immediately instead of waiting for the throttled
    /// filesystem watcher - the "ghost photos linger after a drag" fix.
    static let filesMoved = Notification.Name("QuickCullFilesMoved")

    /// Is this file on a memory card / external drive? Governs how gently
    /// we treat the volume: fewer I/O lanes, no background face scans, no
    /// speculative preview prefetches.
    static func isOnRemovableVolume(_ url: URL) -> Bool {
        // Directory-level memo: every file in a folder shares its volume, so
        // the FIRST file answers for all its siblings. Without this, callers
        // that sweep a whole folder (face gating, prefetch gates) issued one
        // volume-resolution syscall PER FILE on the main thread - thousands
        // per folder click, and measurably slower on external drives.
        let dir = url.deletingLastPathComponent().path
        if let cached = removableDirCache[dir] { return cached }
        let volumePath = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path ?? "/"
        if let cached = removableCache[volumePath] { removableDirCache[dir] = cached; return cached }
        let values = try? URL(fileURLWithPath: volumePath).resourceValues(
            forKeys: [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey])
        let removable = (values?.volumeIsRemovable ?? false)
            || (values?.volumeIsEjectable ?? false)
            || !(values?.volumeIsInternal ?? true)
        removableCache[volumePath] = removable
        removableDirCache[dir] = removable
        return removable
    }

    private static var removableDirCache: [String: Bool] = [:]
    private static var memoryCardCache: [String: Bool] = [:]
    private static var memoryCardDirCache: [String: Bool] = [:]

    /// Narrow: true ONLY for real removable media - SD/CF cards, USB flash.
    /// External HDDs and SSDs report ejectable-but-not-removable, so this is
    /// false for them. Lots of people work straight off external drives, so
    /// those are treated like local disks (face scans run, etc.); only actual
    /// cards are held back (slow + read-only mid-shoot → scan after ingest).
    static func isMemoryCard(_ url: URL) -> Bool {
        // Same directory-level memo as isOnRemovableVolume - see above.
        let dir = url.deletingLastPathComponent().path
        if let cached = memoryCardDirCache[dir] { return cached }
        let volumePath = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path ?? "/"
        if let cached = memoryCardCache[volumePath] { memoryCardDirCache[dir] = cached; return cached }
        let v = try? URL(fileURLWithPath: volumePath).resourceValues(forKeys: [.volumeIsRemovableKey])
        let isCard = v?.volumeIsRemovable ?? false
        memoryCardCache[volumePath] = isCard
        memoryCardDirCache[dir] = isCard
        return isCard
    }

    /// Same-basename files that must travel with a photo (paired JPEG,
    /// XMP sidecar). Deduped by canonical file identity: on the default
    /// case-INSENSITIVE APFS, "x.xmp" and "x.XMP" are the SAME file and both
    /// report as existing - naive checking moved it once, then logged a
    /// failure trying to move it again under the other spelling.
    static func companions(of url: URL) -> [URL] {
        let base = url.deletingPathExtension()
        let fm = FileManager.default
        var result: [URL] = []
        var seenIdentities = Set<String>()
        // The photo itself must never be its own companion.
        seenIdentities.insert(canonicalIdentity(of: url))
        for ext in ["xmp", "XMP", "jpg", "JPG", "jpeg", "JPEG"] {
            let candidate = base.appendingPathExtension(ext)
            guard fm.fileExists(atPath: candidate.path) else { continue }
            if seenIdentities.insert(canonicalIdentity(of: candidate)).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    /// A stable identity for "is this the same physical file" that respects
    /// the volume's case sensitivity.
    private static func canonicalIdentity(of url: URL) -> String {
        if let canonical = (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath {
            return canonical
        }
        return url.path
    }

    /// First non-colliding destination: "name", "name 2", "name 3"…
    static func uniqueDestination(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var counter = 2
        repeat {
            let numbered = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            counter += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    struct OperationResult {
        let primaries: Int                    // photos affected
        let records: [(from: URL, to: URL)]   // every file's journey, for undo
        var skipped: Int = 0                  // collisions the user chose to skip
    }

    /// Finder-style collision handling. Decided per photo GROUP (RAW +
    /// JPEG pair + sidecar move as one unit, so a rename can't split a pair).
    enum Collision {
        case keepBoth   // rename incoming: "Name 2.CR3" (+ "Name 2.xmp"…)
        case skip       // leave colliding photos where they are
        case overwrite  // existing files go to the TRASH first - never rm
    }

    /// Would this photo (or any companion) land on an existing name?
    static func wouldCollide(_ url: URL, in folder: URL) -> Bool {
        let fm = FileManager.default
        return ([url] + companions(of: url)).contains {
            fm.fileExists(atPath: folder.appendingPathComponent($0.lastPathComponent).path)
        }
    }

    /// How many of these photos collide in `folder`? (Same-folder moves are
    /// no-ops and don't count.) Callers use this to decide whether to ask.
    static func collisionCount(_ urls: [URL], in folder: URL) -> Int {
        urls.filter { $0.deletingLastPathComponent().path != folder.path }
            .filter { wouldCollide($0, in: folder) }
            .count
    }

    /// One unique stem for the whole group - "IMG_1234 2" - so RAW, JPEG
    /// and sidecar keep matching names after a keep-both rename.
    private static func uniqueStem(for url: URL, in folder: URL) -> String {
        let fm = FileManager.default
        let stem = url.deletingPathExtension().lastPathComponent
        let exts = ([url] + companions(of: url)).map { $0.pathExtension }
        func taken(_ candidate: String) -> Bool {
            exts.contains { fm.fileExists(atPath: folder.appendingPathComponent("\(candidate).\($0)").path) }
        }
        var counter = 2
        var candidate = stem
        while taken(candidate) {
            candidate = "\(stem) \(counter)"
            counter += 1
        }
        return candidate
    }

    /// Move files (plus companions) into a folder.
    static func move(_ urls: [URL], to folder: URL, onCollision: Collision = .keepBoth) -> OperationResult {
        let fm = FileManager.default
        var moved = 0
        var skipped = 0
        var records: [(from: URL, to: URL)] = []
        for url in urls {
            // No-op if it's already there.
            guard url.deletingLastPathComponent().path != folder.path else { continue }
            let all = [url] + companions(of: url)
            var stem: String? = nil
            if wouldCollide(url, in: folder) {
                switch onCollision {
                case .skip:
                    skipped += 1
                    continue
                case .overwrite:
                    for file in all {
                        let existing = folder.appendingPathComponent(file.lastPathComponent)
                        if fm.fileExists(atPath: existing.path) {
                            try? fm.trashItem(at: existing, resultingItemURL: nil)
                        }
                    }
                case .keepBoth:
                    stem = uniqueStem(for: url, in: folder)
                }
            }
            var movedPrimary = false
            for file in all {
                let name = stem.map { file.pathExtension.isEmpty ? $0 : "\($0).\(file.pathExtension)" } ?? file.lastPathComponent
                let dest = folder.appendingPathComponent(name)
                do {
                    try fm.moveItem(at: file, to: dest)
                    records.append((from: file, to: dest))
                    if file.path == url.path {
                        movedPrimary = true
                        // Identity is the path - the cull values move too.
                        RatingsStore.shared.transfer(from: file.path, to: dest.path)
                    }
                } catch {
                    NSLog("funo: move failed for \(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if movedPrimary { moved += 1 }
        }
        if !records.isEmpty {
            let sources = Set(records.map { $0.from.deletingLastPathComponent().path })
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: FileOps.filesMoved, object: nil,
                                                userInfo: ["sources": Array(sources)])
            }
        }
        return OperationResult(primaries: moved, records: records, skipped: skipped)
    }

    /// Copy files (plus companions) into a folder. Pasting into the same
    /// folder duplicates ("name 2.CR3") - that's what the user asked for.
    static func copy(_ urls: [URL], to folder: URL, onCollision: Collision = .keepBoth) -> OperationResult {
        let fm = FileManager.default
        var copied = 0
        var skipped = 0
        var records: [(from: URL, to: URL)] = []
        for url in urls {
            let all = [url] + companions(of: url)
            var stem: String? = nil
            if wouldCollide(url, in: folder) {
                switch onCollision {
                case .skip:
                    skipped += 1
                    continue
                case .overwrite:
                    // Copy-over-self would destroy the original - same-folder
                    // duplicates always keep both, whatever the policy says.
                    if url.deletingLastPathComponent().path == folder.path {
                        stem = uniqueStem(for: url, in: folder)
                    } else {
                        for file in all {
                            let existing = folder.appendingPathComponent(file.lastPathComponent)
                            if fm.fileExists(atPath: existing.path) {
                                try? fm.trashItem(at: existing, resultingItemURL: nil)
                            }
                        }
                    }
                case .keepBoth:
                    stem = uniqueStem(for: url, in: folder)
                }
            }
            var copiedPrimary = false
            for file in all {
                let name = stem.map { file.pathExtension.isEmpty ? $0 : "\($0).\(file.pathExtension)" } ?? file.lastPathComponent
                let dest = folder.appendingPathComponent(name)
                do {
                    try fm.copyItem(at: file, to: dest)
                    records.append((from: file, to: dest))
                    if file.path == url.path {
                        copiedPrimary = true
                        // The duplicate inherits the original's cull values.
                        RatingsStore.shared.copyValues(from: file.path, to: dest.path)
                    }
                } catch {
                    NSLog("funo: copy failed for \(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if copiedPrimary { copied += 1 }
        }
        return OperationResult(primaries: copied, records: records, skipped: skipped)
    }

    /// Move files (plus companions) to the Trash - recoverable, never rm.
    static func trash(_ urls: [URL]) -> OperationResult {
        let fm = FileManager.default
        var trashed = 0
        var records: [(from: URL, to: URL)] = []
        for url in urls {
            let all = [url] + companions(of: url)
            var trashedPrimary = false
            for file in all {
                var landed: NSURL?
                do {
                    try fm.trashItem(at: file, resultingItemURL: &landed)
                    if let landed = landed as URL? { records.append((from: file, to: landed)) }
                    if file.path == url.path { trashedPrimary = true }
                } catch {
                    NSLog("funo: trash failed for \(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if trashedPrimary { trashed += 1 }
        }
        return OperationResult(primaries: trashed, records: records)
    }
}

/// Undo for file operations: every move/trash batch is recorded and can be
/// reversed with ⌘Z - files walk back to exactly where they came from.
enum FileOpsHistory {

    /// How to reverse a batch: moves walk files back; copies TRASH the
    /// copies (walking a copy "back" would spawn duplicates at the source).
    enum Kind { case move, copy }

    struct Batch {
        let description: String
        let kind: Kind
        let records: [(from: URL, to: URL)]
    }

    private(set) static var stack: [Batch] = [] // main thread only

    static func push(_ description: String, kind: Kind = .move, _ records: [(from: URL, to: URL)]) {
        guard !records.isEmpty else { return }
        stack.append(Batch(description: description, kind: kind, records: records))
        if stack.count > 30 { stack.removeFirst() }
    }

    static func popLatest() -> Batch? {
        stack.popLast()
    }

    /// Reverse the most recent batch. Returns a status message, or nil if
    /// there was nothing to undo. Call off the main thread.
    static func undoLatest(_ batch: Batch) -> String {
        let fm = FileManager.default
        var restored = 0
        switch batch.kind {
        case .move:
            for (from, to) in batch.records.reversed() {
                guard fm.fileExists(atPath: to.path) else { continue }
                let dest = FileOps.uniqueDestination(for: from.lastPathComponent,
                                                     in: from.deletingLastPathComponent())
                if (try? fm.moveItem(at: to, to: dest)) != nil {
                    restored += 1
                    RatingsStore.shared.transfer(from: to.path, to: dest.path)
                }
            }
            if restored > 0 {
                var dirs = Set(batch.records.map { $0.to.deletingLastPathComponent().path })
                dirs.formUnion(batch.records.map { $0.from.deletingLastPathComponent().path })
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: FileOps.filesMoved, object: nil,
                                                    userInfo: ["sources": Array(dirs)])
                }
            }
            return "Undid \(batch.description) - \(restored) file\(restored == 1 ? "" : "s") restored"
        case .copy:
            for (_, to) in batch.records.reversed() {
                guard fm.fileExists(atPath: to.path) else { continue }
                if (try? fm.trashItem(at: to, resultingItemURL: nil)) != nil { restored += 1 }
            }
            return "Undid \(batch.description) - \(restored) cop\(restored == 1 ? "y" : "ies") moved to Trash"
        }
    }
}

import Foundation
import CryptoKit

/// Card ingest: copy media off memory cards as fast as the hardware allows.
///
/// Speed levers (software's job is to not get in the way):
/// - Cards copy IN PARALLEL - two readers are two independent pipes.
/// - Within a card: strictly sequential, 8 MB blocks - no seek thrash,
///   no per-file syscall overhead dominating small files.
/// - SHA-256 computed from the bytes already in memory during the copy
///   (free), stored for deferred verification - never a second read pass
///   blocking the transfer.
/// - Writes land as ".qcpart" then rename: a yanked cable can't leave a
///   half-file that looks real.
/// - Sources are NEVER modified or deleted. Cards are sacred.
final class IngestJob {

    struct Progress {
        var filesDone = 0
        var filesTotal = 0
        var bytesDone: Int64 = 0
        var bytesTotal: Int64 = 0
        var skipped = 0
        var currentFile = ""
    }

    /// Main thread. Throttled to ~10 Hz.
    var onProgress: ((Progress) -> Void)?
    /// Main thread: (copied, skipped, errors)
    var onComplete: ((Int, Int, [String]) -> Void)?

    /// COPY AS pattern - {iseq} = 2-digit import number, {seq} = 4-digit
    /// file counter. nil/empty = keep original names. RAW+JPEG pairs share
    /// a source stem, so they share a renamed stem - pairs never split.
    var renamePattern: String?
    var ingestNumber = 1
    /// NEW ONLY: same name + same size already at destination → skip.
    var skipExisting = true
    /// STRUCTURE: true = keep the card's DCIM subfolders at destination.
    var preserveFolders = false
    private var stemMap: [String: String] = [:]

    private var cancelled = false
    private var progress = Progress()
    private var errors: [String] = []
    private var copied = 0
    private let accounting = DispatchQueue(label: "quickcull.ingest.accounting")
    private var lastEmit = Date.distantPast

    static let mediaExtensions: Set<String> = PhotoAsset.rawExtensions
        .union(PhotoAsset.jpegExtensions)
        .union(PhotoAsset.otherImageExtensions)
        .union(["mov", "mp4", "m4v", "avi", "mts", "m2ts", "mxf", "braw", "crm"])

    // MARK: - Card discovery

    /// A "card" is any removable-ish volume with a DCIM folder.
    static func detectCards() -> [URL] {
        let fm = FileManager.default
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                           options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { fm.fileExists(atPath: $0.appendingPathComponent("DCIM").path) }
    }

    /// A card's ingestable sections: its DCIM subfolders (100CANON,
    /// 101CANON…), or DCIM itself when the card has no subfolders.
    static func sections(of card: URL) -> [URL] {
        let fm = FileManager.default
        let dcim = card.appendingPathComponent("DCIM")
        let children = ((try? fm.contentsOfDirectory(at: dcim,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return children.isEmpty ? [dcim] : children
    }

    /// All media under any folder (a whole DCIM, one subfolder, whatever).
    static func mediaFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                         options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker {
            guard mediaExtensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            files.append(url)
        }
        files.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return files
    }

    /// Tokens: {seq} → 0001 file counter · {iseq} → 04 import number ·
    /// {date} → 20260717 capture date · {name} → original stem. A pattern
    /// with nothing unique per file ({seq} or {name}) gets _0001 appended -
    /// otherwise every file collides.
    static func applyPattern(_ pattern: String, seq: Int, ingest: Int,
                             date: Date = Date(), originalStem: String = "") -> String {
        var stem = pattern
            .replacingOccurrences(of: "{iseq}", with: String(format: "%02d", ingest))
            .replacingOccurrences(of: "{seq}", with: String(format: "%04d", seq))
            .replacingOccurrences(of: "{name}", with: originalStem)
        if stem.contains("{date}") {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd"
            stem = stem.replacingOccurrences(of: "{date}", with: formatter.string(from: date))
        }
        if !pattern.contains("{seq}") && !pattern.contains("{name}") {
            stem += String(format: "_%04d", seq)
        }
        return stem
    }

    // MARK: - The job

    func cancel() {
        cancelled = true
    }

    /// Sources can be whole cards, individual DCIM subfolders, any mix.
    /// Files are grouped into ONE sequential lane per physical volume -
    /// two subfolders of the same card must never compete for its pipe -
    /// while different cards run fully in parallel.
    func start(sources: [URL], destination: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Enumerate everything up front for a truthful progress bar,
            // grouping by volume.
            var lanes: [String: [URL]] = [:]
            var total = 0
            var totalBytes: Int64 = 0
            for source in sources {
                let volume = (try? source.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path ?? source.path
                let files = Self.mediaFiles(under: source)
                lanes[volume, default: []].append(contentsOf: files)
                total += files.count
                for file in files {
                    totalBytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                }
            }
            // Rename map: sequential by name across the WHOLE run, one
            // entry per stem - built before any lane starts, read-only after.
            if let pattern = self.renamePattern, !pattern.isEmpty {
                let all = lanes.values.flatMap { $0 }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                var seq = 0
                var map: [String: String] = [:]
                for file in all {
                    let stem = file.deletingPathExtension().lastPathComponent
                    if map[stem] == nil {
                        seq += 1
                        let captured = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                            .contentModificationDate ?? Date()
                        map[stem] = Self.applyPattern(pattern, seq: seq, ingest: self.ingestNumber,
                                                      date: captured, originalStem: stem)
                    }
                }
                self.stemMap = map
            }

            self.accounting.sync {
                self.progress.filesTotal = total
                self.progress.bytesTotal = totalBytes
            }
            self.emit(force: true)

            let group = DispatchGroup()
            for (_, files) in lanes {
                DispatchQueue.global(qos: .userInitiated).async(group: group) {
                    for file in files {
                        if self.cancelled { break }
                        self.ingestOne(file, to: destination)
                    }
                }
            }

            group.notify(queue: .main) {
                let summary = self.accounting.sync { (self.copied, self.progress.skipped, self.errors) }
                self.onComplete?(summary.0, summary.1, summary.2)
            }
        }
    }

    private func ingestOne(_ source: URL, to destination: URL) {
        let sourceStem = source.deletingPathExtension().lastPathComponent
        let name: String = stemMap[sourceStem].map { renamed in
            let ext = source.pathExtension
            return ext.isEmpty ? renamed : renamed + "." + ext
        } ?? source.lastPathComponent
        var targetDir = destination
        if preserveFolders {
            targetDir = destination.appendingPathComponent(source.deletingLastPathComponent().lastPathComponent)
            try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        }
        let size = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)

        // Incremental: same name + same size already at destination → skip.
        let naive = targetDir.appendingPathComponent(name)
        if skipExisting,
           let existing = try? FileManager.default.attributesOfItem(atPath: naive.path),
           (existing[.size] as? NSNumber)?.int64Value == size {
            accounting.sync {
                progress.filesDone += 1
                progress.skipped += 1
                progress.bytesDone += size
                progress.currentFile = name
            }
            emit()
            return
        }

        // Different-size collision (e.g. same filename on two cards) →
        // unique name instead of overwrite or skip.
        let dest = FileOps.uniqueDestination(for: name, in: targetDir)
        do {
            let sha = try streamCopy(from: source, to: dest)
            // Stash the checksum for deferred verification.
            if let identity = CacheDB.identity(for: dest) {
                CacheDB.shared.set(identity + "|sha256", Data(sha.utf8))
            }
            accounting.sync {
                copied += 1
                progress.filesDone += 1
                progress.bytesDone += size
                progress.currentFile = name
            }
        } catch {
            try? FileManager.default.removeItem(at: dest.appendingPathExtension("qcpart"))
            accounting.sync {
                errors.append("\(name): \(error.localizedDescription)")
                progress.filesDone += 1
                progress.bytesDone += size
            }
        }
        emit()
    }

    /// Sequential large-block copy with in-stream SHA-256. Returns hex digest.
    private func streamCopy(from source: URL, to dest: URL) throws -> String {
        let fm = FileManager.default
        let partial = dest.appendingPathExtension("qcpart")

        guard let input = InputStream(url: source) else {
            throw NSError(domain: "funo", code: 1, userInfo: [NSLocalizedDescriptionKey: "can't open source"])
        }
        fm.createFile(atPath: partial.path, contents: nil)
        guard let output = OutputStream(url: partial, append: false) else {
            throw NSError(domain: "funo", code: 2, userInfo: [NSLocalizedDescriptionKey: "can't open destination"])
        }
        input.open()
        output.open()
        defer {
            input.close()
            output.close()
        }

        var hasher = SHA256()
        let blockSize = 8 * 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: blockSize)

        while input.hasBytesAvailable {
            if cancelled {
                throw NSError(domain: "funo", code: 3, userInfo: [NSLocalizedDescriptionKey: "cancelled"])
            }
            let read = input.read(&buffer, maxLength: blockSize)
            if read < 0 {
                throw input.streamError ?? NSError(domain: "funo", code: 4, userInfo: [NSLocalizedDescriptionKey: "read failed"])
            }
            if read == 0 { break }
            buffer.withUnsafeBufferPointer { pointer in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: pointer.baseAddress, count: read))
            }
            var written = 0
            while written < read {
                let count = buffer.withUnsafeBufferPointer { pointer in
                    output.write(pointer.baseAddress! + written, maxLength: read - written)
                }
                if count <= 0 {
                    throw output.streamError ?? NSError(domain: "funo", code: 5, userInfo: [NSLocalizedDescriptionKey: "write failed"])
                }
                written += count
            }
        }

        try fm.moveItem(at: partial, to: dest)

        // Preserve the card's timestamps - capture-time sorting depends on it.
        if let attrs = try? fm.attributesOfItem(atPath: source.path) {
            var preserved: [FileAttributeKey: Any] = [:]
            if let mtime = attrs[.modificationDate] { preserved[.modificationDate] = mtime }
            if let ctime = attrs[.creationDate] { preserved[.creationDate] = ctime }
            if !preserved.isEmpty { try? fm.setAttributes(preserved, ofItemAtPath: dest.path) }
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func emit(force: Bool = false) {
        let now = Date()
        let snapshot: Progress? = accounting.sync {
            guard force || now.timeIntervalSince(lastEmit) > 0.1 else { return nil }
            lastEmit = now
            return progress
        }
        guard let snapshot else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onProgress?(snapshot)
        }
    }
}

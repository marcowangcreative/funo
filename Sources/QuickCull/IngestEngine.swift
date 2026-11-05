import Foundation
import CryptoKit
import QuickCullCore

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

    /// Sizes and dates for the preview. No image decode.
    static func inventory(under root: URL) -> [IngestSourceFile] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                                         options: [.skipsHiddenFiles]) else { return [] }
        var files: [IngestSourceFile] = []
        for case let url as URL in walker {
            guard mediaExtensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let modified = values?.contentModificationDate ?? Date()
            files.append(IngestSourceFile(
                originalName: url.lastPathComponent,
                stem: url.deletingPathExtension().lastPathComponent,
                ext: url.pathExtension,
                size: size,
                folderName: url.deletingLastPathComponent().lastPathComponent,
                modified: modified
            ))
        }
        files.sort { $0.originalName.localizedStandardCompare($1.originalName) == .orderedAscending }
        return files
    }

    /// Names already in a folder, for the collision preview. Not recursive.
    static func existingFiles(in folder: URL) -> [IngestExisting] {
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        return children.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            return IngestExisting(folder: folder.lastPathComponent, name: url.lastPathComponent, size: size)
        }
    }

    /// File-name tokens. Does not append a hidden counter — collisions are
    /// decided in `IngestPlanner` and shown in the preview before copy.
    static func applyPattern(_ pattern: String, seq: Int, ingest: Int,
                             date: Date = Date(), originalStem: String = "") -> String {
        IngestNaming.renderStem(
            pattern: pattern,
            renameEnabled: true,
            sequence: seq,
            ingest: ingest,
            date: date,
            originalStem: originalStem
        )
    }

    struct Copy {
        var source: URL
        var relativePath: String
        var skip: Bool
        var sourceSize: Int64
    }

    // MARK: - The job

    func cancel() {
        cancelled = true
    }

    /// Copies `copies` into `destination`. Names and collisions are already
    /// decided (the preview). The card is only read. A failed copy deletes
    /// the partial we wrote, never the source.
    func start(copies: [Copy], destination: URL, backupRoot: URL?, jobName: String, writeMetadata: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let totalBytes = copies.reduce(Int64(0)) { $0 + $1.sourceSize }
            self.accounting.sync {
                self.progress.filesTotal = copies.count
                self.progress.bytesTotal = totalBytes
            }
            self.emit(force: true)
            self.appendLog(IngestLog.line(when: Date(), result: "BEGIN", original: jobName,
                                          relative: destination.path, bytes: Int64(copies.count), checksum: ""))

            // One lane per source volume so two folders on one card don't
            // thrash it, while two cards still run together.
            var lanes: [String: [Copy]] = [:]
            for copy in copies {
                let volume = (try? copy.source.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path ?? copy.source.path
                lanes[volume, default: []].append(copy)
            }
            let group = DispatchGroup()
            for (_, lane) in lanes {
                DispatchQueue.global(qos: .userInitiated).async(group: group) {
                    for copy in lane {
                        if self.cancelled { break }
                        self.ingestOne(copy, destination: destination, backupRoot: backupRoot,
                                       jobName: jobName, writeMetadata: writeMetadata)
                    }
                }
            }
            group.notify(queue: .main) {
                let summary = self.accounting.sync { (self.copied, self.progress.skipped, self.errors) }
                self.appendLog(IngestLog.line(when: Date(), result: "END", original: jobName,
                                              relative: "", bytes: Int64(summary.0), checksum: ""))
                self.onComplete?(summary.0, summary.1, summary.2)
            }
        }
    }

    private func ingestOne(_ copy: Copy, destination: URL, backupRoot: URL?, jobName: String, writeMetadata: Bool) {
        let relative = copy.relativePath
        guard !relative.isEmpty, !relative.contains("..") else {
            fail(copy, "refusing an unsafe destination path")
            return
        }
        let dest = destination.appendingPathComponent(relative)
        let name = dest.lastPathComponent
        if copy.skip {
            accounting.sync {
                progress.filesDone += 1
                progress.skipped += 1
                progress.bytesDone += copy.sourceSize
                progress.currentFile = name
            }
            appendLog(IngestLog.line(when: Date(), result: "SKIP", original: copy.source.lastPathComponent,
                                     relative: relative, bytes: copy.sourceSize, checksum: ""))
            emit()
            return
        }
        // Never overwrite. If the preview went stale, number the file.
        let fm = FileManager.default
        var finalDest = dest
        if fm.fileExists(atPath: dest.path) {
            let existing = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value
            if skipExisting, existing == copy.sourceSize {
                accounting.sync {
                    progress.filesDone += 1
                    progress.skipped += 1
                    progress.bytesDone += copy.sourceSize
                    progress.currentFile = name
                }
                appendLog(IngestLog.line(when: Date(), result: "SKIP", original: copy.source.lastPathComponent,
                                         relative: relative, bytes: copy.sourceSize, checksum: ""))
                emit()
                return
            }
            finalDest = FileOps.uniqueDestination(for: name, in: dest.deletingLastPathComponent())
        }
        var ownedCopy = false
        do {
            try fm.createDirectory(at: finalDest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let sourceSHA = try streamCopy(from: copy.source, to: finalDest)
            ownedCopy = true
            accounting.sync { progress.currentFile = "Verifying \(finalDest.lastPathComponent)" }
            emit(force: true)
            let actualSize = (try? fm.attributesOfItem(atPath: finalDest.path)[.size] as? NSNumber)?.int64Value
            let destSHA = try? hashFile(finalDest)
            let check = IngestCheck.evaluate(expectedSize: copy.sourceSize, actualSize: actualSize,
                                             expectedChecksum: sourceSHA, actualChecksum: destSHA)
            switch check {
            case .verified:
                if let identity = CacheDB.identity(for: finalDest) {
                    CacheDB.shared.set(identity + "|sha256", Data(sourceSHA.utf8))
                }
                copySidecarIfPresent(from: copy.source, to: finalDest)
                if writeMetadata {
                    writeJobSidecar(at: finalDest, job: jobName, original: copy.source.lastPathComponent)
                }
                if let backupRoot {
                    copyBackup(finalDest, relative: relativePath(of: finalDest, under: destination), root: backupRoot)
                }
                accounting.sync {
                    copied += 1
                    progress.filesDone += 1
                    progress.bytesDone += copy.sourceSize
                    progress.currentFile = finalDest.lastPathComponent
                }
                appendLog(IngestLog.line(when: Date(), result: "OK", original: copy.source.lastPathComponent,
                                         relative: relativePath(of: finalDest, under: destination),
                                         bytes: copy.sourceSize, checksum: sourceSHA))
            default:
                try? fm.removeItem(at: finalDest)
                fail(copy, "verify failed")
            }
        } catch {
            // A half-written .qcpart is ours. The finished file is ours only
            // after the rename from that partial. The source is never removed.
            try? fm.removeItem(at: finalDest.appendingPathExtension("qcpart"))
            if ownedCopy, finalDest.standardizedFileURL.path != copy.source.standardizedFileURL.path {
                try? fm.removeItem(at: finalDest)
            }
            fail(copy, error.localizedDescription)
        }
        emit()
    }

    private func fail(_ copy: Copy, _ message: String) {
        accounting.sync {
            errors.append("\(copy.source.lastPathComponent): \(message)")
            progress.filesDone += 1
            progress.bytesDone += copy.sourceSize
            progress.currentFile = copy.source.lastPathComponent
        }
        appendLog(IngestLog.line(when: Date(), result: "FAIL", original: copy.source.lastPathComponent,
                                 relative: copy.relativePath, bytes: copy.sourceSize, checksum: message))
    }

    private func relativePath(of file: URL, under root: URL) -> String {
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if file.path.hasPrefix(base) { return String(file.path.dropFirst(base.count)) }
        return file.lastPathComponent
    }

    private func copySidecarIfPresent(from source: URL, to dest: URL) {
        let sidecar = source.deletingPathExtension().appendingPathExtension("xmp")
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return }
        let target = dest.deletingPathExtension().appendingPathExtension("xmp")
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        try? FileManager.default.copyItem(at: sidecar, to: target)
    }

    private func writeJobSidecar(at dest: URL, job: String, original: String) {
        let target = dest.deletingPathExtension().appendingPathExtension("xmp")
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        let text = IngestSidecar.xmp(job: job, originalName: original)
        try? text.write(to: target, atomically: true, encoding: .utf8)
    }

    private func copyBackup(_ file: URL, relative: String, root: URL) {
        let target = root.appendingPathComponent(relative)
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: file, to: target)
    }

    private func appendLog(_ line: String) {
        let folder = logFolder
        guard let folder else { return }
        let url = folder.appendingPathComponent("Ingest Log.txt")
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: Data())
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            if let data = (line + "\n").data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
    }

    /// Set by the controller before start so the log lands in the job folder.
    var logFolder: URL?

    private func hashFile(_ url: URL) throws -> String {
        guard let input = InputStream(url: url) else {
            throw NSError(domain: "funo", code: 6, userInfo: [NSLocalizedDescriptionKey: "can't reopen copy"])
        }
        input.open()
        defer { input.close() }
        var hasher = SHA256()
        let blockSize = 8 * 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: blockSize)
        while input.hasBytesAvailable {
            let read = input.read(&buffer, maxLength: blockSize)
            if read < 0 { throw input.streamError ?? NSError(domain: "funo", code: 7, userInfo: nil) }
            if read == 0 { break }
            buffer.withUnsafeBufferPointer { pointer in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: pointer.baseAddress, count: read))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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

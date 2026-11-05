import Foundation
import QuickCullCore

/// Capture times keyed by path, size, and mtime. The second open of a folder
/// does not re-read EXIF headers.
final class CaptureDateStore {
    static let shared = CaptureDateStore()

    private let queue = DispatchQueue(label: "funo.capture-dates")
    private var cache = CaptureDateCache()
    private var loaded = false

    func snapshot() -> CaptureDateCache {
        queue.sync {
            loadIfNeeded()
            return cache
        }
    }

    func merge(_ records: [CaptureDateRecord]) {
        guard !records.isEmpty else { return }
        queue.async {
            self.loadIfNeeded()
            for record in records { self.cache.store(record) }
            let data = CaptureDateCacheCodec.encode(Array(self.cache.records.values))
            try? data.write(to: self.fileURL(), options: .atomic)
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL()),
              let records = CaptureDateCacheCodec.decode(data) else { return }
        for record in records { cache.store(record) }
    }

    private func fileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("QuickCull", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("capture-dates.v1")
    }
}

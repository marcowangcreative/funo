import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Persistent cache: thumbnails (JPEG blobs) and face-analysis results
/// (JSON), keyed on file identity (path + size + mtime) so any edit to the
/// original invalidates automatically. Second open of a folder costs
/// nothing; relaunches stop re-scanning.
///
/// Invisible plumbing — never user-facing, never a catalog.
final class CacheDB {

    static let shared = CacheDB()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "quickcull.cachedb")

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("QuickCull", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("cache.sqlite").path
        queue.sync {
            guard sqlite3_open(path, &db) == SQLITE_OK else {
                db = nil
                return
            }
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
            sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS blobs (k TEXT PRIMARY KEY, v BLOB);", nil, nil, nil)
        }
    }

    /// Stable identity for cache keys: path + size + mtime. Any change to
    /// the file (or a rename/move) misses the cache and re-derives.
    static func identity(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return "\(url.path)|\(size)|\(Int(mtime.timeIntervalSince1970))"
    }

    func get(_ key: String) -> Data? {
        queue.sync {
            guard let db else { return nil }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT v FROM blobs WHERE k=?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
            let count = Int(sqlite3_column_bytes(stmt, 0))
            return Data(bytes: bytes, count: count)
        }
    }

    func delete(_ key: String) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "DELETE FROM blobs WHERE k=?;", -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    /// Testing aid: wipe every cached blob (thumbnails, face results, hashes).
    func clear() {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            sqlite3_exec(db, "DELETE FROM blobs;", nil, nil, nil)
            sqlite3_exec(db, "VACUUM;", nil, nil, nil)
        }
    }

    func set(_ key: String, _ data: Data) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO blobs (k, v) VALUES (?, ?);", -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            data.withUnsafeBytes { buffer in
                _ = sqlite3_bind_blob(stmt, 2, buffer.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
            }
            sqlite3_step(stmt)
        }
    }
}

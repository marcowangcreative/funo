import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Persistent cache: thumbnails + previews (JPEG blobs) and face-analysis
/// results (JSON), keyed on file identity (path + size + mtime) so any edit
/// to the original invalidates automatically. Second open of a folder costs
/// nothing; relaunches stop re-scanning.
///
/// SELF-MANAGING: an LRU with a disk-derived byte budget. Reads bump access
/// time; writes past budget prune the oldest blobs in the background. No
/// setting, no "empty cache" button a user must find - invisible plumbing.
final class CacheDB {

    static let shared = CacheDB()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "quickcull.cachedb")

    /// Byte budget, derived from free disk once at launch. Not user-facing.
    private var budget: Int64 = 3_000_000_000
    /// Running estimate of on-disk blob bytes; exact SUM recomputed at each
    /// prune so drift never accumulates.
    private var estimatedBytes: Int64 = 0
    private var pruning = false

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("QuickCull", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("cache.sqlite").path
        queue.sync {
            guard sqlite3_open(path, &db) == SQLITE_OK else { db = nil; return }
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
            sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS blobs (k TEXT PRIMARY KEY, v BLOB, bytes INTEGER, atime INTEGER);", nil, nil, nil)
            // Migrate an old (k, v) table in place. ALTER errors if the
            // column already exists (fresh table) - that's expected, ignore.
            sqlite3_exec(db, "ALTER TABLE blobs ADD COLUMN bytes INTEGER;", nil, nil, nil)
            sqlite3_exec(db, "ALTER TABLE blobs ADD COLUMN atime INTEGER;", nil, nil, nil)
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_atime ON blobs(atime);", nil, nil, nil)
        }
        // Backfill + budget + first prune off the critical path AND out of the
        // first-folder window: on a cold launch that pass can hold the cache
        // queue ~1 s, and the grid's thumbnail lookups (queue.sync) would stall
        // behind it - the cold-open beachball. A few seconds late is harmless;
        // pruning isn't urgent, and set() defaults keep the cache safe until it
        // runs (budget starts generous, so nothing over-prunes meanwhile).
        queue.asyncAfter(deadline: .now() + 4.0) { [weak self] in self?.bootstrap(dir: dir) }
    }

    private func now() -> Int64 { Int64(Date().timeIntervalSince1970) }

    /// One-time: fill bytes/atime for legacy rows, size the budget to the
    /// disk, seed the running counter, and prune if we're already over.
    private func bootstrap(dir: URL) {
        guard let db else { return }
        let t = now()
        sqlite3_exec(db, "UPDATE blobs SET bytes = length(v) WHERE bytes IS NULL;", nil, nil, nil)
        sqlite3_exec(db, "UPDATE blobs SET atime = \(t) WHERE atime IS NULL;", nil, nil, nil)

        // Budget: generous but bounded, and never a big fraction of a small
        // disk. Thumbnails are ~40 KB, previews ~1-2 MB - 3 GB is tens of
        // thousands of frames cached.
        var free: Int64 = 0
        if let vals = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let f = vals.volumeAvailableCapacityForImportantUsage { free = f }
        if free > 0 {
            budget = max(512_000_000, min(3_000_000_000, free / 10))
        }
        estimatedBytes = currentBytes()
        pruneLocked()
    }

    private func currentBytes() -> Int64 {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(SUM(bytes),0) FROM blobs;", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Evict oldest-accessed blobs until under 85% of budget - ONE bounded
    /// batch per queue turn. get() is queue.sync from every decode thread,
    /// so a prune that holds the queue for its whole pass stalls ALL
    /// thumbnail/preview rendering (blank cells while scrolling, appearing
    /// only after weeks of use, once the cache first fills its budget).
    /// Yielding between batches lets reads interleave; nothing cares that
    /// the prune finishes a few hundred ms later.
    private func pruneLocked() {
        guard !pruning, db != nil, estimatedBytes > budget else { return }
        pruning = true
        estimatedBytes = currentBytes() // exact starting point, kills drift
        pruneStep(target: Int64(Double(budget) * 0.85), guardCount: 0)
    }

    /// One batch: tally the bytes of the 512 oldest (walks the atime index,
    /// cheap - the old per-batch full-table SUM was most of the stall),
    /// delete them, re-queue the next batch. Runs on the cachedb queue.
    private func pruneStep(target: Int64, guardCount: Int) {
        guard let db, estimatedBytes > target, guardCount < 10_000 else {
            pruning = false
            return
        }
        var batchBytes: Int64 = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COALESCE(SUM(bytes),0) FROM (SELECT bytes FROM blobs ORDER BY atime ASC LIMIT 512);", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW {
            batchBytes = sqlite3_column_int64(stmt, 0)
        }
        sqlite3_finalize(stmt)
        let sql = """
        DELETE FROM blobs WHERE k IN (
            SELECT k FROM blobs ORDER BY atime ASC LIMIT 512
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, sqlite3_changes(db) > 0 else {
            pruning = false
            return
        }
        estimatedBytes = max(0, estimatedBytes - batchBytes)
        queue.async { [weak self] in
            self?.pruneStep(target: target, guardCount: guardCount + 1)
        }
    }

    // MARK: - API (unchanged signatures)

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
            guard sqlite3_prepare_v2(db, "SELECT v, atime FROM blobs WHERE k=?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
            let count = Int(sqlite3_column_bytes(stmt, 0))
            // LRU touch, THROTTLED: only rewrite atime if it's over an hour
            // stale, so hot reads don't turn into a write storm.
            let stored = sqlite3_column_int64(stmt, 1)
            let t = now()
            if t - stored > 3600 {
                var up: OpaquePointer?
                if sqlite3_prepare_v2(db, "UPDATE blobs SET atime=? WHERE k=?;", -1, &up, nil) == SQLITE_OK {
                    sqlite3_bind_int64(up, 1, t)
                    sqlite3_bind_text(up, 2, key, -1, SQLITE_TRANSIENT)
                    sqlite3_step(up)
                }
                sqlite3_finalize(up)
            }
            return Data(bytes: bytes, count: count)
        }
    }

    func set(_ key: String, _ data: Data) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO blobs (k, v, bytes, atime) VALUES (?, ?, ?, ?);", -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            data.withUnsafeBytes { buffer in
                _ = sqlite3_bind_blob(stmt, 2, buffer.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_int64(stmt, 3, Int64(data.count))
            sqlite3_bind_int64(stmt, 4, self.now())
            sqlite3_step(stmt)
            self.estimatedBytes += Int64(data.count)
            // Crossed budget → kick off a sliced prune (no-op if running).
            if self.estimatedBytes > self.budget { self.pruneLocked() }
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

    /// Diagnostic (⌥ menu): wipe every cached blob.
    func clear() {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            sqlite3_exec(db, "DELETE FROM blobs;", nil, nil, nil)
            sqlite3_exec(db, "VACUUM;", nil, nil, nil)
            self.estimatedBytes = 0
        }
    }
}

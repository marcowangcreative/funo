import Foundation

/// Hard-capped LRU.
///
/// NSCache's `totalCostLimit` is not a ceiling on macOS. It is a hint the
/// cache consults when the system finally delivers a memory-pressure
/// warning, and a Mac with tens of gigabytes of RAM delivers that warning
/// very late. A Release build decodes fast enough to insert every photo
/// the user scrolls through before any eviction runs; a Debug build is
/// slow enough that the lazy evictor appears to work. This cache evicts
/// on the inserting thread, before `insert` returns, so the byte budget
/// holds no matter how fast the decode queue runs.
final class BoundedCostCache<Value> {

    let costLimit: Int
    let countLimit: Int

    private struct Entry {
        let value: Value
        var cost: Int
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Oldest at index 0, newest at the end.
    private var order: [String] = []
    private var totalCost: Int = 0

    init(costLimit: Int, countLimit: Int) {
        self.costLimit = max(1, costLimit)
        self.countLimit = max(1, countLimit)
    }

    var currentCost: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalCost
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func contains(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[key] != nil
    }

    /// Oldest key first. For tests and the memory log.
    func keysOldestFirst() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return order
    }

    func value(for key: String) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        moveToNewest(key)
        return entry.value
    }

    /// Remember that these photos are on screen so a burst of inserts
    /// evicts frames the user has already left, not the ones they're on.
    func touch<S: Sequence>(_ keys: S) where S.Element == String {
        lock.lock()
        defer { lock.unlock() }
        for key in keys where entries[key] != nil {
            moveToNewest(key)
        }
    }

    func insert(_ value: Value, for key: String, cost: Int) {
        let cost = max(1, cost)
        lock.lock()
        defer { lock.unlock() }
        if let old = entries.removeValue(forKey: key) {
            totalCost -= old.cost
            removeFromOrder(key)
        }
        entries[key] = Entry(value: value, cost: cost)
        order.append(key)
        totalCost += cost
        evictLocked()
    }

    func remove(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let old = entries.removeValue(forKey: key) else { return }
        totalCost -= old.cost
        removeFromOrder(key)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
        totalCost = 0
    }

    // MARK: - Lock held

    private func moveToNewest(_ key: String) {
        removeFromOrder(key)
        order.append(key)
    }

    private func removeFromOrder(_ key: String) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
    }

    /// Drop oldest entries until both caps hold. A single image larger
    /// than the budget is kept — the photo on screen has to be able to
    /// exist — but it has already evicted everything else.
    private func evictLocked() {
        while entries.count > countLimit || (totalCost > costLimit && entries.count > 1) {
            guard let oldest = order.first else { return }
            order.removeFirst()
            if let entry = entries.removeValue(forKey: oldest) {
                totalCost -= entry.cost
            }
        }
    }
}

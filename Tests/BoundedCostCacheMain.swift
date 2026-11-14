import Foundation

/// Standalone check for the image-cache bound. Not part of the app target.
///
///     cd QuickCull   # repo root
///     swiftc -O -o /tmp/funo-cache-test \
///         Sources/QuickCull/BoundedCostCache.swift \
///         Tests/BoundedCostCacheMain.swift
///     /tmp/funo-cache-test
///
/// Simulates the Release leak: each "thumbnail" inserted at the cost of a
/// full-frame decode (~96 MB). Four hundred of those is about 38 GB, which
/// is the climb Activity Monitor was showing. The cache must stay inside
/// its budget anyway.

@main
struct BoundedCostCacheMain {
    static func main() {
        var failed = 0
        func check(_ name: String, _ ok: Bool) {
            if ok {
                print("PASS \(name)")
            } else {
                print("FAIL \(name)")
                failed += 1
            }
        }

        // MARK: LRU order and cost ceiling

        let small = BoundedCostCache<Int>(costLimit: 30, countLimit: 10)
        small.insert(1, for: "a", cost: 10)
        small.insert(2, for: "b", cost: 10)
        small.insert(3, for: "c", cost: 10)
        check("fills to the budget", small.currentCost == 30 && small.count == 3)

        small.insert(4, for: "d", cost: 10)
        check("evicts the oldest when over budget",
              small.currentCost == 30 && small.count == 3 && !small.contains("a") && small.contains("d"))

        _ = small.value(for: "b") // b becomes newest: c, d, b
        small.insert(5, for: "e", cost: 10)
        check("a recent read is not the one evicted",
              small.contains("b") && !small.contains("c") && small.contains("e") && small.currentCost == 30)

        small.insert(6, for: "b", cost: 5) // d + e were 20, b comes back at 5
        check("replacing a key updates its cost",
              small.contains("b") && small.currentCost == 25 && small.count == 3)

        // MARK: Count ceiling

        let counted = BoundedCostCache<Int>(costLimit: 10_000_000, countLimit: 3)
        for i in 0..<10 {
            counted.insert(i, for: "k\(i)", cost: 1)
        }
        check("count limit holds",
              counted.count == 3 && counted.contains("k9") && counted.contains("k8") && counted.contains("k7")
              && !counted.contains("k0"))

        // MARK: One oversized image is kept, and it evicts the rest

        let tight = BoundedCostCache<Int>(costLimit: 10, countLimit: 8)
        tight.insert(1, for: "small", cost: 4)
        tight.insert(2, for: "huge", cost: 50)
        check("oversized current image is kept alone",
              tight.count == 1 && tight.contains("huge") && !tight.contains("small") && tight.currentCost == 50)

        // MARK: The 32 GB failure mode

        let mb = 1024 * 1024
        let thumbs = BoundedCostCache<Int>(costLimit: 160 * mb, countLimit: 250)
        let fullFrame = 96 * mb // 6000×4000 RGBA, what a RAW "thumbnail" used to be
        for i in 0..<1_000 {
            thumbs.insert(i, for: "photo-\(i)", cost: fullFrame)
        }
        check("1000 full-frame inserts stay inside 160 MB",
              thumbs.currentCost <= 160 * mb && thumbs.count <= 2 && thumbs.contains("photo-999"))
        print(String(format: "  full-frame stress: %d image(s), %.1f MB (budget 160 MB)",
                     thumbs.count, Double(thumbs.currentCost) / Double(mb)))

        let realistic = BoundedCostCache<Int>(costLimit: 160 * mb, countLimit: 250)
        let thumbCost = 512 * 340 * 4 // a real downsampled grid thumb
        for i in 0..<5_000 {
            realistic.insert(i, for: "thumb-\(i)", cost: thumbCost)
        }
        check("5000 real-sized thumbs stay inside 160 MB",
              realistic.currentCost <= 160 * mb && realistic.count <= 250 && realistic.contains("thumb-4999"))
        let kept = realistic.count
        check("enough thumbs survive to scroll back a screen",
              kept >= 80)
        print(String(format: "  thumb stress: %d images, %.1f MB",
                     kept, Double(realistic.currentCost) / Double(mb)))

        // MARK: Concurrent inserts

        let shared = BoundedCostCache<Int>(costLimit: 32 * mb, countLimit: 64)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "cache-stress", attributes: .concurrent)
        for worker in 0..<8 {
            group.enter()
            queue.async {
                for i in 0..<500 {
                    shared.insert(i, for: "w\(worker)-\(i)", cost: mb)
                }
                group.leave()
            }
        }
        group.wait()
        check("concurrent inserts stay inside the budget",
              shared.currentCost <= 32 * mb && shared.count <= 64 && shared.count == shared.keysOldestFirst().count)
        print(String(format: "  concurrent stress: %d images, %.1f MB (budget 32 MB)",
                     shared.count, Double(shared.currentCost) / Double(mb)))

        if failed > 0 {
            print("\(failed) check(s) failed")
            exit(1)
        }
        print("All cache bounds checks passed")
    }
}

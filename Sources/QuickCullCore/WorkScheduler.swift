import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// What a piece of background work is for. Lower raw value runs first.
public enum WorkLane: Int, Comparable, Equatable, CaseIterable {
    /// The photo open in the loupe. Outranks the filmstrip.
    case selected = 0
    /// On-screen thumbnails, including every visible filmstrip frame.
    case visible = 1
    /// The next two or three screens. Ahead of capture dates and the rest.
    case lookahead = 2
    /// Capture-date header reads. Behind the photos on screen, beside the rest.
    case metadata = 3
    case prefetch = 4
    case background = 5

    public static func < (lhs: WorkLane, rhs: WorkLane) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .selected: return "selected"
        case .visible: return "visible"
        case .lookahead: return "lookahead"
        case .metadata: return "metadata"
        case .prefetch: return "prefetch"
        case .background: return "background"
        }
    }
}

/// How many reads a drive can take at once.
/// A memory card is the only slow device. An external SSD is not a card.
public enum VolumePace: Equatable {
    case card
    case external
    case internalDisk
}

/// Pace and concurrency for a volume. Pure so tests can pin a core count.
public enum DrivePacing {
    /// Disk-cache reads live on the internal SSD. They must not take a slot
    /// on the volume the photo file is on.
    public static let cacheVolume = "cache"

    public struct Limits: Equatable {
        public var card: Int
        public var external: Int
        public var internalDisk: Int
        public var global: Int
        /// Capture-date readers that may run at once, on any pace.
        public var metadata: Int

        public init(card: Int, external: Int, internalDisk: Int, global: Int, metadata: Int) {
            self.card = card
            self.external = external
            self.internalDisk = internalDisk
            self.global = global
            self.metadata = metadata
        }
    }

    /// Removable media is a card. An external volume that is not removable
    /// (a USB exFAT SSD) stays external. Anything else is internal.
    public static func pace(removable: Bool, isInternal: Bool) -> VolumePace {
        if removable { return .card }
        if isInternal { return .internalDisk }
        return .external
    }

    public static func limits(cores: Int) -> Limits {
        let n = max(1, cores)
        return Limits(
            card: 2,
            external: max(4, n - 2),
            internalDisk: max(4, n - 1),
            global: max(1, n - 1),
            metadata: 4
        )
    }

    public static func limit(_ pace: VolumePace, _ limits: Limits) -> Int {
        switch pace {
        case .card: return limits.card
        case .external: return limits.external
        case .internalDisk: return limits.internalDisk
        }
    }
}

public enum WorkState: Equatable {
    case queued
    case running
    case finished
    case cancelled
    case timedOut
}

public struct WorkJob: Equatable {
    public var id: Int
    public var group: String
    public var name: String
    public var lane: WorkLane
    public var volume: String
    public var pace: VolumePace
    public var generation: Int
    public var state: WorkState
    public var enqueuedAt: TimeInterval
    public var startedAt: TimeInterval?

    public init(id: Int, group: String, name: String, lane: WorkLane, volume: String,
                pace: VolumePace, generation: Int, state: WorkState,
                enqueuedAt: TimeInterval, startedAt: TimeInterval? = nil) {
        self.id = id
        self.group = group
        self.name = name
        self.lane = lane
        self.volume = volume
        self.pace = pace
        self.generation = generation
        self.state = state
        self.enqueuedAt = enqueuedAt
        self.startedAt = startedAt
    }
}

/// 0/1 flag the volume walk can read without taking the job lock.
private final class YieldFlag: @unchecked Sendable {
    private let raw: UnsafeMutablePointer<UInt32>
    init() {
        raw = .allocate(capacity: 1)
        raw.initialize(to: 0)
    }
    deinit {
        raw.deinitialize(count: 1)
        raw.deallocate()
    }
    var isSet: Bool {
        #if canImport(Darwin)
        return OSAtomicOr32Barrier(0, raw) != 0
        #else
        return raw.pointee != 0
        #endif
    }
    func store(_ on: Bool) {
        #if canImport(Darwin)
        if on {
            _ = OSAtomicOr32Barrier(1, raw)
        } else {
            _ = OSAtomicAnd32Barrier(0, raw)
        }
        #else
        raw.pointee = on ? 1 : 0
        #endif
    }
}

/// One queue for disk work. Each lane is a FIFO. Promotion pops the front,
/// so it does not sort the pending list. Lane changes are an unlink and an
/// append. The yield flag is a separate atomic the index walk can read
/// without this lock.
public final class WorkScheduler {
    public var cardLimit: Int
    public var externalLimit: Int
    public var internalLimit: Int
    public var globalLimit: Int
    public var metadataLimit: Int
    public var timeout: TimeInterval

    private final class Slot {
        var job: WorkJob
        var prev: Slot?
        var next: Slot?
        init(job: WorkJob) { self.job = job }
    }

    private let lock = NSLock()
    private let inboxLock = NSLock()
    private var laneNotes: [Int: WorkLane] = [:]
    private var slots: [Int: Slot] = [:]
    private var head: [WorkLane: Slot] = [:]
    private var tail: [WorkLane: Slot] = [:]
    private var queuedOnVolume: [WorkLane: [String: Int]] = [:]
    private var volumePace: [String: VolumePace] = [:]
    private var groupIDs: [String: Set<Int>] = [:]
    private var runningOnVolume: [String: Int] = [:]
    private var runningCount = 0
    private var metadataRunning = 0
    private var visibleQueued = 0
    private var visibleRunning = 0
    private var foregroundQueued = 0
    private var foregroundRunning = 0
    private var nextID = 1
    private var folderLoading = false
    private var cancelledIDs: Set<Int> = []
    private let yield = YieldFlag()

    public init(cardLimit: Int = 2, externalLimit: Int = 6, internalLimit: Int = 6,
                globalLimit: Int = 8, metadataLimit: Int = 4, timeout: TimeInterval = 20) {
        self.cardLimit = cardLimit
        self.externalLimit = externalLimit
        self.internalLimit = internalLimit
        self.globalLimit = globalLimit
        self.metadataLimit = metadataLimit
        self.timeout = timeout
    }

    public func setFolderLoading(_ loading: Bool) {
        lock.lock()
        folderLoading = loading
        publishYieldLocked()
        lock.unlock()
    }

    public var isFolderLoading: Bool {
        lock.lock()
        defer { lock.unlock() }
        return folderLoading
    }

    /// Lock-free. The volume walk may call this often.
    public var backgroundShouldYield: Bool { yield.isSet }

    @discardableResult
    public func enqueue(group: String, name: String, lane: WorkLane, volume: String,
                        pace: VolumePace, generation: Int, now: TimeInterval) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        let job = WorkJob(
            id: id, group: group, name: name, lane: lane, volume: volume, pace: pace,
            generation: generation, state: .queued, enqueuedAt: now
        )
        let slot = Slot(job: job)
        slots[id] = slot
        append(slot, to: lane)
        queuedOnVolume[lane, default: [:]][volume, default: 0] += 1
        volumePace[volume] = pace
        groupIDs[group, default: []].insert(id)
        if lane != .background { foregroundQueued += 1 }
        publishYieldLocked()
        return id
    }

    /// Moves a queued job to another lane. O(1). Safe on the scheduler queue.
    /// The main thread must not call this; use `noteLane` instead.
    public func setLane(_ id: Int, _ lane: WorkLane) {
        lock.lock()
        setLaneLocked(id, lane)
        publishYieldLocked()
        lock.unlock()
    }

    /// Apply a batch of lane changes under one lock. Used by the scheduler
    /// queue after it has coalesced notes from the main thread.
    public func applyLanes(_ changes: [Int: WorkLane]) {
        guard !changes.isEmpty else { return }
        lock.lock()
        for (id, lane) in changes { setLaneLocked(id, lane) }
        publishYieldLocked()
        lock.unlock()
    }

    /// Records a lane change without taking the job lock. The scheduler
    /// queue applies the batch later. The latest note for an id wins.
    public func noteLane(_ id: Int, _ lane: WorkLane) {
        inboxLock.lock()
        laneNotes[id] = lane
        inboxLock.unlock()
    }

    /// Apply every noted lane change. One lock for the whole batch.
    public func applyLaneNotes() {
        inboxLock.lock()
        let batch = laneNotes
        laneNotes.removeAll(keepingCapacity: true)
        inboxLock.unlock()
        guard !batch.isEmpty else { return }
        lock.lock()
        for (id, lane) in batch { setLaneLocked(id, lane) }
        publishYieldLocked()
        lock.unlock()
    }

    public func cancel(group: String, generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        for id in groupIDs[group] ?? [] {
            guard let slot = slots[id], slot.job.generation == generation else { continue }
            cancelLocked(slot)
        }
        publishYieldLocked()
    }

    public func cancel(group: String) {
        lock.lock()
        defer { lock.unlock() }
        for id in groupIDs[group] ?? [] {
            guard let slot = slots[id] else { continue }
            cancelLocked(slot)
        }
        publishYieldLocked()
    }

    public func cancel(id: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let slot = slots[id] else {
            cancelledIDs.insert(id)
            return
        }
        cancelLocked(slot)
        publishYieldLocked()
    }

    public func cancel(volume: String) {
        lock.lock()
        defer { lock.unlock() }
        let ids = slots.values.filter { $0.job.volume == volume }.map(\.job.id)
        for id in ids {
            guard let slot = slots[id] else { continue }
            cancelLocked(slot)
        }
        publishYieldLocked()
    }

    public func isCancelled(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledIDs.contains(id)
    }

    /// Pop the next job that may start. The common case is the front of the
    /// highest lane, which is O(1). A full volume is skipped without walking
    /// every waiting thumbnail.
    public func promoteNext(now: TimeInterval) -> WorkJob? {
        lock.lock()
        defer { lock.unlock() }
        if runningCount >= globalLimit { return nil }
        // On-screen photos and the next screens take the drive first.
        if let job = takeLocked([.selected, .visible, .lookahead], now: now) {
            return job
        }
        // A few capture-date readers, then the rest of the folder shares
        // whatever slots are left. Dates never fill the drive by themselves.
        if metadataRunning < metadataLimit, let job = takeLocked([.metadata], now: now) {
            return job
        }
        return takeLocked([.prefetch, .background], now: now)
    }

    private func takeLocked(_ lanes: [WorkLane], now: TimeInterval) -> WorkJob? {
        for lane in lanes {
            if lane == .background, folderLoading || visibleQueued > 0 || visibleRunning > 0 { continue }
            guard laneHasRoom(lane) else { continue }
            var slot = head[lane]
            var spins = 0
            let volumeCount = queuedOnVolume[lane]?.count ?? 0
            while let current = slot {
                let limit = limit(for: current.job.pace)
                if (runningOnVolume[current.job.volume] ?? 0) < limit {
                    detach(current)
                    current.job.state = .running
                    current.job.startedAt = now
                    runningCount += 1
                    runningOnVolume[current.job.volume, default: 0] += 1
                    if lane == .metadata { metadataRunning += 1 }
                    if lane == .visible { visibleRunning += 1 }
                    if lane != .background {
                        foregroundQueued -= 1
                        foregroundRunning += 1
                    }
                    publishYieldLocked()
                    return current.job
                }
                slot = current.next
                spins += 1
                if spins > max(volumeCount, 1) { break }
            }
        }
        return nil
    }

    private func limit(for pace: VolumePace) -> Int {
        switch pace {
        case .card: return cardLimit
        case .external: return externalLimit
        case .internalDisk: return internalLimit
        }
    }

    public func finish(_ id: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let slot = slots.removeValue(forKey: id) else { return }
        groupIDs[slot.job.group]?.remove(id)
        if slot.job.startedAt != nil {
            runningCount = max(0, runningCount - 1)
            let volume = slot.job.volume
            runningOnVolume[volume] = max(0, (runningOnVolume[volume] ?? 1) - 1)
            if slot.job.lane == .metadata {
                metadataRunning = max(0, metadataRunning - 1)
            }
            if slot.job.lane == .visible {
                visibleRunning = max(0, visibleRunning - 1)
            }
            if slot.job.lane != .background {
                foregroundRunning = max(0, foregroundRunning - 1)
            }
        }
        publishYieldLocked()
    }

    public func markTimedOut(_ id: Int, now: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard let slot = slots[id], slot.job.state == .running else { return }
        slot.job.state = .timedOut
        cancelledIDs.insert(id)
        _ = now
    }

    public func overdue(now: TimeInterval) -> [WorkJob] {
        lock.lock()
        defer { lock.unlock() }
        var late: [WorkJob] = []
        for slot in slots.values where slot.job.state == .running {
            guard let started = slot.job.startedAt, now - started > timeout else { continue }
            late.append(slot.job)
        }
        return late
    }

    public func live() -> [WorkJob] {
        lock.lock()
        defer { lock.unlock() }
        var running: [WorkJob] = []
        for slot in slots.values where slot.job.state == .running || slot.job.state == .timedOut {
            running.append(slot.job)
        }
        running.sort { $0.lane < $1.lane }
        return running
    }

    private func append(_ slot: Slot, to lane: WorkLane) {
        slot.job.lane = lane
        slot.prev = tail[lane]
        slot.next = nil
        if let last = tail[lane] {
            last.next = slot
        } else {
            head[lane] = slot
        }
        tail[lane] = slot
        if slot.job.state == .queued, lane == .visible {
            visibleQueued += 1
        }
    }

    private func detach(_ slot: Slot) {
        let lane = slot.job.lane
        if let prev = slot.prev { prev.next = slot.next } else { head[lane] = slot.next }
        if let next = slot.next { next.prev = slot.prev } else { tail[lane] = slot.prev }
        slot.prev = nil
        slot.next = nil
        if slot.job.state == .queued, lane == .visible {
            visibleQueued = max(0, visibleQueued - 1)
        }
        if slot.job.state == .queued {
            let volume = slot.job.volume
            if var counts = queuedOnVolume[lane] {
                counts[volume] = max(0, (counts[volume] ?? 1) - 1)
                if counts[volume] == 0 { counts.removeValue(forKey: volume) }
                queuedOnVolume[lane] = counts
            }
        }
    }

    private func setLaneLocked(_ id: Int, _ lane: WorkLane) {
        guard let slot = slots[id], slot.job.state == .queued, slot.job.lane != lane else { return }
        let old = slot.job.lane
        detach(slot)
        append(slot, to: lane)
        queuedOnVolume[lane, default: [:]][slot.job.volume, default: 0] += 1
        if old != .background { foregroundQueued -= 1 }
        if lane != .background { foregroundQueued += 1 }
    }

    private func cancelLocked(_ slot: Slot) {
        cancelledIDs.insert(slot.job.id)
        if slot.job.state == .queued {
            if slot.job.lane != .background { foregroundQueued = max(0, foregroundQueued - 1) }
            detach(slot)
            slots[slot.job.id] = nil
            groupIDs[slot.job.group]?.remove(slot.job.id)
        } else if slot.job.state == .running || slot.job.state == .timedOut {
            slot.job.state = .cancelled
        }
    }

    private func laneHasRoom(_ lane: WorkLane) -> Bool {
        guard let counts = queuedOnVolume[lane] else { return false }
        for (volume, waiting) in counts where waiting > 0 {
            let pace = volumePace[volume] ?? .internalDisk
            let limit = limit(for: pace)
            if (runningOnVolume[volume] ?? 0) < limit { return true }
        }
        return false
    }

    private func publishYieldLocked() {
        yield.store(folderLoading || foregroundQueued > 0 || foregroundRunning > 0)
    }
}

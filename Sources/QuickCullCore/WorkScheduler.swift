import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// What a piece of background work is for. Lower raw value runs first.
public enum WorkLane: Int, Comparable, Equatable, CaseIterable {
    case visible = 0
    case selected = 1
    case prefetch = 2
    case background = 3

    public static func < (lhs: WorkLane, rhs: WorkLane) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .visible: return "visible"
        case .selected: return "selected"
        case .prefetch: return "prefetch"
        case .background: return "background"
        }
    }
}

/// How many reads a drive can take at once. USB, exFAT, and spinning
/// disks thrash if they are asked for more than a couple of files at a time.
public enum VolumePace: Equatable {
    case fast
    case slow

    public var defaultLimit: Int { self == .fast ? 6 : 2 }
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
    public var slowLimit: Int
    public var fastLimit: Int
    public var globalLimit: Int
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
    private var foregroundQueued = 0
    private var foregroundRunning = 0
    private var nextID = 1
    private var folderLoading = false
    private var cancelledIDs: Set<Int> = []
    private let yield = YieldFlag()

    public init(slowLimit: Int = 2, fastLimit: Int = 6, globalLimit: Int = 8, timeout: TimeInterval = 20) {
        self.slowLimit = slowLimit
        self.fastLimit = fastLimit
        self.globalLimit = globalLimit
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
        for lane in WorkLane.allCases.sorted() {
            if folderLoading && lane == .background { continue }
            guard laneHasRoom(lane) else { continue }
            var slot = head[lane]
            var spins = 0
            let volumeCount = queuedOnVolume[lane]?.count ?? 0
            while let current = slot {
                let limit = current.job.pace == .slow ? slowLimit : fastLimit
                if (runningOnVolume[current.job.volume] ?? 0) < limit {
                    detach(current)
                    current.job.state = .running
                    current.job.startedAt = now
                    runningCount += 1
                    runningOnVolume[current.job.volume, default: 0] += 1
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

    public func finish(_ id: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let slot = slots.removeValue(forKey: id) else { return }
        groupIDs[slot.job.group]?.remove(id)
        if slot.job.startedAt != nil {
            runningCount = max(0, runningCount - 1)
            let volume = slot.job.volume
            runningOnVolume[volume] = max(0, (runningOnVolume[volume] ?? 1) - 1)
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
    }

    private func detach(_ slot: Slot) {
        let lane = slot.job.lane
        if let prev = slot.prev { prev.next = slot.next } else { head[lane] = slot.next }
        if let next = slot.next { next.prev = slot.prev } else { tail[lane] = slot.prev }
        slot.prev = nil
        slot.next = nil
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
            let pace = volumePace[volume] ?? .fast
            let limit = pace == .slow ? slowLimit : fastLimit
            if (runningOnVolume[volume] ?? 0) < limit { return true }
        }
        return false
    }

    private func publishYieldLocked() {
        yield.store(folderLoading || foregroundQueued > 0 || foregroundRunning > 0)
    }
}

import Foundation

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

/// One queue for disk work. Visible cells and the selected photo run before
/// prefetch, which runs before the volume index and face scan. Leaving a
/// folder cancels that generation instead of letting it finish in the dark.
public final class WorkScheduler {
    public var slowLimit: Int
    public var fastLimit: Int
    public var globalLimit: Int
    public var timeout: TimeInterval
    private let lock = NSLock()
    private var jobs: [WorkJob] = []
    private var nextID = 1
    private var folderLoading = false
    private var cancelledIDs: Set<Int> = []

    public init(slowLimit: Int = 2, fastLimit: Int = 6, globalLimit: Int = 8, timeout: TimeInterval = 20) {
        self.slowLimit = slowLimit
        self.fastLimit = fastLimit
        self.globalLimit = globalLimit
        self.timeout = timeout
    }

    public func setFolderLoading(_ loading: Bool) {
        lock.lock()
        folderLoading = loading
        lock.unlock()
    }

    public var isFolderLoading: Bool {
        lock.lock()
        defer { lock.unlock() }
        return folderLoading
    }

    /// The volume walk should stop reading while a folder is opening or any
    /// foreground job is waiting or running.
    public var backgroundShouldYield: Bool {
        lock.lock()
        defer { lock.unlock() }
        if folderLoading { return true }
        return jobs.contains {
            $0.lane != .background && ($0.state == .queued || $0.state == .running)
        }
    }

    @discardableResult
    public func enqueue(group: String, name: String, lane: WorkLane, volume: String,
                        pace: VolumePace, generation: Int, now: TimeInterval) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        jobs.append(WorkJob(
            id: id, group: group, name: name, lane: lane, volume: volume, pace: pace,
            generation: generation, state: .queued, enqueuedAt: now
        ))
        return id
    }

    public func setLane(_ id: Int, _ lane: WorkLane) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .queued else { return }
        jobs[index].lane = lane
    }

    /// Queued work for this generation will not start. Running work is marked
    /// cancelled so the worker can stop at its next check.
    public func cancel(group: String, generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        for index in jobs.indices.reversed() where jobs[index].group == group && jobs[index].generation == generation {
            cancelLocked(index)
        }
    }

    public func cancel(group: String) {
        lock.lock()
        defer { lock.unlock() }
        for index in jobs.indices.reversed() where jobs[index].group == group {
            cancelLocked(index)
        }
    }

    public func cancel(id: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            cancelledIDs.insert(id)
            return
        }
        cancelLocked(index)
    }

    public func cancel(volume: String) {
        lock.lock()
        defer { lock.unlock() }
        for index in jobs.indices.reversed() where jobs[index].volume == volume {
            cancelLocked(index)
        }
    }

    public func isCancelled(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledIDs.contains(id)
    }

    /// Start the most important job that still fits on its volume.
    public func promoteNext(now: TimeInterval) -> WorkJob? {
        lock.lock()
        defer { lock.unlock() }
        let running = jobs.filter(occupiesSlot)
        if running.count >= globalLimit { return nil }
        let queued = jobs.enumerated().filter { $0.element.state == .queued }
            .sorted { a, b in
                if a.element.lane != b.element.lane { return a.element.lane < b.element.lane }
                if a.element.enqueuedAt != b.element.enqueuedAt { return a.element.enqueuedAt < b.element.enqueuedAt }
                return a.element.id < b.element.id
            }
        for candidate in queued {
            let job = candidate.element
            if folderLoading && job.lane == .background { continue }
            let limit = job.pace == .slow ? slowLimit : fastLimit
            let onVolume = running.filter { $0.volume == job.volume }.count
            if onVolume >= limit { continue }
            jobs[candidate.offset].state = .running
            jobs[candidate.offset].startedAt = now
            return jobs[candidate.offset]
        }
        return nil
    }

    public func finish(_ id: Int) {
        lock.lock()
        defer { lock.unlock() }
        jobs.removeAll { $0.id == id }
    }

    public func markTimedOut(_ id: Int, now: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .running else { return }
        jobs[index].state = .timedOut
        cancelledIDs.insert(id)
        _ = now
    }

    public func overdue(now: TimeInterval) -> [WorkJob] {
        lock.lock()
        defer { lock.unlock() }
        return jobs.filter { job in
            guard job.state == .running, let started = job.startedAt else { return false }
            return now - started > timeout
        }
    }

    public func live() -> [WorkJob] {
        lock.lock()
        defer { lock.unlock() }
        return jobs.filter(isLive)
            .sorted { a, b in
                if a.lane != b.lane { return a.lane < b.lane }
                return a.enqueuedAt < b.enqueuedAt
            }
    }

    private func occupiesSlot(_ job: WorkJob) -> Bool {
        if job.state == .running || job.state == .timedOut { return true }
        return job.state == .cancelled && job.startedAt != nil
    }

    private func isLive(_ job: WorkJob) -> Bool {
        switch job.state {
        case .queued, .running, .timedOut: return true
        case .cancelled: return job.startedAt != nil
        case .finished: return false
        }
    }

    private func cancelLocked(_ index: Int) {
        cancelledIDs.insert(jobs[index].id)
        if jobs[index].state == .queued {
            jobs.remove(at: index)
        } else if jobs[index].state == .running || jobs[index].state == .timedOut {
            jobs[index].state = .cancelled
        }
    }
}

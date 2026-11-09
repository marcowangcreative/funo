import AppKit
import QuickCullCore

/// Runs `WorkScheduler` jobs on one bounded pool. Callers do not open their
/// own decode queues.
final class WorkRunner {
    static let shared = WorkRunner()

    let scheduler: WorkScheduler
    private let pump = DispatchQueue(label: "funo.work.pump")
    private let pool: OperationQueue
    private var bodies: [Int: ((@escaping () -> Bool) -> Void)] = [:]
    private var paceMemo: [String: (volume: String, pace: VolumePace)] = [:]
    private let paceLock = NSLock()
    private var watchdogSource: DispatchSourceTimer?
    private var pendingLanes: [Int: WorkLane] = [:]
    private var laneFlushScheduled = false

    private init() {
        let limits = DrivePacing.limits(cores: ProcessInfo.processInfo.activeProcessorCount)
        scheduler = WorkScheduler(
            cardLimit: limits.card, externalLimit: limits.external, internalLimit: limits.internalDisk,
            globalLimit: limits.global, metadataLimit: limits.metadata)
        pool = OperationQueue()
        pool.name = "funo.work"
        pool.maxConcurrentOperationCount = limits.global
        pool.qualityOfService = .userInitiated
    }

    func startWatchdog() {
        guard watchdogSource == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: pump)
        source.schedule(deadline: .now() + 2, repeating: 2)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSinceReferenceDate
            let late = self.scheduler.overdue(now: now)
            for job in late {
                let started = job.startedAt ?? now
                FunoLog.write(String(format: "funo work: %@ [%@ %@] on %@ has been running %.0f s", job.name, job.lane.label, job.group, job.volume, now - started))
                if job.lane == .background {
                    self.scheduler.markTimedOut(job.id, now: now)
                }
            }
        }
        source.resume()
        watchdogSource = source
    }

    func setFolderLoading(_ loading: Bool) {
        pump.async {
            self.scheduler.setFolderLoading(loading)
            self.kick()
        }
    }

    /// Three paces. A real card (`volumeIsRemovable`) gets 2 reads. An
    /// external SSD that is not removable media — including exFAT — gets
    /// max(4, cores-2). The internal disk gets max(4, cores-1). Treating
    /// every external SSD as a card starved the cores and read as load lag.
    func classify(_ url: URL) -> (volume: String, pace: VolumePace) {
        let dir = url.deletingLastPathComponent().path
        paceLock.lock()
        if let memo = paceMemo[dir] {
            paceLock.unlock()
            return memo
        }
        paceLock.unlock()
        let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path ?? "/"
        let values = try? URL(fileURLWithPath: volume).resourceValues(
            forKeys: [.volumeIsRemovableKey, .volumeIsInternalKey])
        let removable = values?.volumeIsRemovable ?? false
        let isInternal = values?.volumeIsInternal ?? true
        let result = (volume, DrivePacing.pace(removable: removable, isInternal: isInternal))
        paceLock.lock()
        paceMemo[dir] = result
        paceLock.unlock()
        return result
    }

    func submit(group: String, name: String, lane: WorkLane, volume: String, pace: VolumePace,
                generation: Int, onQueued: ((Int) -> Void)? = nil,
                body: @escaping (_ isCancelled: () -> Bool) -> Void) {
        pump.async {
            let id = self.scheduler.enqueue(
                group: group, name: name, lane: lane, volume: volume, pace: pace,
                generation: generation, now: Date().timeIntervalSinceReferenceDate)
            self.bodies[id] = body
            onQueued?(id)
            self.kick()
        }
    }

    /// Fire-and-forget. The caller, including the main thread, never takes
    /// the scheduler lock. Repeated notes for the same id keep the latest.
    func setLane(_ id: Int, _ lane: WorkLane) {
        guard id != 0 else { return }
        pump.async {
            self.pendingLanes[id] = lane
            self.scheduleLaneFlush()
        }
    }

    /// One scroll posts one set. A newer scroll replaces a set that has not
    /// been applied yet.
    func replaceLanes(_ updates: [Int: WorkLane]) {
        pump.async {
            self.pendingLanes = updates
            self.scheduleLaneFlush()
        }
    }

    private func scheduleLaneFlush() {
        guard !laneFlushScheduled else { return }
        laneFlushScheduled = true
        pump.async {
            self.laneFlushScheduled = false
            let batch = self.pendingLanes
            self.pendingLanes.removeAll(keepingCapacity: true)
            if !batch.isEmpty { self.scheduler.applyLanes(batch) }
            self.kick()
        }
    }

    func cancel(group: String, generation: Int) {
        pump.async { self.scheduler.cancel(group: group, generation: generation) }
    }

    func cancel(group: String) {
        pump.async {
            self.scheduler.cancel(group: group)
            self.kick()
        }
    }

    func cancel(id: Int) {
        guard id != 0 else { return }
        pump.async { self.scheduler.cancel(id: id) }
    }

    func cancel(volume: String) {
        pump.async {
            self.scheduler.cancel(volume: volume)
            self.kick()
        }
    }

    private func kick() {
        let now = Date().timeIntervalSinceReferenceDate
        while let job = scheduler.promoteNext(now: now) {
            guard let body = bodies.removeValue(forKey: job.id) else {
                scheduler.finish(job.id)
                continue
            }
            let id = job.id
            pool.addOperation { [weak self] in
                body { self?.scheduler.isCancelled(id) ?? true }
                self?.scheduler.finish(id)
                self?.pump.async { self?.kick() }
            }
        }
    }
}

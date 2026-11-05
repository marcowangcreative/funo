import AppKit
import QuickCullCore

/// Runs `WorkScheduler` jobs on one bounded pool. Callers do not open their
/// own decode queues.
final class WorkRunner {
    static let shared = WorkRunner()

    let scheduler = WorkScheduler()
    private let pump = DispatchQueue(label: "funo.work.pump")
    private let pool: OperationQueue
    private var bodies: [Int: ((@escaping () -> Bool) -> Void)] = [:]
    private var paceMemo: [String: (volume: String, pace: VolumePace)] = [:]
    private let paceLock = NSLock()
    private var watchdog: Timer?

    private init() {
        pool = OperationQueue()
        pool.name = "funo.work"
        pool.maxConcurrentOperationCount = 8
        pool.qualityOfService = .userInitiated
    }

    func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date().timeIntervalSinceReferenceDate
            for job in self.scheduler.overdue(now: now) {
                let started = job.startedAt ?? now
                NSLog("funo work: \(job.name) [\(job.lane.label) \(job.group)] on \(job.volume) has been running %.0f s", now - started)
                if job.lane == .background {
                    self.scheduler.markTimedOut(job.id, now: now)
                }
            }
        }
    }

    func setFolderLoading(_ loading: Bool) {
        scheduler.setFolderLoading(loading)
        pump.async { self.kick() }
    }

    /// Internal disks get six reads. Anything that can be unplugged, including
    /// USB, exFAT, and spinning drives, gets two so the heads and the bus
    /// are not thrashed.
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
        let slow = (values?.volumeIsRemovable ?? false) || (values?.volumeIsInternal == false)
        let result = (volume, slow ? VolumePace.slow : VolumePace.fast)
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

    func setLane(_ id: Int, _ lane: WorkLane) {
        guard id != 0 else { return }
        scheduler.setLane(id, lane)
        pump.async { self.kick() }
    }

    func cancel(group: String, generation: Int) {
        scheduler.cancel(group: group, generation: generation)
    }

    func cancel(group: String) {
        scheduler.cancel(group: group)
        pump.async { self.kick() }
    }

    func cancel(id: Int) {
        guard id != 0 else { return }
        scheduler.cancel(id: id)
    }

    func cancel(volume: String) {
        scheduler.cancel(volume: volume)
        pump.async { self.kick() }
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

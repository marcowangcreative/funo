import Foundation

#if DEBUG
/// Debug-only tripwire for the app's #1 bug class: blocking disk I/O on the
/// main thread. The stall only HURTS on a sleeping external drive, but it
/// EXISTS on every machine — this makes it visible on a dev Mac where the
/// call returns fast. Any main-thread block > threshold logs loudly.
///
/// Not compiled into release builds (build_app.sh builds -c release).
/// To hunt a report: reproduce with Instruments' Time Profiler, or sample
/// the process — the watchdog tells you WHEN, the profiler tells you WHERE.
final class MainThreadWatchdog {
    static let shared = MainThreadWatchdog()

    /// 120 ms: two skipped frames at 60 Hz beyond the 100 ms "feels instant"
    /// budget — real jank, comfortably above timer jitter false-positives.
    private let threshold: TimeInterval = 0.12
    private let interval: TimeInterval = 0.25
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let thread = Thread { [threshold, interval] in
            while true {
                let sem = DispatchSemaphore(value: 0)
                let sentAt = DispatchTime.now()
                DispatchQueue.main.async { sem.signal() }
                if sem.wait(timeout: .now() + threshold) == .timedOut {
                    // Main is blocked right now. Wait for it to come back
                    // and report how long the whole stall lasted.
                    sem.wait()
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - sentAt.uptimeNanoseconds) / 1_000_000
                    NSLog("🚨 funo watchdog: main thread blocked %.0f ms — if you just touched a folder/drive, some disk I/O is on the main thread. Sample with Instruments.", ms)
                }
                Thread.sleep(forTimeInterval: interval)
            }
        }
        thread.name = "funo.watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }
}
#endif

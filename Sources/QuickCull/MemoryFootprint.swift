import Foundation
import os
#if canImport(Darwin)
import Darwin
#endif

/// Resident-memory readout for checking the image cache.
///
/// Activity Monitor's Memory column is `phys_footprint`, not the older
/// resident-size number. Launch with `FUNO_MEMORY_LOG=1` and this prints
/// that figure, plus what the image cache believes it is holding, about
/// twice a second while you scroll or arrow through photos:
///
///     FUNO_MEMORY_LOG=1 swift run -c release
enum MemoryFootprint {

    private static let logger = Logger(subsystem: "funo.quickcull", category: "memory")
    private static let lock = NSLock()
    private static var lastLog = Date.distantPast

    static var loggingEnabled: Bool {
        let value = ProcessInfo.processInfo.environment["FUNO_MEMORY_LOG"]?.lowercased()
        return value == "1" || value == "yes" || value == "true"
    }

    /// Bytes Activity Monitor shows in the Memory column. 0 if the kernel
    /// refuses the query.
    static func physFootprint() -> UInt64 {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
        #else
        return 0
        #endif
    }

    /// Throttled. Safe to call from a scroll-bounds notification.
    static func log(context: String, cacheSummary: String) {
        guard loggingEnabled else { return }
        lock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastLog) >= 0.5 else {
            lock.unlock()
            return
        }
        lastLog = now
        lock.unlock()

        let mb = Double(physFootprint()) / 1_048_576
        let line = String(format: "QuickCullMemory %@  activity-monitor %.0f MB  %@",
                          context, mb, cacheSummary)
        print(line)
        logger.notice("\(line, privacy: .public)")
    }
}

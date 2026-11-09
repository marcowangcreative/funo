import Foundation

/// f/uno's own log. `swift run` sends NSLog to the terminal, which is not
/// the unified log, so the same lines are appended here.
enum FunoLog {
    private static let queue = DispatchQueue(label: "funo.log")
    private static let maxBytes = 5 * 1024 * 1024

    static func write(_ message: String) {
        NSLog("%@", message)
        queue.async { append(message) }
    }

    private static func append(_ message: String) {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/funo", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("funo.log")
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber, size.intValue >= maxBytes {
            let rotated = dir.appendingPathComponent("funo.log.1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: url, to: rotated)
        }
        let line = message.hasSuffix("\n") ? message : message + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

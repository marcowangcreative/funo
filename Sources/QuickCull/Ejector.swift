import AppKit

extension Notification.Name {
    /// Posted on main just before an eject attempt. userInfo["paths"] is
    /// [String] - the volume mount paths. Anyone holding descriptors under
    /// those paths (folder watchers, queued decodes) must let go NOW; the
    /// unmount starts half a second later.
    static let funoPrepareEject = Notification.Name("FunoPrepareEject")
}

/// The one place that knows how to put a card out politely: release every
/// hold f/uno owns, retry the (blocking) unmount off-main, and - when
/// someone ELSE is pinning the volume - name the culprit instead of
/// shrugging. Used by the ingest sheet's ⏏ button and the sidebar's
/// right-click Eject.
enum Ejector {

    struct Result {
        let ejected: [URL]
        let remaining: [URL]
        let lastError: String
        /// Other real apps with files open on the failed volume(s),
        /// friendliest first (e.g. ["Lightroom"]).
        let holders: [String]
        /// System daemons (Spotlight etc.) holding files, only meaningful
        /// when they are ALL that is left.
        let noise: [String]
        /// Files WE still have open - a bug worth logging, not hiding.
        let selfPaths: [String]
        var succeeded: Bool { remaining.isEmpty }

        /// One short line for a status label.
        var failureMessage: String {
            if let culprit = holders.first {
                return "\(culprit) is using the card - close it there, then eject."
            }
            if !selfPaths.isEmpty {
                return "f/uno is still reading the card - try again in a moment."
            }
            if !noise.isEmpty {
                return "Spotlight is indexing the card - try again in a moment."
            }
            return "Couldn't eject - try again in a moment."
        }

        /// Everything we know, for a tooltip / alert detail / Console.
        var failureDetail: String {
            var lines: [String] = []
            if !holders.isEmpty { lines.append("In use by: " + holders.joined(separator: ", ")) }
            if !noise.isEmpty { lines.append("System processes: " + noise.joined(separator: ", ")) }
            if !selfPaths.isEmpty {
                lines.append("f/uno still holds:")
                lines.append(contentsOf: selfPaths.prefix(12))
            }
            if lines.isEmpty { lines.append("lsof saw no open files - the volume may be busy at the kernel level.") }
            if !lastError.isEmpty { lines.append(lastError) }
            return lines.joined(separator: "\n")
        }
    }

    /// Call on main; completion arrives on main.
    static func eject(volumes: [URL], completion: @escaping (Result) -> Void) {
        guard !volumes.isEmpty else {
            completion(Result(ejected: [], remaining: [], lastError: "", holders: [], noise: [], selfPaths: []))
            return
        }

        // 1. Everything WE own lets go first: grid folder watchers (their
        //    O_EVTONLY descriptors pin the volume for as long as a tab has
        //    ever looked at it) …
        NotificationCenter.default.post(name: .funoPrepareEject, object: nil,
                                        userInfo: ["paths": volumes.map(\.path)])
        // … and queued thumbnail decodes.
        for volume in volumes {
            ThumbnailLoader.shared.cancelPending(underVolumePath: volume.path)
        }

        // 2. Retry off-main - unmount BLOCKS, and the first try often races
        //    the last in-flight read closing its descriptor.
        DispatchQueue.global(qos: .userInitiated).async {
            var remaining = volumes
            var lastError = ""
            for attempt in 0..<3 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.7) }
                remaining = remaining.filter { volume in
                    // diskutil, NOT NSWorkspace.unmountAndEjectDevice - the
                    // NSWorkspace path threw phantom fBsyErr (-47) on
                    // volumes Finder ejected happily (Carbon-era cruft).
                    // diskutil takes the same DiskArbitration road Finder
                    // does, and when something IS holding the card its
                    // error text names the dissenting process.
                    if let failure = diskutilEject(volume) {
                        lastError = failure
                        return true
                    }
                    return false
                }
                if remaining.isEmpty { break }
            }

            // 3. Still stuck → ask lsof who has the card open. Only on
            //    failure (it costs ~a second) and only off-main. NOTHING is
            //    hidden: other apps, system daemons, and our own leaks all
            //    get classified - a diagnostic that filters out the true
            //    cause is worse than none.
            var holders: [String] = []
            var noise: [String] = []
            var selfPaths: [String] = []
            if !remaining.isEmpty {
                let me = ProcessInfo.processInfo.processName
                var seen = Set<String>()
                for volume in remaining {
                    for proc in openProcesses(on: volume) {
                        if proc.name == me || proc.name.hasPrefix(me) || me.hasPrefix(proc.name) {
                            selfPaths.append(contentsOf: proc.paths)
                        } else if systemNoise.contains(proc.name) {
                            if seen.insert(proc.name).inserted { noise.append(proc.name) }
                        } else if seen.insert(proc.name).inserted {
                            holders.append(friendlyName(proc.name))
                        }
                    }
                }
                NSLog("[Ejector] eject failed (%@). holders=%@ noise=%@ selfPaths=%@",
                      lastError, holders.description, noise.description, selfPaths.description)
            }

            let ejected = volumes.filter { v in !remaining.contains(v) }
            DispatchQueue.main.async {
                completion(Result(ejected: ejected, remaining: remaining,
                                  lastError: lastError, holders: holders,
                                  noise: noise, selfPaths: selfPaths))
            }
        }
    }

    // MARK: - Who's holding the card?

    /// System daemons that show up in lsof but release on their own the
    /// moment the unmount actually proceeds - naming them would send the
    /// user chasing ghosts.
    private static let systemNoise: Set<String> = [
        "mds", "mds_stores", "mdworker", "mdworker_shared",
        "fseventsd", "deleted", "revisiond", "Finder",
    ]

    /// Eject via diskutil (synchronous, ~1s). Returns nil on success or
    /// a human-readable failure string - diskutil's own text when it has
    /// one, which usually names the process pinning the volume.
    private static func diskutilEject(_ volume: URL) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["eject", volume.path]
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do { try task.run() } catch {
            return "diskutil failed to launch: \(error.localizedDescription)"
        }
        let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: watchdog)
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()
        if task.terminationStatus == 0 { return nil }
        let text = [errData, outData]
            .compactMap { String(data: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return text.isEmpty ? "diskutil exit \(task.terminationStatus)" : text
    }

    struct OpenProcess {
        var name: String
        var paths: [String]
    }

    /// `lsof -Fpcn <mountpoint>` lists every process with an open file on
    /// that filesystem, with the paths it holds. Field output: p<pid>,
    /// c<command>, n<path> - one per line.
    private static func openProcesses(on volume: URL) -> [OpenProcess] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-Fpcn", volume.path]
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do { try task.run() } catch {
            NSLog("[Ejector] lsof failed to launch: %@", error.localizedDescription)
            return []
        }

        // lsof scans EVERY process on the system - give it a real chance
        // (10s) before abandoning the diagnosis (not the eject; that
        // already failed).
        let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()
        if let stderrText = String(data: errData, encoding: .utf8), !stderrText.isEmpty {
            NSLog("[Ejector] lsof stderr: %@", stderrText)
        }
        NSLog("[Ejector] lsof exit %d, %d bytes of output", task.terminationStatus, data.count)

        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var procs: [OpenProcess] = []
        var current: OpenProcess?
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                if let current { procs.append(current) }
                current = OpenProcess(name: "?", paths: [])
            case "c":
                current?.name = value
            case "n":
                current?.paths.append(value)
            default:
                break
            }
        }
        if let current { procs.append(current) }
        return procs
    }

    /// lsof reports process names like "Adobe Lightroo" (truncated) or
    /// "com.apple.Quick" - clean up the ones photographers actually hit.
    private static func friendlyName(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("lightroo") { return "Lightroom" }
        if lower.contains("photoshop") { return "Photoshop" }
        if lower.contains("photo mecha") || lower.contains("photomecha") { return "Photo Mechanic" }
        if lower.contains("quicklook") || lower.contains("com.apple.quick") { return "Quick Look" }
        if lower.contains("photos") && raw.count <= 7 { return "Photos" }
        return raw
    }
}

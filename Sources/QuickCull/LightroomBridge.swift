import AppKit

/// Hand-off to Lightroom without the navigation ritual. Opening photo URLs
/// (or a whole folder) with Lightroom Classic launches it straight into the
/// Import dialog with those files pre-selected — the user just confirms.
/// True zero-click import needs a companion Lightroom plugin (SDK/Lua) —
/// that's the roadmap step; this saves every click except the last one.
enum LightroomBridge {

    static func appURL() -> URL? {
        let candidatePaths = [
            "/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app",
            "/Applications/Adobe Lightroom Classic.app",
            "/Applications/Adobe Lightroom CC/Adobe Lightroom CC.app",
            "/Applications/Adobe Lightroom.app"
        ]
        for path in candidatePaths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let bundleIDs = ["com.adobe.LightroomClassicCC7", "com.adobe.lightroomCC"]
        for id in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return url
            }
        }
        return nil
    }

    static var isAvailable: Bool { appURL() != nil }

    /// Send files (or a folder URL) to Lightroom's import.
    static func send(_ urls: [URL], completion: @escaping (Bool) -> Void) {
        ExternalEditor.open(urls, with: appURL(), completion: completion)
    }
}

/// Hand-off to Photoshop. Opening RAW files with Photoshop drops them
/// straight into Adobe Camera Raw — the classic "edit the keepers" jump.
/// The app is discovered automatically: Adobe installs year-versioned
/// folders (/Applications/Adobe Photoshop 2026/Adobe Photoshop 2026.app),
/// so we scan for the newest year and fall back to asking Launch Services
/// for the bundle ID, which catches non-standard install locations.
enum PhotoshopBridge {

    static func appURL() -> URL? {
        let fm = FileManager.default
        let apps = "/Applications"
        if let entries = try? fm.contentsOfDirectory(atPath: apps) {
            let candidates = entries
                .filter { $0.hasPrefix("Adobe Photoshop") && !$0.contains("Elements") }
                .sorted(by: >)   // "…2026" sorts above "…2025"
            for folder in candidates {
                let nested = "\(apps)/\(folder)/\(folder).app"
                if fm.fileExists(atPath: nested) { return URL(fileURLWithPath: nested) }
                if folder.hasSuffix(".app") {
                    let direct = "\(apps)/\(folder)"
                    if fm.fileExists(atPath: direct) { return URL(fileURLWithPath: direct) }
                }
            }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.adobe.Photoshop")
    }

    static var isAvailable: Bool { appURL() != nil }

    static func send(_ urls: [URL], completion: @escaping (Bool) -> Void) {
        ExternalEditor.open(urls, with: appURL(), completion: completion)
    }
}

/// Shared open-with plumbing for editor hand-offs.
enum ExternalEditor {
    static func open(_ urls: [URL], with app: URL?, completion: @escaping (Bool) -> Void) {
        guard let app, !urls.isEmpty else {
            completion(false)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration) { _, error in
            DispatchQueue.main.async { completion(error == nil) }
        }
    }
}

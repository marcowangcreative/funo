import Foundation

/// Folder-structure templates: a named list of relative paths ("Ceremony",
/// "Reception/Speeches") stamped into any folder from the sidebar.
/// The tree stays the source of truth — a template is just a recipe.
enum FolderTemplates {

    private static let key = "QuickCullFolderTemplates"

    static var all: [String: [String]] {
        get { (UserDefaults.standard.dictionary(forKey: key) as? [String: [String]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var names: [String] { all.keys.sorted() }

    /// Seed starter templates on first run (users can delete them).
    static func ensureDefaults() {
        guard UserDefaults.standard.object(forKey: key) == nil else { return }
        all = [
            "Wedding": ["01 Getting Ready", "02 Ceremony", "03 Formals",
                        "04 Bride + Groom", "05 Reception", "06 Details", "Selects"],
            "Basic Shoot": ["Selects", "Alts", "Rejects"]
        ]
    }

    /// Create the template's folders inside `folder`. Existing folders are
    /// left untouched. Returns how many were newly created.
    @discardableResult
    static func apply(_ name: String, to folder: URL) -> Int {
        guard let paths = all[name] else { return 0 }
        let fm = FileManager.default
        var created = 0
        for path in paths {
            // Sanitize: template paths must stay INSIDE the target folder.
            let components = path.split(separator: "/").map(String.init)
            guard !components.isEmpty,
                  !components.contains(".."),
                  !components.contains(where: { $0.hasPrefix("~") }) else { continue }
            let target = folder.appendingPathComponent(components.joined(separator: "/"), isDirectory: true)
            guard !fm.fileExists(atPath: target.path) else { continue }
            do {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                created += 1
            } catch {
                NSLog("funo: template folder failed \(path): \(error.localizedDescription)")
            }
        }
        return created
    }

    /// Capture a folder's existing subfolder structure (two levels deep)
    /// as a reusable template.
    static func capture(from folder: URL) -> [String] {
        relativeSubfolders(of: folder, depth: 2)
    }

    static func save(name: String, paths: [String]) {
        var templates = all
        templates[name] = paths
        all = templates
    }

    static func delete(_ name: String) {
        var templates = all
        templates[name] = nil
        all = templates
    }

    private static func relativeSubfolders(of url: URL, depth: Int) -> [String] {
        guard depth > 0 else { return [] }
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var out: [String] = []
        for child in children {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let name = child.lastPathComponent
            out.append(name)
            for sub in relativeSubfolders(of: child, depth: depth - 1) {
                out.append(name + "/" + sub)
            }
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

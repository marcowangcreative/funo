import Foundation

/// File-name tokens. Renaming is off unless the caller says so. A pattern
/// never grows a hidden counter: collisions are numbered in the plan, where
/// the preview can show them.
public enum IngestNaming {
    public static func renderStem(
        pattern: String,
        renameEnabled: Bool,
        sequence: Int,
        ingest: Int,
        date: Date,
        originalStem: String,
        job: String = "",
        calendar: Calendar = .current
    ) -> String {
        guard renameEnabled else { return originalStem }
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return originalStem }
        let parts = dateParts(date, calendar: calendar)
        var stem = trimmed
            .replacingOccurrences(of: "{name}", with: originalStem)
            .replacingOccurrences(of: "{seq}", with: String(format: "%04d", sequence))
            .replacingOccurrences(of: "{iseq}", with: String(format: "%02d", ingest))
            .replacingOccurrences(of: "{date}", with: String(format: "%04d%02d%02d", parts.y, parts.m, parts.d))
            .replacingOccurrences(of: "{yyyy}", with: String(format: "%04d", parts.y))
            .replacingOccurrences(of: "{mm}", with: String(format: "%02d", parts.m))
            .replacingOccurrences(of: "{dd}", with: String(format: "%02d", parts.d))
            .replacingOccurrences(of: "{job}", with: sanitize(job))
        stem = stem.replacingOccurrences(of: "/", with: "-")
        stem = stem.replacingOccurrences(of: ":", with: "-")
        return stem.isEmpty ? originalStem : stem
    }

    static func dateParts(_ date: Date, calendar: Calendar) -> (y: Int, m: Int, d: Int) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    static func sanitize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A saved folder recipe. `pathPattern` is the destination relative path.
/// `subfolders` are extra directories created inside it (the old template
/// lists). Both survive together.
public struct IngestTemplate: Equatable {
    public var name: String
    public var pathPattern: String
    public var subfolders: [String]

    public init(name: String, pathPattern: String, subfolders: [String]) {
        self.name = name
        self.pathPattern = pathPattern
        self.subfolders = subfolders
    }
}

public enum IngestTemplates {
    /// Legacy lists stay. A name that already has a saved pattern keeps it.
    /// A name that only has folders becomes `{Job}` plus those folders.
    /// Nothing is dropped.
    public static func migrate(folderLists: [String: [String]], pathPatterns: [String: String]) -> [IngestTemplate] {
        let names = Set(folderLists.keys).union(pathPatterns.keys)
        return names.sorted().map { name in
            let pattern = pathPatterns[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let folders = (folderLists[name] ?? []).filter { isSafeRelative($0) }
            return IngestTemplate(
                name: name,
                pathPattern: (pattern?.isEmpty == false) ? pattern! : "{Job}",
                subfolders: folders
            )
        }
    }

    public static func render(
        pattern: String,
        job: String,
        camera: String = "",
        card: String = "",
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let parts = IngestNaming.dateParts(date, calendar: calendar)
        let stamp = String(format: "%04d%02d%02d", parts.y, parts.m, parts.d)
        var raw = pattern
            .replacingOccurrences(of: "{Job}", with: IngestNaming.sanitize(job))
            .replacingOccurrences(of: "{job}", with: IngestNaming.sanitize(job))
            .replacingOccurrences(of: "{Camera}", with: IngestNaming.sanitize(camera))
            .replacingOccurrences(of: "{camera}", with: IngestNaming.sanitize(camera))
            .replacingOccurrences(of: "{Card}", with: IngestNaming.sanitize(card))
            .replacingOccurrences(of: "{card}", with: IngestNaming.sanitize(card))
            .replacingOccurrences(of: "{YYYYMMDD}", with: stamp)
            .replacingOccurrences(of: "{YYYY}", with: String(format: "%04d", parts.y))
            .replacingOccurrences(of: "{MM}", with: String(format: "%02d", parts.m))
            .replacingOccurrences(of: "{DD}", with: String(format: "%02d", parts.d))
        let components = raw.split(separator: "/").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix("~") }
        raw = components.joined(separator: "/")
        return raw.isEmpty ? IngestNaming.sanitize(job) : raw
    }

    public static func isSafeRelative(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        return !components.isEmpty
            && !components.contains("..")
            && !components.contains(where: { $0.hasPrefix("~") || $0 == "." })
    }
}

public struct IngestSourceFile: Equatable {
    public var originalName: String
    public var stem: String
    public var ext: String
    public var size: Int64
    /// Card subfolder name when structure is preserved. Empty flattens.
    public var folderName: String
    public var modified: Date
    /// Stable identity so a preview row stays tied to one source file.
    public var id: Int

    public init(originalName: String, stem: String, ext: String, size: Int64, folderName: String, modified: Date, id: Int = 0) {
        self.originalName = originalName
        self.stem = stem
        self.ext = ext
        self.size = size
        self.folderName = folderName
        self.modified = modified
        self.id = id
    }
}

public struct IngestExisting: Equatable {
    public var folder: String
    public var name: String
    public var size: Int64
    public init(folder: String = "", name: String, size: Int64) {
        self.folder = folder
        self.name = name
        self.size = size
    }
}

public enum IngestRowNote: Equatable {
    case copy
    case renamed
    case skipDuplicate
    case numbered
}

public struct IngestPreviewRow: Equatable {
    public var originalName: String
    public var newName: String
    public var relativePath: String
    public var note: IngestRowNote
    public var size: Int64

    public init(originalName: String, newName: String, relativePath: String, note: IngestRowNote, size: Int64) {
        self.originalName = originalName
        self.newName = newName
        self.relativePath = relativePath
        self.note = note
        self.size = size
    }
}

public struct IngestPlanSummary: Equatable {
    public var copying: Int
    public var renamed: Int
    public var numbered: Int
    public var skipping: Int
    public var bytes: Int64
}

public enum IngestPlanner {
    /// Names for a run. Same stem (a RAW+JPEG pair) shares one rendered stem.
    /// Nothing is overwritten: same name + same size can skip; every other
    /// collision is numbered `stem 2.ext`.
    public static func rows(
        files: [IngestSourceFile],
        renameEnabled: Bool,
        pattern: String,
        ingestNumber: Int,
        preserveFolders: Bool,
        skipDuplicates: Bool,
        existing: [IngestExisting],
        job: String = ""
    ) -> [IngestPreviewRow] {
        let ordered = files.sorted {
            if $0.id != $1.id { return $0.id < $1.id }
            return $0.originalName.localizedStandardCompare($1.originalName) == .orderedAscending
        }
        var seqByStem: [String: Int] = [:]
        var nextSeq = 0
        for file in ordered where seqByStem[file.stem] == nil {
            nextSeq += 1
            seqByStem[file.stem] = nextSeq
        }

        var used: Set<String> = []
        var existingSize: [String: Int64] = [:]
        for item in existing {
            let folder = preserveFolders ? safeFolder(item.folder) : ""
            existingSize[key(folder, item.name)] = item.size
        }

        return ordered.map { file in
            let seq = seqByStem[file.stem] ?? 1
            let rendered = IngestNaming.renderStem(
                pattern: pattern,
                renameEnabled: renameEnabled,
                sequence: seq,
                ingest: ingestNumber,
                date: file.modified,
                originalStem: file.stem,
                job: job
            )
            let folder = preserveFolders ? safeFolder(file.folderName) : ""
            let desired = joinName(stem: rendered, ext: file.ext)
            let renamed = desired.caseInsensitiveCompare(file.originalName) != .orderedSame
            let allocated = allocate(
                desired: desired,
                folder: folder,
                size: file.size,
                skipDuplicates: skipDuplicates,
                existingSize: existingSize,
                used: &used
            )
            let note: IngestRowNote
            if allocated.skip {
                note = .skipDuplicate
            } else if allocated.name.caseInsensitiveCompare(desired) != .orderedSame {
                note = .numbered
            } else if renamed {
                note = .renamed
            } else {
                note = .copy
            }
            let relative = folder.isEmpty ? allocated.name : folder + "/" + allocated.name
            return IngestPreviewRow(
                originalName: file.originalName,
                newName: allocated.name,
                relativePath: relative,
                note: note,
                size: file.size
            )
        }
    }

    public static func summary(_ rows: [IngestPreviewRow]) -> IngestPlanSummary {
        var copying = 0, renamed = 0, numbered = 0, skipping = 0
        var bytes: Int64 = 0
        for row in rows {
            switch row.note {
            case .skipDuplicate:
                skipping += 1
            case .numbered:
                numbered += 1
                copying += 1
                bytes += row.size
            case .renamed:
                renamed += 1
                copying += 1
                bytes += row.size
            case .copy:
                copying += 1
                bytes += row.size
            }
        }
        return IngestPlanSummary(copying: copying, renamed: renamed, numbered: numbered, skipping: skipping, bytes: bytes)
    }

    private static func safeFolder(_ name: String) -> String {
        let cleaned = IngestNaming.sanitize(name)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "" }
        return cleaned
    }

    private static func joinName(stem: String, ext: String) -> String {
        ext.isEmpty ? stem : stem + "." + ext
    }

    private static func key(_ folder: String, _ name: String) -> String {
        folder.lowercased() + "/" + name.lowercased()
    }

    private static func allocate(
        desired: String,
        folder: String,
        size: Int64,
        skipDuplicates: Bool,
        existingSize: [String: Int64],
        used: inout Set<String>
    ) -> (name: String, skip: Bool) {
        let exists = existingSize[key(folder, desired)]
        if used.contains(key(folder, desired)) || exists != nil {
            if !used.contains(key(folder, desired)), let exists, exists == size, skipDuplicates {
                used.insert(key(folder, desired))
                return (desired, true)
            }
            let ext = (desired as NSString).pathExtension
            let stem = (desired as NSString).deletingPathExtension
            var n = 2
            while true {
                let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
                let taken = used.contains(key(folder, candidate)) || existingSize[key(folder, candidate)] != nil
                if !taken {
                    used.insert(key(folder, candidate))
                    return (candidate, false)
                }
                n += 1
            }
        }
        used.insert(key(folder, desired))
        return (desired, false)
    }
}

public enum IngestCheck: Equatable {
    case verified
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch
    case unreadable

    /// Size first (cheap), then checksum. A missing file is unreadable.
    public static func evaluate(
        expectedSize: Int64,
        actualSize: Int64?,
        expectedChecksum: String,
        actualChecksum: String?
    ) -> IngestCheck {
        guard let actualSize else { return .unreadable }
        if actualSize != expectedSize { return .sizeMismatch(expected: expectedSize, actual: actualSize) }
        guard let actualChecksum else { return .unreadable }
        if actualChecksum.caseInsensitiveCompare(expectedChecksum) != .orderedSame {
            return .checksumMismatch
        }
        return .verified
    }
}

public enum IngestLog {
    public static func line(when: Date, result: String, original: String, relative: String, bytes: Int64, checksum: String) -> String {
        let stamp = ISO8601DateFormatter().string(from: when)
        return "\(stamp)\t\(result)\t\(original)\t\(relative)\t\(bytes)\t\(checksum)"
    }
}

public enum IngestSidecar {
    /// A small sidecar. Written only when metadata is on and no sidecar
    /// already exists at the destination. The source file is never touched.
    public static func xmp(job: String, originalName: String) -> String {
        let safeJob = job
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let safeName = originalName
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>
        <x:xmpmeta xmlns:x=\"adobe:ns:meta/\">
         <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">
          <rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">
           <dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">\(safeJob)</rdf:li></rdf:Alt></dc:title>
           <dc:source>\(safeName)</dc:source>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end=\"w\"?>
        """
    }
}

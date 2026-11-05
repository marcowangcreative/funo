import Foundation

/// Folded index of one folder's photos for ⌘F.
///
/// Names are folded once, when the folder list is built. A keystroke only
/// walks those strings. Matching ignores case, diacritics, and width, and
/// compares Unicode in composed form, so a typed "Cafe" hits "Café" whether
/// the disk name is NFC or NFD. The index is the whole folder, not whatever
/// the grid is currently filtering down to.
public struct FolderSearchIndex: Equatable {
    public struct Entry: Equatable {
        public var id: String
        public var name: String
        public var foldedName: String
        public var foldedStem: String

        public init(id: String, name: String, foldedName: String, foldedStem: String) {
            self.id = id
            self.name = name
            self.foldedName = foldedName
            self.foldedStem = foldedStem
        }
    }

    public private(set) var entries: [Entry]

    public init(photos: [(id: String, name: String)]) {
        entries = photos.map { photo in
            let folded = Self.fold(photo.name)
            return Entry(id: photo.id, name: photo.name,
                         foldedName: folded, foldedStem: Self.stem(folded))
        }
    }

    /// Case, diacritics, and fullwidth forms. POSIX so Turkish "I" stays "i".
    public static func fold(_ string: String) -> String {
        string.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
    }

    public static func stem(_ folded: String) -> String {
        (folded as NSString).deletingPathExtension
    }

    /// Best matches first. Rank 0 is an exact name or stem (so `IMG_1.JPG`
    /// hits the `IMG_1.CR3` pair). The cap never drops a rank-0 hit that
    /// sorted in ahead of looser prefix matches.
    public func hits(query: String, limit: Int = 12) -> [(id: String, name: String)] {
        let q = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else { return [] }
        let qStem = Self.stem(q)
        let digits = q.allSatisfy(\.isNumber)
        var ranked: [(rank: Int, index: Int, id: String, name: String)] = []
        ranked.reserveCapacity(min(entries.count, max(limit, 1)))
        for (index, entry) in entries.enumerated() {
            let rank: Int
            if digits {
                if entry.foldedStem.hasSuffix(q) {
                    rank = 0
                } else if entry.foldedStem.contains(q) || entry.foldedName.contains(q) {
                    rank = 1
                } else {
                    continue
                }
            } else if entry.foldedName == q || (!qStem.isEmpty && entry.foldedStem == qStem) {
                rank = 0
            } else if entry.foldedName.hasPrefix(q)
                        || (!qStem.isEmpty && (entry.foldedStem.hasPrefix(q) || entry.foldedStem.hasPrefix(qStem))) {
                rank = 1
            } else if entry.foldedName.contains(q)
                        || (!qStem.isEmpty && entry.foldedStem.contains(qStem)) {
                rank = 2
            } else {
                continue
            }
            ranked.append((rank, index, entry.id, entry.name))
        }
        ranked.sort { ($0.rank, $0.index) < ($1.rank, $1.index) }
        var out: [(id: String, name: String)] = []
        out.reserveCapacity(min(limit, ranked.count))
        for hit in ranked {
            if out.count >= limit { break }
            out.append((hit.id, hit.name))
        }
        return out
    }
}

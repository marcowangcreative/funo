import Foundation

/// One photo's place in a capture-time sort.
///
/// `hasDate` is false when the file has no DateTimeOriginal. Those rows stay
/// at the end in both directions. Subseconds break ties inside one second,
/// then the filename, so a burst shot in the same second keeps frame order.
public struct CaptureSortKey: Equatable {
    public var filename: String
    public var hasDate: Bool
    public var seconds: TimeInterval
    public var subsecMillis: Int

    public init(filename: String, hasDate: Bool, seconds: TimeInterval = 0, subsecMillis: Int = 0) {
        self.filename = filename
        self.hasDate = hasDate
        self.seconds = seconds
        self.subsecMillis = subsecMillis
    }
}

public enum CaptureSort {
    /// EXIF `yyyy:MM:dd HH:mm:ss` plus `SubSecTimeOriginal`. The fraction is
    /// scaled to milliseconds: `"956"` is 956 ms, `"5"` is 500 ms.
    public static func parse(dateTime: String, subsec: String?) -> (seconds: TimeInterval, millis: Int)? {
        guard let date = parser.date(from: dateTime) else { return nil }
        return (date.timeIntervalSince1970, subsecMillis(subsec))
    }

    public static func subsecMillis(_ raw: String?) -> Int {
        guard let raw else { return 0 }
        let digits = raw.prefix { $0.isNumber }
        guard !digits.isEmpty else { return 0 }
        if digits.count >= 3 {
            return min(Int(digits.prefix(3)) ?? 0, 999)
        }
        var value = Int(digits) ?? 0
        for _ in digits.count..<3 { value *= 10 }
        return min(value, 999)
    }

    /// Strict weak order. Direction is a flag on the comparison. Missing
    /// dates compare after every real date, ascending or descending.
    public static func isOrderedBefore(_ a: CaptureSortKey, _ b: CaptureSortKey, ascending: Bool) -> Bool {
        if a.hasDate != b.hasDate { return a.hasDate }
        if a.hasDate {
            if a.seconds != b.seconds || a.subsecMillis != b.subsecMillis {
                let aTime = a.seconds + Double(a.subsecMillis) / 1000
                let bTime = b.seconds + Double(b.subsecMillis) / 1000
                if aTime != bTime { return ascending ? aTime < bTime : aTime > bTime }
            }
        }
        let order = a.filename.localizedStandardCompare(b.filename)
        if order == .orderedSame { return false }
        return ascending ? order == .orderedAscending : order == .orderedDescending
    }

    private static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()
}

/// Disk cache identity is path + size + mtime. A rewrite of the file misses.
public struct CaptureDateRecord: Equatable {
    public var identity: String
    public var hasDate: Bool
    public var seconds: TimeInterval
    public var subsecMillis: Int

    public init(identity: String, hasDate: Bool, seconds: TimeInterval = 0, subsecMillis: Int = 0) {
        self.identity = identity
        self.hasDate = hasDate
        self.seconds = seconds
        self.subsecMillis = subsecMillis
    }
}

public struct CaptureDateCache: Equatable {
    public private(set) var records: [String: CaptureDateRecord]

    public init(records: [String: CaptureDateRecord] = [:]) {
        self.records = records
    }

    public static func identity(path: String, size: Int64, mtime: TimeInterval) -> String {
        "\(path)|\(size)|\(Int64((mtime * 1000).rounded()))"
    }

    public func record(path: String, size: Int64, mtime: TimeInterval) -> CaptureDateRecord? {
        records[Self.identity(path: path, size: size, mtime: mtime)]
    }

    public mutating func store(_ record: CaptureDateRecord) {
        records[record.identity] = record
    }
}

public enum CaptureDateCacheCodec {
    private static let sep: Character = "\u{1f}"

    public static func encode(_ records: [CaptureDateRecord]) -> Data {
        var text = "FUNOCAP1\n"
        for record in records {
            guard !record.identity.contains("\n"), !record.identity.contains(sep) else { continue }
            let ms = Int64((record.seconds * 1000).rounded())
            text += [
                record.identity,
                record.hasDate ? "1" : "0",
                String(ms),
                String(record.subsecMillis)
            ].joined(separator: String(sep))
            text += "\n"
        }
        return Data(text.utf8)
    }

    public static func decode(_ data: Data) -> [CaptureDateRecord]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "FUNOCAP1" else { return nil }
        lines.removeFirst()
        var records: [CaptureDateRecord] = []
        for line in lines where !line.isEmpty {
            let parts = line.split(separator: sep, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, parts[1] == "0" || parts[1] == "1",
                  let ms = Int64(parts[2]), let sub = Int(parts[3]) else { return nil }
            records.append(CaptureDateRecord(
                identity: parts[0],
                hasDate: parts[1] == "1",
                seconds: TimeInterval(ms) / 1000,
                subsecMillis: sub
            ))
        }
        return records
    }
}

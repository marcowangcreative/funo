import Foundation

/// How a photo's date and time is written in the info panel.
///
/// EXIF `DateTimeOriginal` is `yyyy:MM:dd HH:mm:ss` in the camera's own
/// clock, with no time zone. Formatting it must not shift the hour.
public enum CaptureTime {
    /// Readable camera-local time, or nil when the string is not EXIF.
    public static func display(exif raw: String) -> String? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: raw) else { return nil }
        return stamp.string(from: date)
    }

    /// File modification time, shown in UTC so the string does not depend
    /// on the machine clock. Callers that have a real capture time should
    /// prefer `display(exif:)`.
    public static func display(fileDate date: Date) -> String {
        stamp.string(from: date)
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d, yyyy  HH:mm:ss"
        return formatter
    }()
}

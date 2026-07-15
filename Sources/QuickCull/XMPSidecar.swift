import Foundation

/// XMP sidecar read/write — the bridge that makes stars, color labels and
/// rotation visible to Lightroom, Photo Mechanic, Capture One, Bridge…
///
/// Rules:
/// - Sidecars only, RAW files only. RAW originals are NEVER touched.
/// - A sidecar authored by another app (Lightroom develop settings!) is
///   NEVER overwritten — we read from it but won't stomp it.
/// - Writes are atomic and happen on a background queue, debounced —
///   the advance key never waits on disk.
enum XMPSidecar {

    private static let marker = "funo"
    /// Sidecars written before the rename carry the old toolkit string —
    /// they are still OURS to update, not foreign files to protect.
    private static let legacyMarker = "QuickCull"
    /// Lightroom's default label vocabulary — matches Theme.labelNames.
    private static let labelNames = ["", "Red", "Yellow", "Green", "Blue", "Purple"]

    static func sidecarURL(for photoURL: URL) -> URL {
        photoURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// True if we may write: no sidecar yet, or one we authored.
    static func canWrite(for photoURL: URL) -> Bool {
        let sidecar = sidecarURL(for: photoURL)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return true }
        guard let existing = try? String(contentsOf: sidecar, encoding: .utf8) else { return false }
        return existing.contains(marker) || existing.contains(legacyMarker)
    }

    @discardableResult
    static func write(rating: Int, label: Int, orientation: Int?, for photoURL: URL) -> Bool {
        guard canWrite(for: photoURL) else { return false }

        var attributes = "xmp:Rating=\"\(rating)\""
        if label >= 1, label <= 5 {
            attributes += "\n    xmp:Label=\"\(labelNames[label])\""
        }
        if let orientation, orientation != 1 {
            attributes += "\n    tiff:Orientation=\"\(orientation)\""
        }

        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="\(marker) 0.1">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
            \(attributes)/>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        do {
            try xml.write(to: sidecarURL(for: photoURL), atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("funo: XMP write failed for \(photoURL.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    /// Read rating/label from any sidecar (ours or Lightroom's), so culls
    /// done elsewhere show up here too.
    static func read(for photoURL: URL) -> (rating: Int?, label: Int?) {
        let sidecar = sidecarURL(for: photoURL)
        guard let content = try? String(contentsOf: sidecar, encoding: .utf8) else { return (nil, nil) }

        var rating: Int?
        if let value = firstMatch(in: content, pattern: "xmp:Rating\\s*=\\s*\"(-?\\d+)\"")
            ?? firstMatch(in: content, pattern: "<xmp:Rating>\\s*(-?\\d+)\\s*</xmp:Rating>") {
            rating = Int(value)
        }
        var label: Int?
        if let name = firstMatch(in: content, pattern: "xmp:Label\\s*=\\s*\"([^\"]+)\"")
            ?? firstMatch(in: content, pattern: "<xmp:Label>\\s*([^<]+?)\\s*</xmp:Label>") {
            label = labelNames.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        return (rating, label == 0 ? nil : label)
    }

    /// Compose the camera's orientation flag with the user's [ ] rotation
    /// into an EXIF orientation code for the sidecar.
    static func orientationCode(containerOrientation: Int, plusDegreesCW degrees: Int) -> Int {
        let base = ImageTransform.degreesCW(fromEXIFOrientation: containerOrientation)
        switch (((base + degrees) % 360) + 360) % 360 {
        case 90:  return 6
        case 180: return 3
        case 270: return 8
        default:  return 1
        }
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }
}

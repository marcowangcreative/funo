import Foundation

/// XMP sidecar read/write - the bridge that makes stars, color labels and
/// rotation visible to Lightroom, Photo Mechanic, Capture One, Bridge…
///
/// Rules:
/// - Sidecars only, RAW files only. RAW originals are NEVER touched.
/// - A sidecar authored by another app (Lightroom develop settings,
///   Photo Mechanic prefs) is NEVER regenerated. Rating/label changes are
///   SURGICAL: only the xmp:Rating / xmp:Label attribute values change,
///   every other byte survives verbatim. (Refusing to write at all - the
///   old rule - meant culls silently never reached Lightroom for anyone
///   re-culling a folder PM or LR had already touched.)
/// - Foreign orientation is never touched (it can interact with develop
///   settings); rotation only lands in sidecars WE authored.
/// - Writes are atomic and happen on a background queue, debounced -
///   the advance key never waits on disk.
enum XMPSidecar {

    private static let marker = "funo"
    /// Sidecars written before the rename carry the old toolkit string -
    /// they are still OURS to update, not foreign files to protect.
    private static let legacyMarker = "QuickCull"
    /// Lightroom's default label vocabulary - matches Theme.labelNames.
    private static let labelNames = ["", "Red", "Yellow", "Green", "Blue", "Purple"]

    static func sidecarURL(for photoURL: URL) -> URL {
        photoURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    @discardableResult
    static func write(rating: Int, label: Int, orientation: Int?, for photoURL: URL) -> Bool {
        let sidecar = sidecarURL(for: photoURL)
        if let existing = try? String(contentsOf: sidecar, encoding: .utf8),
           !existing.contains(marker), !existing.contains(legacyMarker) {
            // Foreign sidecar: surgical attribute update, never a rewrite.
            return surgicalUpdate(existing, rating: rating, label: label, to: sidecar)
        }

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

    /// Update ONLY xmp:Rating / xmp:Label inside someone else's sidecar.
    /// Handles both attribute form (PM, LR) and element form; inserts the
    /// attribute after rdf:about if absent. Everything the authoring app
    /// wrote - develop settings, photomechanic:* prefs - survives verbatim.
    private static func surgicalUpdate(_ content: String, rating: Int, label: Int, to sidecar: URL) -> Bool {
        var s = content

        func replaceFirst(_ pattern: String, with replacement: String, in text: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let r = Range(match.range, in: text) else { return nil }
            return text.replacingCharacters(in: r, with: replacement)
        }
        /// Insert new attributes right after the first rdf:about="…".
        func insertAttribute(_ attribute: String, in text: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: "rdf:about=\"[^\"]*\""),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(match.range, in: text) else { return nil }
            return text.replacingCharacters(in: r, with: String(text[r]) + "\n   " + attribute)
        }

        // xmp namespace must exist before we add xmp: attributes.
        if !s.contains("xmlns:xmp=") {
            guard let updated = insertAttribute("xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"", in: s) else { return false }
            s = updated
        }

        // Rating: replace attribute → replace element → insert attribute.
        if let updated = replaceFirst("xmp:Rating\\s*=\\s*\"[^\"]*\"", with: "xmp:Rating=\"\(rating)\"", in: s) {
            s = updated
        } else if let updated = replaceFirst("<xmp:Rating>[^<]*</xmp:Rating>", with: "<xmp:Rating>\(rating)</xmp:Rating>", in: s) {
            s = updated
        } else if let updated = insertAttribute("xmp:Rating=\"\(rating)\"", in: s) {
            s = updated
        } else {
            return false
        }

        // Label: set, or REMOVE when cleared (label 0).
        if label >= 1, label <= 5 {
            let name = labelNames[label]
            if let updated = replaceFirst("xmp:Label\\s*=\\s*\"[^\"]*\"", with: "xmp:Label=\"\(name)\"", in: s) {
                s = updated
            } else if let updated = replaceFirst("<xmp:Label>[^<]*</xmp:Label>", with: "<xmp:Label>\(name)</xmp:Label>", in: s) {
                s = updated
            } else if let updated = insertAttribute("xmp:Label=\"\(name)\"", in: s) {
                s = updated
            }
        } else {
            if let updated = replaceFirst("\\s*xmp:Label\\s*=\\s*\"[^\"]*\"", with: "", in: s) {
                s = updated
            } else if let updated = replaceFirst("\\s*<xmp:Label>[^<]*</xmp:Label>", with: "", in: s) {
                s = updated
            }
        }

        guard s != content else { return true } // nothing to change
        do {
            try s.write(to: sidecar, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("funo: surgical XMP update failed for \(sidecar.lastPathComponent): \(error.localizedDescription)")
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

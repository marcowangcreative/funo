import Foundation
import ImageIO
import AppKit

/// Canon CR3 files are ISO-BMFF (MP4-family) containers. Track 1 is a
/// full-resolution JPEG rendition of the frame - the same pixels the camera
/// would have written as a Large JPEG. Apple's ImageIO only surfaces the
/// smaller 1620×1080 PRVW preview, so for crisp full-screen previews we pull
/// the full-size JPEG straight out of the container ourselves. No RAW decode.
///
/// Verified against Canon EOS R3 files (tracks: 1 = 6000×4000 JPEG,
/// 2 = 2004×1336 proxy, 3 = CRAW sensor data, 4 = metadata).
enum CR3PreviewExtractor {

    /// Returns the full-size embedded JPEG bytes, or nil if the container
    /// doesn't match expectations (then the normal ImageIO path takes over).
    static func fullSizeJPEGData(from url: URL) -> Data? {
        // Memory-map: we touch only the moov header pages + the JPEG range.
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }

        var candidates: [(offset: Int, size: Int)] = []

        forEachBox(in: data, from: 0, to: data.count) { type, start, end in
            guard type == "moov" else { return }
            forEachBox(in: data, from: start, to: end) { t2, s2, e2 in
                guard t2 == "trak" else { return }
                if let sample = sampleLocation(in: data, trakStart: s2, trakEnd: e2) {
                    candidates.append(sample)
                }
            }
        }

        for (offset, size) in candidates {
            guard size > 200_000,                 // skip thumbnail-sized tracks
                  offset + size <= data.count,
                  data[offset] == 0xFF, data[offset + 1] == 0xD8 // JPEG SOI
            else { continue }
            return data.subdata(in: offset..<(offset + size))
        }
        return nil
    }

    /// Decode the full-size embedded JPEG downsampled to `maxPixel`.
    /// The embedded JPEG carries NO orientation tag - the camera writes the
    /// rotation flag on the CR3 container - so portrait frames must be
    /// rotated using the container's orientation or they display sideways.
    static func decodePreview(url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let jpeg = fullSizeJPEGData(from: url),
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // honors a tag if one exists
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard var cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        // If the JPEG itself had no orientation, fall back to the container's.
        let jpegProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let jpegHasOrientation = jpegProps?[kCGImagePropertyOrientation] != nil
        if !jpegHasOrientation {
            let containerOrientation = ImageTransform.containerOrientation(of: url)
            let degrees = ImageTransform.degreesCW(fromEXIFOrientation: containerOrientation)
            if degrees != 0 {
                cg = ImageTransform.rotate(cg, degreesCW: degrees)
            }
        }
        return NSImage(cgImage: cg, size: .zero)
    }

    // MARK: - ISO-BMFF plumbing

    private static func be32(_ d: Data, _ o: Int) -> Int? {
        guard o >= 0, o + 4 <= d.count else { return nil }
        return Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3])
    }

    private static func be64(_ d: Data, _ o: Int) -> Int? {
        guard let hi = be32(d, o), let lo = be32(d, o + 4), hi >= 0 else { return nil }
        return (hi << 32) | lo
    }

    private static func boxType(_ d: Data, _ o: Int) -> String? {
        guard o + 4 <= d.count else { return nil }
        return String(bytes: d[o..<(o + 4)], encoding: .isoLatin1)
    }

    /// Iterate sibling boxes in [from, to). Calls body(type, payloadStart, boxEnd).
    private static func forEachBox(in d: Data, from: Int, to: Int, _ body: (String, Int, Int) -> Void) {
        var offset = from
        while offset + 8 <= to {
            guard var size = be32(d, offset), let type = boxType(d, offset + 4) else { return }
            var headerLength = 8
            if size == 1 {
                guard let large = be64(d, offset + 8) else { return }
                size = large
                headerLength = 16
            } else if size == 0 {
                size = to - offset
            }
            guard size >= headerLength, offset + size <= to else { return } // corrupt/truncated
            body(type, offset + headerLength, offset + size)
            offset += size
        }
    }

    /// Dig trak → mdia → minf → stbl and read the first sample's offset+size.
    private static func sampleLocation(in d: Data, trakStart: Int, trakEnd: Int) -> (offset: Int, size: Int)? {
        var sampleOffset: Int?
        var sampleSize: Int?

        func walk(_ from: Int, _ to: Int) {
            forEachBox(in: d, from: from, to: to) { type, start, end in
                switch type {
                case "mdia", "minf", "stbl":
                    walk(start, end)
                case "stsz":
                    // uint32 version/flags, uint32 fixed_size, uint32 count, [sizes]
                    if let fixed = be32(d, start + 4), fixed > 0 {
                        sampleSize = fixed
                    } else {
                        sampleSize = be32(d, start + 12)
                    }
                case "stco":
                    // uint32 version/flags, uint32 count, uint32 offsets[0]
                    sampleOffset = be32(d, start + 8)
                case "co64":
                    sampleOffset = be64(d, start + 8)
                default:
                    break
                }
            }
        }
        walk(trakStart, trakEnd)

        guard let o = sampleOffset, let s = sampleSize, o > 0, s > 0 else { return nil }
        return (o, s)
    }
}

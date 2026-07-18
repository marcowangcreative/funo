import Foundation
import ImageIO

/// A single photo in a folder. The file on disk is the source of truth -
/// this struct is just a lightweight handle to it.
struct PhotoAsset: Hashable {
    let url: URL
    let filename: String
    let isRAW: Bool
    /// Cheap from enumeration; ≈ capture time for camera files. The EXIF
    /// capture date replaces it asynchronously for exact sorting.
    let modificationDate: Date
    /// True when a same-named JPEG sits next to this RAW (we show the pair as one item).
    var hasJPEGPair: Bool = false

    /// Stable identity for ratings/cache. Path is fine for a prototype;
    /// production should key on volume ID + file resource ID + mtime.
    var id: String { url.path }

    static let rawExtensions: Set<String> = [
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
        "rw2", "dng", "pef", "srw", "x3f", "3fr", "erf", "iiq", "mos", "rwl", "raw"
    ]
    static let jpegExtensions: Set<String> = ["jpg", "jpeg"]
    static let otherImageExtensions: Set<String> = [
        "png", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp", "avif"
    ]

    static func isImageExtension(_ ext: String) -> Bool {
        let e = ext.lowercased()
        return rawExtensions.contains(e) || jpegExtensions.contains(e) || otherImageExtensions.contains(e)
    }
}

enum FolderScanner {

    struct ScanResult {
        let assets: [PhotoAsset]
        let elapsed: TimeInterval
        let pairedJPEGCount: Int
    }

    /// Shallow, non-recursive scan of one directory. Never walks subfolders -
    /// clicking a wedding folder must not crawl the whole card.
    static func scan(_ folder: URL) -> ScanResult {
        let start = Date()
        let fm = FileManager.default

        // FAST readdir. The URL API with .skipsHiddenFiles stat-ed EVERY
        // entry to resolve its hidden flag - measured 7.7 s on a 5,700-file
        // external folder. contentsOfDirectory(atPath:) is a raw readdir
        // with zero per-file I/O; we skip dotfiles by name instead (camera
        // output never sets the hidden FLAG without a leading dot). mtime is
        // only a capture-sort fallback and streams in later via
        // scanCaptureDates, so it isn't read here at all.
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []

        var images: [PhotoAsset] = []
        images.reserveCapacity(names.count)
        for name in names {
            if name.hasPrefix(".") { continue }
            let ext = (name as NSString).pathExtension
            guard PhotoAsset.isImageExtension(ext) else { continue }
            let isRaw = PhotoAsset.rawExtensions.contains(ext.lowercased())
            let url = folder.appendingPathComponent(name)
            images.append(PhotoAsset(url: url, filename: name, isRAW: isRaw, modificationDate: .distantPast))
        }

        // RAW+JPEG pairing: same base name → one grid item (the RAW), badged.
        var rawBaseNames = Set<String>()
        var jpegBaseNames = Set<String>()
        for asset in images {
            let base = asset.url.deletingPathExtension().lastPathComponent.lowercased()
            if asset.isRAW {
                rawBaseNames.insert(base)
            } else if PhotoAsset.jpegExtensions.contains(asset.url.pathExtension.lowercased()) {
                jpegBaseNames.insert(base)
            }
        }

        var result: [PhotoAsset] = []
        var pairedJPEGs = 0
        for var asset in images {
            let base = asset.url.deletingPathExtension().lastPathComponent.lowercased()
            let ext = asset.url.pathExtension.lowercased()
            if PhotoAsset.jpegExtensions.contains(ext), rawBaseNames.contains(base) {
                pairedJPEGs += 1
                continue // hidden behind its RAW
            }
            if asset.isRAW, jpegBaseNames.contains(base) {
                asset.hasJPEGPair = true
            }
            result.append(asset)
        }

        result.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        return ScanResult(assets: result, elapsed: Date().timeIntervalSince(start), pairedJPEGCount: pairedJPEGs)
    }

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    /// Exact capture time from EXIF (header read only). nil → caller falls
    /// back to the file's modification date.
    static func captureDate(of url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String else {
            return nil
        }
        return exifDateFormatter.date(from: raw)
    }
}

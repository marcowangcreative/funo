import CoreGraphics
import ImageIO

/// Shared ImageIO options.
///
/// `kCGImageSourceShouldCache` defaults to **true**. Left on, ImageIO keeps
/// a decoded copy of the full frame in a process-wide cache for every
/// source it has touched. Thumbnail calls that don't repeat the flag do
/// the same, and the CGImage they return can pin that full-frame buffer
/// for as long as the thumbnail lives. A few hundred of those is the
/// multi-tens-of-gigabytes climb. Every decode here turns the cache off,
/// asks for an immediately-realized thumbnail (so the pixels don't alias
/// the source), and the caller drops the source cache before releasing it.
enum ImageIODecode {

    static let sourceOptions: [CFString: Any] = [
        kCGImageSourceShouldCache: false
    ]

    static func makeSource(url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary)
    }

    static func makeSource(data: Data) -> CGImageSource? {
        CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary)
    }

    /// `embeddedOnly` asks for a camera preview and will not develop a RAW.
    /// The other path forces a thumbnail and is allowed to decode, but
    /// ImageIO downsamples while decoding — it never materializes a 60MP
    /// bitmap just so we can scale it afterwards.
    static func thumbnail(source: CGImageSource, maxPixel: CGFloat, embeddedOnly: Bool) -> CGImage? {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCache: false,
            // Decode into the thumbnail's own buffer NOW. Without this the
            // CGImage is a lazy view over the source, and releasing the
            // source (or the source's cache) either crashes or, worse,
            // keeps the full-resolution decode alive for the thumbnail's
            // whole lifetime.
            kCGImageSourceShouldCacheImmediately: true
        ]
        if embeddedOnly {
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = false
        } else {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func dropCache(_ source: CGImageSource) {
        CGImageSourceRemoveCacheAtIndex(source, 0)
    }

    /// ImageIO often returns an existing embedded preview at its native
    /// size and ignores `kCGImageSourceThumbnailMaxPixelSize` on that path
    /// (a 6000×4000 camera JPEG "thumbnail"). Copy into our own 8-bit
    /// buffer at or under `maxPixel` so the bitmap we keep is the size we
    /// asked for, and so it does not share ImageIO's data provider.
    /// Nil only if a context can't be created; callers must not keep
    /// `image` itself in that case, because it may alias the source cache.
    static func materialized(_ image: CGImage, maxPixel: CGFloat) -> CGImage? {
        let srcW = image.width
        let srcH = image.height
        guard srcW > 0, srcH > 0 else { return nil }
        let longest = CGFloat(max(srcW, srcH))
        let scale: CGFloat = (maxPixel > 0 && longest > maxPixel) ? (maxPixel / longest) : 1
        let outW = max(1, Int((CGFloat(srcW) * scale).rounded(.towardZero)))
        let outH = max(1, Int((CGFloat(srcH) * scale).rounded(.towardZero)))

        let bitmap = CGImageAlphaInfo.premultipliedLast.rawValue
        let preferred = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: outW, height: outH,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: preferred, bitmapInfo: bitmap)
            ?? CGContext(data: nil, width: outW, height: outH,
                         bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: bitmap)
        guard let ctx else { return nil }
        ctx.interpolationQuality = scale < 1 ? .medium : .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return ctx.makeImage()
    }

    /// Byte size of the bitmap we actually allocated. `NSImage.size` is in
    /// points, so a cost computed from it is smaller than the buffer (a
    /// quarter, on a 2x display) and for a CGImage-backed image it can
    /// still be zero until something draws it. The old cache used that
    /// number, and NSCache does not treat it as a hard ceiling anyway.
    static func byteCost(_ image: CGImage) -> Int {
        let row = image.bytesPerRow > 0 ? image.bytesPerRow : image.width * 4
        let bytes = row * max(image.height, 1)
        return max(1, bytes)
    }
}

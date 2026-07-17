import Foundation
import CoreGraphics
import ImageIO

/// CGImage rotation utilities. Two jobs:
/// 1. Apply the CR3 *container's* orientation to its embedded JPEG - the
///    camera writes the rotation flag on the container, not the JPEG bytes,
///    so portrait frames decode sideways without this.
/// 2. Apply the user's manual [ / ] rotation.
enum ImageTransform {

    /// EXIF orientation (1–8) → clockwise degrees. Mirrored variants are
    /// treated as their rotated equivalents (rare from cameras).
    static func degreesCW(fromEXIFOrientation orientation: Int) -> Int {
        switch orientation {
        case 3, 4: return 180
        case 6, 5: return 90
        case 8, 7: return 270
        default:   return 0
        }
    }

    /// The orientation flag from a file's metadata (cheap header read).
    static func containerOrientation(of url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return 1
        }
        if let value = props[kCGImagePropertyOrientation] as? UInt32 { return Int(value) }
        if let value = props[kCGImagePropertyOrientation] as? Int { return value }
        return 1
    }

    /// Rotate clockwise by 0/90/180/270 degrees.
    static func rotate(_ image: CGImage, degreesCW: Int) -> CGImage {
        let degrees = ((degreesCW % 360) + 360) % 360
        guard degrees != 0 else { return image }
        let w = image.width
        let h = image.height
        let outW = degrees == 180 ? w : h
        let outH = degrees == 180 ? h : w
        guard let ctx = CGContext(data: nil, width: outW, height: outH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        // CG coordinates are y-up: negative angle = visually clockwise.
        ctx.rotate(by: -CGFloat(degrees) * .pi / 180)
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage() ?? image
    }
}

import AppKit
import QuartzCore

extension NSImage {
    /// CGImage suitable for assigning to `CALayer.contents`.
    ///
    /// `cgImage(forProposedRect: nil)` returns nil for images created off the
    /// main thread with `size: .zero` — there is no screen to resolve that
    /// size against — so the grid cell or the expanded stage kept whatever
    /// pixels it already had (or stayed blank). Prefer an explicit rect, then
    /// a bitmap rep, and only then the proposed-rect-nil fallback.
    func quickCullCGImage() -> CGImage? {
        var proposed = CGRect(origin: .zero, size: size)
        if proposed.width >= 1, proposed.height >= 1,
           let cg = cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
            return cg
        }
        for rep in representations {
            if let bitmap = rep as? NSBitmapImageRep, let cg = bitmap.cgImage {
                return cg
            }
        }
        return cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

enum QuickCullImage {
    /// Explicit pixel size so a background-thread NSImage doesn't depend on
    /// the main screen to learn how big it is.
    static func fromCGImage(_ cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Layer contents changes otherwise animate. During scroll and label
    /// updates that fade reads as flicker.
    static func setContents(_ cg: CGImage?, of layer: CALayer?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = cg
        CATransaction.commit()
    }
}

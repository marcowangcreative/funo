import Foundation

/// Whether a decode that has reached the main thread may publish.
///
/// Only the operation still registered for its cache key may touch that
/// key's waiters or pending slot. A prefetch cancelled once it scrolled
/// away (or a reload that dropped the old op) used to finish afterward and
/// hand its result — sometimes nil — to the waiters of the replacement
/// request. The cell on screen then stayed blank or showed the stale frame,
/// and the real decode's completion found nobody left to tell.
public enum ThumbnailDelivery {
    public static func shouldPublish(pendingOpIsSelf: Bool) -> Bool {
        pendingOpIsSelf
    }
}

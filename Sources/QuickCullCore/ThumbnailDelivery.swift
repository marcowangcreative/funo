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

/// What a thumbnail attempt produced. A cancellation is not a broken file.
public enum ThumbOutcome: Equatable {
    case ready
    case failed
    case cancelled
}

/// How many real decode failures a visible cell absorbs before it stops
/// asking. Cancellations do not count, and a cancelled request that still
/// has a waiter is queued again instead of being handed out as a nil image.
public enum ThumbRetryPolicy {
    public static let failureCap = 3

    public struct Decision: Equatable {
        public var failures: Int
        public var giveUp: Bool
        /// Start the decode again. The previous attempt is not delivered.
        public var requeue: Bool

        public init(failures: Int, giveUp: Bool, requeue: Bool) {
            self.failures = failures
            self.giveUp = giveUp
            self.requeue = requeue
        }
    }

    public static func decide(outcome: ThumbOutcome, failures: Int, hasWaiter: Bool) -> Decision {
        switch outcome {
        case .ready:
            return Decision(failures: 0, giveUp: false, requeue: false)
        case .cancelled:
            return Decision(failures: failures, giveUp: false, requeue: hasWaiter)
        case .failed:
            let next = failures + 1
            let giveUp = next >= failureCap
            return Decision(failures: next, giveUp: giveUp, requeue: hasWaiter && !giveUp)
        }
    }
}

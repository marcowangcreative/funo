import Foundation

/// What a face-analysis attempt actually learned.
public enum FaceDecodeOutcome: Equatable {
    /// The file decoded and Vision ran. Zero faces is a real answer
    /// (a landscape, a product shot) and may be cached.
    case settled(faceCount: Int)
    /// The file could not be decoded — busy card, missing preview, a read
    /// that lost the race with thumbnail I/O. This is not "no faces".
    case unavailable
}

/// What the analyzer should do with that outcome.
public enum FaceCacheDecision: Equatable {
    /// Remember it in memory and on disk.
    case commit(faceCount: Int)
    /// Try again. Do not write a cache entry.
    case retry
    /// Stop retrying for this pass. Still do not cache a fake empty result;
    /// a later folder load gets a fresh budget and can succeed.
    case abandon
}

/// What the faces panel should show for one photo.
public enum FacePanelPhase: Equatable {
    case pending
    case unavailable
    case noFaces
    case faces(Int)
}

/// Per-photo face-result bookkeeping.
///
/// A failed decode used to be stored as `FaceAnalysis(faces: [])` — in memory
/// and in the disk cache — so the panel treated a busy read as "scanned, no
/// faces" and hid until somebody hit Rescan. Settled results (including a
/// true zero) commit; transient failures retry, then abandon without caching.
public struct FaceResultLedger: Equatable {
    public let maxFailures: Int
    public private(set) var committed: [String: Int] = [:]
    private var failures: [String: Int] = [:]
    public private(set) var abandoned: Set<String> = []

    public init(maxFailures: Int = 3) {
        self.maxFailures = max(1, maxFailures)
    }

    public mutating func record(id: String, outcome: FaceDecodeOutcome) -> FaceCacheDecision {
        switch outcome {
        case .settled(let count):
            let faces = max(0, count)
            committed[id] = faces
            failures[id] = nil
            abandoned.remove(id)
            return .commit(faceCount: faces)
        case .unavailable:
            let n = (failures[id] ?? 0) + 1
            failures[id] = n
            if n <= maxFailures { return .retry }
            abandoned.insert(id)
            return .abandon
        }
    }

    /// A new folder pass (or an explicit rescan) gets a fresh retry budget.
    /// Committed verdicts are left alone — the caller only resets ids it is
    /// about to analyze again.
    public mutating func resetAttempts(_ id: String) {
        failures[id] = nil
        abandoned.remove(id)
    }

    public mutating func forget(_ id: String) {
        committed[id] = nil
        failures[id] = nil
        abandoned.remove(id)
    }

    public func isAbandoned(_ id: String) -> Bool { abandoned.contains(id) }

    /// `storedFaceCount` is the in-memory verdict (nil = not committed).
    /// Crops arriving is what flips `.faces` from "loading" to "showing";
    /// the panel asks `showsCrops` separately. This phase is the verdict
    /// itself: pending / unavailable / none / some.
    public func phase(id: String, storedFaceCount: Int?) -> FacePanelPhase {
        if let storedFaceCount {
            return storedFaceCount == 0 ? .noFaces : .faces(storedFaceCount)
        }
        if abandoned.contains(id) { return .unavailable }
        return .pending
    }
}

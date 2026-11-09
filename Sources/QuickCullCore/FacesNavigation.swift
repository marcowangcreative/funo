import Foundation

/// What the faces panel knows about a photo at the moment of a decision.
public enum FacesCropAvailability: Equatable {
    /// Analysis has not committed a verdict.
    case notAnalyzed
    /// The retry budget was spent. This is not "no faces".
    case unavailable
    /// A real decode found nobody.
    case noFaces
    /// Crops are already in memory. `faceCount` is how many will be shown.
    case cropsCached(Int)
    /// A verdict with faces exists, but the crops have not been cut yet.
    case facesKnownCropsMissing(Int)
}

/// What the panel should do. The keypress path and the settle path are
/// different on purpose: a keypress may paint a cache hit, and it must not
/// tear the panel down or start a decode.
public enum FacesNavAction: Equatable {
    case showCached(faceCount: Int)
    case showNoFaces
    case showUnavailable
    case showScanning
    case showLoading
    case holdForDecode
}

/// Navigation policy for the faces panel.
///
/// Arrow keys used to clear the panel on the keypress (so it flashed
/// "scanning…" / "loading faces…") and wait out a debounce before fetching
/// crops, including ones that were already cached. Cached results paint on
/// the keypress. Uncached work waits until the frame is still current.
public enum FacesNavigation {

    /// Longer than key-repeat, shorter than a deliberate look. A skim
    /// invalidates the timer and never starts the decode.
    public static let settleDelay: TimeInterval = 0.12

    /// Decision for the keypress itself. Never starts a decode and never
    /// asks the panel to rebuild into a scanning/loading state.
    public static func onAdvance(_ availability: FacesCropAvailability) -> FacesNavAction {
        switch availability {
        case .cropsCached(let count) where count > 0:
            return .showCached(faceCount: count)
        case .cropsCached, .noFaces:
            return .showNoFaces
        case .unavailable:
            return .showUnavailable
        case .notAnalyzed, .facesKnownCropsMissing:
            return .holdForDecode
        }
    }

    /// Decision once this frame has stayed current. This is the only path
    /// that starts a crop decode or shows "scanning…".
    public static func onSettle(_ availability: FacesCropAvailability) -> FacesNavAction {
        switch availability {
        case .cropsCached(let count) where count > 0:
            return .showCached(faceCount: count)
        case .cropsCached, .noFaces:
            return .showNoFaces
        case .unavailable:
            return .showUnavailable
        case .notAnalyzed:
            return .showScanning
        case .facesKnownCropsMissing:
            return .showLoading
        }
    }

    /// Column count for the face grid. Same count means same columns, so
    /// equal counts can swap images without rebuilding the view tree.
    public static func columns(forFaceCount count: Int) -> Int {
        switch count {
        case 1: return 1
        case 2...6: return 2
        case 7...12: return 3
        case 13...: return 4
        default: return 0
        }
    }

    /// True when the new photo can replace images in the cells already on screen.
    public static func swapsInPlace(from previousCount: Int, to nextCount: Int) -> Bool {
        nextCount > 0 && previousCount == nextCount
            && columns(forFaceCount: previousCount) == columns(forFaceCount: nextCount)
    }
}

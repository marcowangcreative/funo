import XCTest
@testable import QuickCullCore

final class FacesNavigationTests: XCTestCase {

    func testCachedCropsPaintOnTheKeypress() {
        XCTAssertEqual(FacesNavigation.onAdvance(.cropsCached(3)), .showCached(faceCount: 3))
        XCTAssertEqual(FacesNavigation.onAdvance(.cropsCached(1)), .showCached(faceCount: 1))
    }

    func testSettledEmptyVerdictsPaintOnTheKeypress() {
        XCTAssertEqual(FacesNavigation.onAdvance(.noFaces), .showNoFaces)
        XCTAssertEqual(FacesNavigation.onAdvance(.cropsCached(0)), .showNoFaces)
        XCTAssertEqual(FacesNavigation.onAdvance(.unavailable), .showUnavailable)
    }

    func testKeypressDoesNotStartADecodeOrAScanningRebuild() {
        // The flash was a keypress that tore the panel down into "scanning…"
        // and then decoded. Uncached frames hold the chrome instead.
        XCTAssertEqual(FacesNavigation.onAdvance(.notAnalyzed), .holdForDecode)
        XCTAssertEqual(FacesNavigation.onAdvance(.facesKnownCropsMissing(4)), .holdForDecode)
        let advanceActions: [FacesNavAction] = [
            FacesNavigation.onAdvance(.notAnalyzed),
            FacesNavigation.onAdvance(.facesKnownCropsMissing(2)),
            FacesNavigation.onAdvance(.cropsCached(2))
        ]
        XCTAssertFalse(advanceActions.contains(.showScanning))
        XCTAssertFalse(advanceActions.contains(.showLoading))
    }

    func testSettleIsWhatStartsWork() {
        XCTAssertEqual(FacesNavigation.onSettle(.notAnalyzed), .showScanning)
        XCTAssertEqual(FacesNavigation.onSettle(.facesKnownCropsMissing(2)), .showLoading)
        XCTAssertEqual(FacesNavigation.onSettle(.cropsCached(2)), .showCached(faceCount: 2))
        XCTAssertEqual(FacesNavigation.onSettle(.noFaces), .showNoFaces)
        XCTAssertEqual(FacesNavigation.onSettle(.unavailable), .showUnavailable)
    }

    func testSkippedFrameNeverReachesSettle() {
        // A burst of arrows stays on `onAdvance`. Only a frame that survives
        // `settleDelay` is allowed to decode.
        XCTAssertEqual(FacesNavigation.onAdvance(.facesKnownCropsMissing(5)), .holdForDecode)
        XCTAssertGreaterThan(FacesNavigation.settleDelay, 0.05)
        XCTAssertLessThan(FacesNavigation.settleDelay, 0.2)
    }

    func testSameFaceCountSwapsInPlace() {
        XCTAssertTrue(FacesNavigation.swapsInPlace(from: 4, to: 4))
        XCTAssertTrue(FacesNavigation.swapsInPlace(from: 1, to: 1))
        XCTAssertFalse(FacesNavigation.swapsInPlace(from: 4, to: 5))
        XCTAssertFalse(FacesNavigation.swapsInPlace(from: 4, to: 0))
        XCTAssertFalse(FacesNavigation.swapsInPlace(from: 0, to: 3))
    }

    func testColumnBreaksMatchTheGrid() {
        XCTAssertEqual(FacesNavigation.columns(forFaceCount: 0), 0)
        XCTAssertEqual(FacesNavigation.columns(forFaceCount: 1), 1)
        XCTAssertEqual(FacesNavigation.columns(forFaceCount: 2), 2)
        XCTAssertEqual(FacesNavigation.columns(forFaceCount: 6), 2)
        XCTAssertEqual(FacesNavigation.columns(forFaceCount: 7), 3)
        XCTAssertEqual(FacesNavigation.columns(forFaceCount: 12), 3)
        XCTAssertEqual(FacesNavigation.columns(forFaceCount: 13), 4)
        XCTAssertEqual(FacesNavigation.columns(forFaceCount: 40), 4)
    }
}

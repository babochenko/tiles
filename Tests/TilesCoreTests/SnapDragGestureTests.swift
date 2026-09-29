import CoreGraphics
import XCTest
@testable import TilesCore

final class SnapDragGestureTests: XCTestCase {
    private let start = CGPoint(x: 100, y: 100)

    func testClickAndReleaseDoesNotSnap() {
        var gesture = SnapDragGesture()
        gesture.mouseDown(at: start)

        XCTAssertFalse(gesture.mouseUp())
    }

    func testStationaryPressedMouseDoesNotShowPreviewOrTriggerHaptic() {
        var gesture = SnapDragGesture()
        gesture.mouseDown(at: start)

        XCTAssertFalse(gesture.mouseDragged(to: start))
        XCTAssertFalse(gesture.mouseDragged(to: start))
        XCTAssertFalse(gesture.isActive)
        XCTAssertFalse(gesture.mouseUp())
    }

    func testPointerJitterDoesNotShowPreviewOrTriggerHaptic() {
        var gesture = SnapDragGesture()
        gesture.mouseDown(at: start)

        XCTAssertFalse(gesture.mouseDragged(to: CGPoint(x: 102, y: 102)))
        XCTAssertFalse(gesture.mouseDragged(to: CGPoint(x: 97, y: 100)))
        XCTAssertFalse(gesture.mouseUp())
    }

    func testMovementAtThresholdActivatesPreviewAndAllowsSnap() {
        var gesture = SnapDragGesture()
        gesture.mouseDown(at: start)

        XCTAssertTrue(gesture.mouseDragged(to: CGPoint(x: 104, y: 100)))
        XCTAssertTrue(gesture.isActive)
        XCTAssertTrue(gesture.mouseUp())
    }

    func testDiagonalMovementBeyondThresholdActivatesDrag() {
        var gesture = SnapDragGesture()
        gesture.mouseDown(at: start)

        XCTAssertTrue(gesture.mouseDragged(to: CGPoint(x: 103, y: 103)))
        XCTAssertTrue(gesture.mouseUp())
    }

    func testActivatedDragStaysActiveWhenCursorReturnsToStart() {
        var gesture = SnapDragGesture()
        gesture.mouseDown(at: start)

        XCTAssertTrue(gesture.mouseDragged(to: CGPoint(x: 110, y: 100)))
        XCTAssertTrue(gesture.mouseDragged(to: start))
        XCTAssertTrue(gesture.mouseUp())
    }

    func testMouseUpResetsGesture() {
        var gesture = SnapDragGesture()
        gesture.mouseDown(at: start)
        XCTAssertTrue(gesture.mouseDragged(to: CGPoint(x: 104, y: 100)))

        XCTAssertTrue(gesture.mouseUp())
        XCTAssertFalse(gesture.isActive)
        XCTAssertFalse(gesture.mouseDragged(to: CGPoint(x: 120, y: 100)))
        XCTAssertFalse(gesture.mouseUp())
    }

    func testNewMouseDownResetsAnActiveDrag() {
        var gesture = SnapDragGesture()
        gesture.mouseDown(at: start)
        XCTAssertTrue(gesture.mouseDragged(to: CGPoint(x: 104, y: 100)))

        gesture.mouseDown(at: CGPoint(x: 200, y: 200))

        XCTAssertFalse(gesture.isActive)
        XCTAssertFalse(gesture.mouseUp())
    }

    func testExplicitResetCancelsSnap() {
        var gesture = SnapDragGesture()
        gesture.mouseDown(at: start)
        XCTAssertTrue(gesture.mouseDragged(to: CGPoint(x: 104, y: 100)))

        gesture.reset()

        XCTAssertFalse(gesture.isActive)
        XCTAssertFalse(gesture.mouseUp())
    }
}

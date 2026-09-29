import CoreGraphics
import XCTest
@testable import TilesCore

final class TilingGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)

    func testSideZonesAre60PixelsAndTopZoneIs30Pixels() {
        XCTAssertEqual(TilingGeometry.snapZone(at: CGPoint(x: 59, y: 400), in: screen), .left)
        XCTAssertNil(TilingGeometry.snapZone(at: CGPoint(x: 60, y: 400), in: screen))
        XCTAssertEqual(TilingGeometry.snapZone(at: CGPoint(x: 600, y: 871), in: screen), .top)
        XCTAssertNil(TilingGeometry.snapZone(at: CGPoint(x: 600, y: 870), in: screen))
    }

    func testTopZoneTakesPriorityAtCornersAndUsesFullscreen() {
        XCTAssertEqual(TilingGeometry.snapZone(at: CGPoint(x: 1, y: 899), in: screen), .top)
        XCTAssertEqual(TilingGeometry.arrange(existing: [], inserting: 7, in: .top), [LayoutSlot(windowID: 7, start: 0, end: 6)])
    }

    func testOneTwoAndThreeWindowLayouts() {
        let one = TilingGeometry.arrange(existing: [], inserting: 1, in: .left)
        XCTAssertEqual(one, [LayoutSlot(windowID: 1, start: 0, end: 3)])
        let two = TilingGeometry.arrange(existing: one, inserting: 2, in: .right)
        XCTAssertEqual(two, [LayoutSlot(windowID: 1, start: 0, end: 3), LayoutSlot(windowID: 2, start: 3, end: 6)])
        let three = TilingGeometry.arrange(existing: two, inserting: 3, in: .right)
        XCTAssertEqual(three, [LayoutSlot(windowID: 1, start: 0, end: 2), LayoutSlot(windowID: 2, start: 2, end: 4), LayoutSlot(windowID: 3, start: 4, end: 6)])
    }

    func testFourthWindowReplacesOnlyEdgeWindow() {
        let existing = [LayoutSlot(windowID: 1, start: 0, end: 2), LayoutSlot(windowID: 2, start: 2, end: 4), LayoutSlot(windowID: 3, start: 4, end: 6)]
        XCTAssertEqual(TilingGeometry.arrange(existing: existing, inserting: 4, in: .left).map(\.windowID), [4, 2, 3])
        XCTAssertEqual(TilingGeometry.arrange(existing: existing, inserting: 4, in: .right).map(\.windowID), [1, 2, 4])
    }

    func testMarginsAre15AtScreenEdgesAnd15BetweenWindows() {
        let left = TilingGeometry.frame(for: LayoutSlot(windowID: 1, start: 0, end: 3), in: screen)
        let right = TilingGeometry.frame(for: LayoutSlot(windowID: 2, start: 3, end: 6), in: screen)
        XCTAssertEqual(left.minX, 15)
        XCTAssertEqual(right.maxX, 1185)
        XCTAssertEqual(right.minX - left.maxX, 15)
        XCTAssertEqual(left.minY, 15)
        XCTAssertEqual(left.maxY, 885)
    }

    func testPreviewRangesMatchFutureDrop() {
        XCTAssertEqual(TilingGeometry.previewRange(existingCount: 0, zone: .left), 0...0.5)
        XCTAssertEqual(TilingGeometry.previewRange(existingCount: 1, zone: .right), 0.5...1)
        XCTAssertEqual(TilingGeometry.previewRange(existingCount: 2, zone: .right), (2.0 / 3.0)...1)
        XCTAssertEqual(TilingGeometry.previewRange(existingCount: 2, zone: .top), 0...1)
    }

    func testHapticFiresOnEnterExitAndZoneChangeOnly() {
        XCTAssertTrue(TilingGeometry.shouldHaptic(from: nil, to: .left))
        XCTAssertTrue(TilingGeometry.shouldHaptic(from: .left, to: nil))
        XCTAssertTrue(TilingGeometry.shouldHaptic(from: .left, to: .top))
        XCTAssertFalse(TilingGeometry.shouldHaptic(from: nil, to: nil))
        XCTAssertFalse(TilingGeometry.shouldHaptic(from: .right, to: .right))
    }

    func testMenuBarAndInteractivePanelsAreIgnoredButClickThroughOverlayIsNot() {
        let visible = CGRect(x: 0, y: 0, width: 1200, height: 875)
        XCTAssertTrue(TilingGeometry.shouldIgnoreMouseDown(at: CGPoint(x: 1000, y: 890), screenVisibleFrame: visible, overInteractiveTilesWindow: false))
        XCTAssertTrue(TilingGeometry.shouldIgnoreMouseDown(at: CGPoint(x: 500, y: 500), screenVisibleFrame: visible, overInteractiveTilesWindow: true))
        XCTAssertFalse(TilingGeometry.shouldIgnoreMouseDown(at: CGPoint(x: 500, y: 500), screenVisibleFrame: visible, overInteractiveTilesWindow: false))
    }

    func testLinkedResizeIsContinuousAndMaintains15PixelGap() {
        let left = CGRect(x: 15, y: 15, width: 577.5, height: 870)
        let right = CGRect(x: 607.5, y: 15, width: 577.5, height: 870)
        let frames = TilingGeometry.linkedFrames(left: left, right: right, divider: 700)
        XCTAssertEqual(frames.left.maxX, 692.5)
        XCTAssertEqual(frames.right.minX, 707.5)
        XCTAssertEqual(frames.right.minX - frames.left.maxX, 15)
        XCTAssertEqual(frames.right.maxX, 1185)
    }
}

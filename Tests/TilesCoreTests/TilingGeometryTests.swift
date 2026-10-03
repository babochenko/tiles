import CoreGraphics
import XCTest
@testable import TilesCore

final class TilingGeometryTests: XCTestCase {
    func testSnapDragMustStartInWindowTitleBar() {
        let frame = CGRect(x: 100, y: 200, width: 600, height: 500)

        XCTAssertTrue(TilingGeometry.isTitleBarDragStart(at: CGPoint(x: 400, y: 680), windowFrame: frame))
        XCTAssertTrue(TilingGeometry.isTitleBarDragStart(at: CGPoint(x: 400, y: 660), windowFrame: frame))
        XCTAssertFalse(TilingGeometry.isTitleBarDragStart(at: CGPoint(x: 400, y: 659), windowFrame: frame))
        XCTAssertFalse(TilingGeometry.isTitleBarDragStart(at: CGPoint(x: 400, y: 400), windowFrame: frame))
        XCTAssertFalse(TilingGeometry.isTitleBarDragStart(at: CGPoint(x: 99, y: 680), windowFrame: frame))
    }

    private let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)

    func testLeftZoneSkipsStageManagerStripAndUsesBottomCorner() {
        XCTAssertNil(TilingGeometry.snapZone(at: CGPoint(x: 139, y: 30), in: screen))
        XCTAssertEqual(TilingGeometry.snapZone(at: CGPoint(x: 140, y: 0), in: screen), .left)
        XCTAssertEqual(TilingGeometry.snapZone(at: CGPoint(x: 379, y: 239), in: screen), .left)
        XCTAssertNil(TilingGeometry.snapZone(at: CGPoint(x: 380, y: 120), in: screen))
        XCTAssertNil(TilingGeometry.snapZone(at: CGPoint(x: 200, y: 240), in: screen))
        XCTAssertNil(TilingGeometry.snapZone(at: CGPoint(x: 300, y: 400), in: screen))
    }

    func testRightZoneIs60PixelsAndTopZoneIs30Pixels() {
        XCTAssertEqual(TilingGeometry.snapZone(at: CGPoint(x: 600, y: 871), in: screen), .top)
        XCTAssertNil(TilingGeometry.snapZone(at: CGPoint(x: 600, y: 870), in: screen))
        XCTAssertEqual(TilingGeometry.snapZone(at: CGPoint(x: 1141, y: 400), in: screen), .right)
        XCTAssertNil(TilingGeometry.snapZone(at: CGPoint(x: 1140, y: 400), in: screen))
    }

    func testTopZoneTakesPriorityAtCornersAndUsesFullscreen() {
        XCTAssertEqual(TilingGeometry.snapZone(at: CGPoint(x: 1, y: 899), in: screen), .top)
        XCTAssertEqual(TilingGeometry.arrange(existing: [], inserting: 7, in: .top), [LayoutSlot(windowID: 7, start: 0, end: 6)])
    }

    func testZonesSupportTranslatedScreensAndTopWinsAtBothCorners() {
        let translated = CGRect(x: -1200, y: 200, width: 1200, height: 900)
        XCTAssertEqual(TilingGeometry.snapZone(at: CGPoint(x: -1199, y: 1099), in: translated), .top)
        XCTAssertEqual(TilingGeometry.snapZone(at: CGPoint(x: -1, y: 1099), in: translated), .top)
        XCTAssertEqual(TilingGeometry.snapZone(at: CGPoint(x: -1060, y: 200), in: translated), .left)
    }

    func testOneTwoAndThreeWindowLayouts() {
        let one = TilingGeometry.arrange(existing: [], inserting: 1, in: .left)
        XCTAssertEqual(one, [LayoutSlot(windowID: 1, start: 0, end: 3)])
        let two = TilingGeometry.arrange(existing: one, inserting: 2, in: .right)
        XCTAssertEqual(two, [LayoutSlot(windowID: 1, start: 0, end: 3), LayoutSlot(windowID: 2, start: 3, end: 6)])
        let three = TilingGeometry.arrange(existing: two, inserting: 3, in: .right)
        XCTAssertEqual(three, [LayoutSlot(windowID: 1, start: 0, end: 2), LayoutSlot(windowID: 2, start: 2, end: 4), LayoutSlot(windowID: 3, start: 4, end: 6)])
    }

    func testFirstWindowCanOccupyRightHalf() {
        XCTAssertEqual(TilingGeometry.arrange(existing: [], inserting: 1, in: .right),
                       [LayoutSlot(windowID: 1, start: 3, end: 6)])
    }

    func testArrangeSortsInputAndReinsertingDoesNotDuplicateWindow() {
        let unordered = [LayoutSlot(windowID: 2, start: 3, end: 6), LayoutSlot(windowID: 1, start: 0, end: 3)]
        let updated = TilingGeometry.arrange(existing: unordered, inserting: 1, in: .right)
        XCTAssertEqual(updated, [LayoutSlot(windowID: 2, start: 0, end: 3), LayoutSlot(windowID: 1, start: 3, end: 6)])
        XCTAssertEqual(updated.filter { $0.windowID == 1 }.count, 1)
    }

    func testArrangeSafelyCapsMalformedOversizedInput() {
        let oversized = (0..<5).map { LayoutSlot(windowID: UInt32($0), start: $0, end: $0 + 1) }
        let updated = TilingGeometry.arrange(existing: oversized, inserting: 9, in: .right)
        XCTAssertEqual(updated.count, 3)
        XCTAssertEqual(updated.map(\.windowID), [0, 1, 9])
    }

    func testFourthWindowReplacesOnlyEdgeWindow() {
        let existing = [LayoutSlot(windowID: 1, start: 0, end: 2), LayoutSlot(windowID: 2, start: 2, end: 4), LayoutSlot(windowID: 3, start: 4, end: 6)]
        XCTAssertEqual(TilingGeometry.arrange(existing: existing, inserting: 4, in: .left).map(\.windowID), [4, 2, 3])
        XCTAssertEqual(TilingGeometry.arrange(existing: existing, inserting: 4, in: .right).map(\.windowID), [1, 2, 4])
        XCTAssertEqual(TilingGeometry.arrange(existing: existing, inserting: 4, in: .left), [
            LayoutSlot(windowID: 4, start: 0, end: 2), LayoutSlot(windowID: 2, start: 2, end: 4),
            LayoutSlot(windowID: 3, start: 4, end: 6)
        ])
    }

    func testWindowCanBeInsertedAtEveryPositionAroundTwoWindows() {
        let existing = [
            LayoutSlot(windowID: 1, start: 0, end: 3),
            LayoutSlot(windowID: 2, start: 3, end: 6)
        ]
        XCTAssertEqual(TilingGeometry.arrange(existing: existing, inserting: 3, at: 0).map(\.windowID), [3, 1, 2])
        XCTAssertEqual(TilingGeometry.arrange(existing: existing, inserting: 3, at: 1).map(\.windowID), [1, 3, 2])
        XCTAssertEqual(TilingGeometry.arrange(existing: existing, inserting: 3, at: 2).map(\.windowID), [1, 2, 3])
    }

    func testInsertingBetweenTwoWindowsRedistributesAllThreeIntoThirds() {
        let existing = [
            LayoutSlot(windowID: 1, start: 0, end: 3),
            LayoutSlot(windowID: 2, start: 3, end: 6)
        ]
        XCTAssertEqual(TilingGeometry.arrange(existing: existing, inserting: 3, at: 1), [
            LayoutSlot(windowID: 1, start: 0, end: 2),
            LayoutSlot(windowID: 3, start: 2, end: 4),
            LayoutSlot(windowID: 2, start: 4, end: 6)
        ])
    }

    func testReinsertingAnExistingWindowAdjustsItsOriginalIndex() {
        let existing = [
            LayoutSlot(windowID: 1, start: 0, end: 2),
            LayoutSlot(windowID: 2, start: 2, end: 4),
            LayoutSlot(windowID: 3, start: 4, end: 6)
        ]
        XCTAssertEqual(TilingGeometry.arrange(existing: existing, inserting: 3, at: 1).map(\.windowID), [1, 3, 2])
        XCTAssertEqual(TilingGeometry.arrange(existing: existing, inserting: 1, at: 2).map(\.windowID), [2, 1, 3])
    }

    func testInsertionTargetCoversOnlyTheStripBetweenWindows() {
        let frames = [
            CGRect(x: 15, y: 15, width: 577.5, height: 870),
            CGRect(x: 607.5, y: 15, width: 577.5, height: 870)
        ]
        let target = TilingGeometry.insertionTarget(at: CGPoint(x: 600, y: 400), orderedFrames: frames)
        XCTAssertEqual(target?.index, 1)
        XCTAssertEqual(target?.indicatorFrame, CGRect(x: 596, y: 15, width: 8, height: 870))
        XCTAssertNil(TilingGeometry.insertionTarget(at: CGPoint(x: 569, y: 400), orderedFrames: frames))
        XCTAssertNil(TilingGeometry.insertionTarget(at: CGPoint(x: 600, y: 900), orderedFrames: frames))
    }

    func testInsertionTargetSelectsTheCorrectDividerInThreeWindowLayout() {
        let frames = [0, 2, 4].map {
            TilingGeometry.frame(for: LayoutSlot(windowID: UInt32($0), start: $0, end: $0 + 2), in: screen)
        }
        XCTAssertEqual(TilingGeometry.insertionTarget(
            at: CGPoint(x: 400, y: 450), orderedFrames: frames
        )?.index, 1)
        XCTAssertEqual(TilingGeometry.insertionTarget(
            at: CGPoint(x: 800, y: 450), orderedFrames: frames
        )?.index, 2)
    }

    func testReplacementTargetUsesTopQuarterAndHighlightsExactSlotFrame() {
        let slots = [
            LayoutSlot(windowID: 1, start: 0, end: 3),
            LayoutSlot(windowID: 2, start: 3, end: 6)
        ]
        let rightFrame = TilingGeometry.frame(for: slots[1], in: screen)
        let target = TilingGeometry.replacementTarget(
            at: CGPoint(x: rightFrame.midX, y: rightFrame.maxY - 20),
            slots: slots,
            visibleFrame: screen
        )
        XCTAssertEqual(target, LayoutReplacementTarget(windowID: 2, frame: rightFrame))
        XCTAssertNil(TilingGeometry.replacementTarget(
            at: CGPoint(x: rightFrame.midX, y: rightFrame.midY),
            slots: slots,
            visibleFrame: screen
        ))
    }

    func testReplacingWindowPreservesExactSlotAndOtherRelationships() {
        let existing = [
            LayoutSlot(windowID: 1, start: 0, end: 2),
            LayoutSlot(windowID: 2, start: 2, end: 4),
            LayoutSlot(windowID: 3, start: 4, end: 6)
        ]
        XCTAssertEqual(TilingGeometry.replacing(existing: existing, window: 2, with: 9), [
            LayoutSlot(windowID: 1, start: 0, end: 2),
            LayoutSlot(windowID: 9, start: 2, end: 4),
            LayoutSlot(windowID: 3, start: 4, end: 6)
        ])
        XCTAssertEqual(TilingGeometry.replacing(existing: existing, window: 99, with: 9), existing)
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

    func testThirdsOnTranslatedFractionalScreenPreserveMarginsAndGaps() {
        let visible = CGRect(x: -1000, y: 50, width: 1000.5, height: 700)
        let frames = [0, 2, 4].map {
            TilingGeometry.frame(for: LayoutSlot(windowID: UInt32($0), start: $0, end: $0 + 2), in: visible)
        }
        XCTAssertEqual(frames[0].minX, visible.minX + 15)
        XCTAssertEqual(frames[2].maxX, visible.maxX - 15, accuracy: 0.0001)
        XCTAssertEqual(frames[1].minX - frames[0].maxX, 15, accuracy: 0.0001)
        XCTAssertEqual(frames[2].minX - frames[1].maxX, 15, accuracy: 0.0001)
    }

    func testFullScreenSlotUsesMarginsOnEveryEdge() {
        let frame = TilingGeometry.frame(for: LayoutSlot(windowID: 1, start: 0, end: 6), in: screen)
        XCTAssertEqual(frame, CGRect(x: 15, y: 15, width: 1170, height: 870))
    }

    func testPreviewRangesMatchFutureDrop() {
        XCTAssertEqual(TilingGeometry.previewRange(existingCount: 0, zone: .left), 0...0.5)
        XCTAssertEqual(TilingGeometry.previewRange(existingCount: 1, zone: .right), 0.5...1)
        XCTAssertEqual(TilingGeometry.previewRange(existingCount: 2, zone: .right), (2.0 / 3.0)...1)
        XCTAssertEqual(TilingGeometry.previewRange(existingCount: 2, zone: .top), 0...1)
    }

    func testPreviewRangeClampsUnusualCounts() {
        XCTAssertEqual(TilingGeometry.previewRange(existingCount: -10, zone: .left), 0...0.5)
        XCTAssertEqual(TilingGeometry.previewRange(existingCount: 100, zone: .left), 0...(1.0 / 3.0))
        XCTAssertEqual(TilingGeometry.previewRange(existingCount: 100, zone: .right), (2.0 / 3.0)...1)
    }

    func testHapticFiresOnEnterExitAndZoneChangeOnly() {
        XCTAssertTrue(TilingGeometry.shouldHaptic(from: nil, to: .left))
        XCTAssertTrue(TilingGeometry.shouldHaptic(from: .left, to: nil))
        XCTAssertTrue(TilingGeometry.shouldHaptic(from: .left, to: .top))
        XCTAssertFalse(TilingGeometry.shouldHaptic(from: nil, to: nil))
        XCTAssertFalse(TilingGeometry.shouldHaptic(from: .right, to: .right))
        XCTAssertTrue(TilingGeometry.shouldHaptic(from: .left, to: .right))
        XCTAssertTrue(TilingGeometry.shouldHaptic(from: .top, to: .left))
    }

    func testMenuBarAndInteractivePanelsAreIgnoredButClickThroughOverlayIsNot() {
        let visible = CGRect(x: 0, y: 0, width: 1200, height: 875)
        XCTAssertTrue(TilingGeometry.shouldIgnoreMouseDown(at: CGPoint(x: 1000, y: 890), screenVisibleFrame: visible, overInteractiveTilesWindow: false))
        XCTAssertTrue(TilingGeometry.shouldIgnoreMouseDown(at: CGPoint(x: 500, y: 500), screenVisibleFrame: visible, overInteractiveTilesWindow: true))
        XCTAssertFalse(TilingGeometry.shouldIgnoreMouseDown(at: CGPoint(x: 500, y: 500), screenVisibleFrame: visible, overInteractiveTilesWindow: false))
        XCTAssertTrue(TilingGeometry.shouldIgnoreMouseDown(at: CGPoint(x: 500, y: visible.maxY), screenVisibleFrame: visible, overInteractiveTilesWindow: false))
        XCTAssertFalse(TilingGeometry.shouldIgnoreMouseDown(at: CGPoint(x: 500, y: visible.minY - 1), screenVisibleFrame: visible, overInteractiveTilesWindow: false))
    }

    func testStageManagerStripIgnoresTheEntireMouseSequence() {
        let visible = CGRect(x: -1200, y: 0, width: 1200, height: 875)
        XCTAssertTrue(TilingGeometry.shouldIgnoreMouseDown(
            at: CGPoint(x: -1061, y: 400), screenVisibleFrame: visible, overInteractiveTilesWindow: false
        ))
        XCTAssertFalse(TilingGeometry.shouldIgnoreMouseDown(
            at: CGPoint(x: -1060, y: 400), screenVisibleFrame: visible, overInteractiveTilesWindow: false
        ))
    }

    func testStageManagerThumbnailCentersAreExcludedOnTranslatedScreens() {
        let translated = CGRect(x: -1200, y: 0, width: 1200, height: 900)
        XCTAssertTrue(TilingGeometry.isCenteredInStageManagerStrip(
            windowFrame: CGRect(x: -1190, y: 300, width: 180, height: 120), screenFrame: translated
        ))
        XCTAssertFalse(TilingGeometry.isCenteredInStageManagerStrip(
            windowFrame: CGRect(x: -1060, y: 100, width: 600, height: 700), screenFrame: translated
        ))
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

    func testLinkedResizeClampsBothSidesToMinimumWidth() {
        let left = CGRect(x: 15, y: 20, width: 300, height: 500)
        let right = CGRect(x: 330, y: 20, width: 300, height: 500)
        let leftClamped = TilingGeometry.linkedFrames(left: left, right: right, divider: -100)
        XCTAssertEqual(leftClamped.left.width, 100)
        XCTAssertEqual(leftClamped.right.minX - leftClamped.left.maxX, 15)

        let rightClamped = TilingGeometry.linkedFrames(left: left, right: right, divider: 1000)
        XCTAssertEqual(rightClamped.right.width, 100)
        XCTAssertEqual(rightClamped.right.minX - rightClamped.left.maxX, 15)
    }

    func testLinkedResizePreservesOuterEdgesAndVerticalGeometry() {
        let left = CGRect(x: -500, y: 40, width: 200, height: 600)
        let right = CGRect(x: -285, y: 40, width: 300, height: 600)
        let frames = TilingGeometry.linkedFrames(left: left, right: right, divider: -200, minimumWidth: 120)
        XCTAssertEqual(frames.left.minX, left.minX)
        XCTAssertEqual(frames.right.maxX, right.maxX)
        XCTAssertEqual(frames.left.minY, left.minY)
        XCTAssertEqual(frames.right.height, right.height)
        XCTAssertGreaterThanOrEqual(frames.left.width, 120)
        XCTAssertGreaterThanOrEqual(frames.right.width, 120)
    }
}

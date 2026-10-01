import CoreGraphics
import XCTest
@testable import TilesCore

final class MouseSequenceGateTests: XCTestCase {
    func testNormalSequenceEmitsOneDownDragsAndOneUp() {
        var gate = MouseSequenceGate()
        XCTAssertEqual(gate.update(isDown: true), .down)
        XCTAssertEqual(gate.update(isDown: true), .dragged)
        XCTAssertEqual(gate.update(isDown: true), .dragged)
        XCTAssertEqual(gate.update(isDown: false), .up)
        XCTAssertNil(gate.update(isDown: false))
    }

    func testIgnoredPressSuppressesEntireSequenceAndNextPressWorks() {
        var gate = MouseSequenceGate()
        XCTAssertNil(gate.update(isDown: true, ignoreNewPress: true))
        XCTAssertNil(gate.update(isDown: true))
        XCTAssertNil(gate.update(isDown: false))
        XCTAssertEqual(gate.update(isDown: true), .down)
    }

    func testIgnoreInputOnlyAppliesAtStartOfPress() {
        var gate = MouseSequenceGate()
        XCTAssertEqual(gate.update(isDown: true), .down)
        XCTAssertEqual(gate.update(isDown: true, ignoreNewPress: true), .dragged)
        XCTAssertEqual(gate.update(isDown: false), .up)
    }

    func testIdleReleaseDoesNothing() {
        var gate = MouseSequenceGate()
        XCTAssertNil(gate.update(isDown: false))
        XCTAssertFalse(gate.isButtonDown)
    }
}

final class TilingStateTests: XCTestCase {
    typealias Slot = PlacedSlot<Int>

    func testSnapMovesWindowFromOldScreenAndPreservesUnrelatedScreens() {
        let slots = [
            Slot(windowID: 1, start: 0, end: 3, screenID: 1),
            Slot(windowID: 2, start: 3, end: 6, screenID: 1),
            Slot(windowID: 3, start: 0, end: 6, screenID: 2)
        ]

        let updated = TilingState.updatingForSnap(slots, inserting: 3, on: 1, in: .left)

        XCTAssertEqual(updated.map(\.windowID), [3, 1, 2])
        XCTAssertTrue(updated.allSatisfy { $0.screenID == 1 })
        XCTAssertEqual(updated.filter { $0.windowID == 3 }.count, 1)
    }

    func testTopSnapClearsOnlyTargetScreen() {
        let slots = [
            Slot(windowID: 1, start: 0, end: 3, screenID: 1),
            Slot(windowID: 2, start: 3, end: 6, screenID: 1),
            Slot(windowID: 9, start: 0, end: 6, screenID: 2)
        ]

        let updated = TilingState.updatingForSnap(slots, inserting: 3, on: 1, in: .top)

        XCTAssertEqual(updated, [
            Slot(windowID: 9, start: 0, end: 6, screenID: 2),
            Slot(windowID: 3, start: 0, end: 6, screenID: 1)
        ])
    }

    func testPaletteRemovesStrictOverlapsButPreservesAbuttingSlots() {
        let slots = [
            Slot(windowID: 1, start: 0, end: 2, screenID: 1),
            Slot(windowID: 2, start: 2, end: 4, screenID: 1),
            Slot(windowID: 3, start: 4, end: 6, screenID: 1)
        ]

        let updated = TilingState.updatingForPalette(slots, placing: 4, start: 2, end: 4, on: 1)

        XCTAssertEqual(updated, [slots[0], slots[2], Slot(windowID: 4, start: 2, end: 4, screenID: 1)])
    }

    func testPaletteMovesWindowGloballyAndPreservesOtherScreenSlots() {
        let slots = [
            Slot(windowID: 1, start: 0, end: 3, screenID: 2),
            Slot(windowID: 2, start: 0, end: 3, screenID: 2),
            Slot(windowID: 3, start: 0, end: 3, screenID: 1)
        ]

        let updated = TilingState.updatingForPalette(slots, placing: 1, start: 3, end: 6, on: 1)

        XCTAssertEqual(updated, [slots[1], slots[2], Slot(windowID: 1, start: 3, end: 6, screenID: 1)])
    }

    func testPaletteDoesNotReflowSurvivingSlots() {
        let slot = Slot(windowID: 1, start: 0, end: 2, screenID: 1)
        let updated = TilingState.updatingForPalette([slot], placing: 2, start: 4, end: 6, on: 1)
        XCTAssertEqual(updated.first, slot)
    }
}

final class StageGroupStoreTests: XCTestCase {
    private let a = WindowIdentity(windowID: 1, ownerPID: 10)
    private let b = WindowIdentity(windowID: 2, ownerPID: 20)
    private let c = WindowIdentity(windowID: 3, ownerPID: 30)
    private let d = WindowIdentity(windowID: 4, ownerPID: 40)

    func testGroupActivatesOnlyAfterStableSamples() throws {
        var store = StageGroupStore<Int>()
        XCTAssertEqual(store.observe(screenID: 1, visibleWindows: [a, b]), .transitioning)
        let context = try active(store.observe(screenID: 1, visibleWindows: [a, b]))
        XCTAssertEqual(context.visibleWindows, [a, b])
    }

    func testSetChangeRevokesOldContextImmediately() throws {
        var store = StageGroupStore<Int>(requiredStableSamples: 1)
        let old = try active(store.observe(screenID: 1, visibleWindows: [a, b]))
        store.setSlots([LayoutSlot(windowID: 1, start: 0, end: 3)], in: old)
        let current = try active(store.observe(screenID: 1, visibleWindows: [c, d]))
        XCTAssertFalse(store.isCurrent(old))
        XCTAssertFalse(store.permits(window: a, in: old))
        XCTAssertTrue(store.slots(in: old).isEmpty)
        XCTAssertTrue(store.isCurrent(current))
    }

    func testSwitchingAwayAndBackRestoresGroupIDAndSlots() throws {
        var store = StageGroupStore<Int>(requiredStableSamples: 1)
        let first = try active(store.observe(screenID: 1, visibleWindows: [a, b]))
        store.setSlots([LayoutSlot(windowID: 1, start: 0, end: 3)], in: first)
        _ = store.observe(screenID: 1, visibleWindows: [c, d])
        let restored = try active(store.observe(screenID: 1, visibleWindows: [a, b]))
        XCTAssertEqual(restored.key.groupID, first.key.groupID)
        XCTAssertEqual(store.slots(in: restored), [LayoutSlot(windowID: 1, start: 0, end: 3)])
    }

    func testReturningGroupRestoresLayoutWhenUnmanagedWindowSignatureChanged() throws {
        let extras = (5...9).map { WindowIdentity(windowID: UInt32($0), ownerPID: Int32($0 * 10)) }
        let newExtras = (10...13).map { WindowIdentity(windowID: UInt32($0), ownerPID: Int32($0 * 10)) }
        var store = StageGroupStore<Int>(requiredStableSamples: 1)
        let first = try active(store.observe(screenID: 1, visibleWindows: Set([a, b] + extras)))
        store.setSlots([
            LayoutSlot(windowID: a.windowID, start: 0, end: 3),
            LayoutSlot(windowID: b.windowID, start: 3, end: 6)
        ], in: first)
        _ = store.observe(screenID: 1, visibleWindows: [c, d])

        let restored = try active(store.observe(screenID: 1, visibleWindows: Set([a, b] + newExtras)))
        XCTAssertEqual(restored.key.groupID, first.key.groupID)
        XCTAssertEqual(store.slots(in: restored).map(\.windowID), [a.windowID, b.windowID])
    }

    func testLayoutBasedRestoreRequiresAllSlottedWindows() throws {
        var store = StageGroupStore<Int>(requiredStableSamples: 1)
        let first = try active(store.observe(screenID: 1, visibleWindows: [a, b]))
        store.setSlots([
            LayoutSlot(windowID: a.windowID, start: 0, end: 3),
            LayoutSlot(windowID: b.windowID, start: 3, end: 6)
        ], in: first)
        let partial = try active(store.observe(screenID: 1, visibleWindows: [a, c, d]))
        XCTAssertNotEqual(partial.key.groupID, first.key.groupID)
        XCTAssertTrue(store.slots(in: partial).isEmpty)
    }

    func testLayoutBasedRestoreRejectsReusedWindowIDFromAnotherProcess() throws {
        var store = StageGroupStore<Int>(requiredStableSamples: 1)
        let first = try active(store.observe(screenID: 1, visibleWindows: [a, b]))
        store.setSlots([LayoutSlot(windowID: a.windowID, start: 0, end: 6)], in: first)
        let reused = WindowIdentity(windowID: a.windowID, ownerPID: 999)
        let current = try active(store.observe(screenID: 1, visibleWindows: [reused, c, d]))
        XCTAssertNotEqual(current.key.groupID, first.key.groupID)
        XCTAssertTrue(store.slots(in: current).isEmpty)
    }

    func testGroupsOnSameScreenKeepIndependentSlots() throws {
        var store = StageGroupStore<Int>(requiredStableSamples: 1)
        let first = try active(store.observe(screenID: 1, visibleWindows: [a, b]))
        store.setSlots([LayoutSlot(windowID: 1, start: 0, end: 3)], in: first)
        let second = try active(store.observe(screenID: 1, visibleWindows: [c, d]))
        store.setSlots([LayoutSlot(windowID: 3, start: 3, end: 6)], in: second)
        XCTAssertNotEqual(first.key.groupID, second.key.groupID)
        XCTAssertEqual(store.storedGroupCount, 2)
        let restored = try active(store.observe(screenID: 1, visibleWindows: [a, b]))
        XCTAssertEqual(store.slots(in: restored).map(\.windowID), [1])
    }

    func testAddingWindowConservativelyMatchesExistingGroup() throws {
        var store = StageGroupStore<Int>(requiredStableSamples: 1)
        let first = try active(store.observe(screenID: 1, visibleWindows: [a, b]))
        let expanded = try active(store.observe(screenID: 1, visibleWindows: [a, b, c]))
        XCTAssertEqual(expanded.key.groupID, first.key.groupID)
    }

    func testAmbiguousUnionDoesNotMergeTwoGroups() throws {
        var store = StageGroupStore<Int>(requiredStableSamples: 1)
        let first = try active(store.observe(screenID: 1, visibleWindows: [a, b]))
        let second = try active(store.observe(screenID: 1, visibleWindows: [c, d]))
        let union = try active(store.observe(screenID: 1, visibleWindows: [a, b, c, d]))
        XCTAssertNotEqual(union.key.groupID, first.key.groupID)
        XCTAssertNotEqual(union.key.groupID, second.key.groupID)
    }

    func testReusedWindowIDWithDifferentPIDDoesNotMatch() throws {
        var store = StageGroupStore<Int>(requiredStableSamples: 1)
        let first = try active(store.observe(screenID: 1, visibleWindows: [a]))
        let reused = WindowIdentity(windowID: a.windowID, ownerPID: 999)
        let second = try active(store.observe(screenID: 1, visibleWindows: [reused]))
        XCTAssertNotEqual(first.key.groupID, second.key.groupID)
    }

    func testScreensMaintainIndependentActiveGroups() throws {
        var store = StageGroupStore<Int>(requiredStableSamples: 1)
        let first = try active(store.observe(screenID: 1, visibleWindows: [a]))
        let second = try active(store.observe(screenID: 2, visibleWindows: [b]))
        XCTAssertEqual(store.activeContext(on: 1), first)
        XCTAssertEqual(store.activeContext(on: 2), second)
    }

    func testEmptyVisibilityDeactivatesButPreservesStoredGroup() throws {
        var store = StageGroupStore<Int>(requiredStableSamples: 1)
        let context = try active(store.observe(screenID: 1, visibleWindows: [a]))
        store.setSlots([LayoutSlot(windowID: 1, start: 0, end: 6)], in: context)
        XCTAssertEqual(store.observe(screenID: 1, visibleWindows: []), .none)
        XCTAssertNil(store.activeContext(on: 1))
        XCTAssertEqual(store.storedGroupCount, 1)
    }

    private func active(_ observation: StageGroupObservation<Int>) throws -> StageGroupContext<Int> {
        guard case let .active(context) = observation else {
            throw NSError(domain: "StageGroupStoreTests", code: 1)
        }
        return context
    }
}

final class StageGroupLayoutTests: XCTestCase {
    private let slots = [
        LayoutSlot(windowID: 1, start: 0, end: 2),
        LayoutSlot(windowID: 2, start: 2, end: 4),
        LayoutSlot(windowID: 3, start: 4, end: 6)
    ]

    func testAssignmentsExcludeOffStageWindows() {
        let assignments = StageGroupLayout.assignments(
            slots: slots, visibleWindowIDs: [1, 3], visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 900)
        )
        XCTAssertEqual(assignments.map(\.windowID), [1, 3])
    }

    func testNoVisibleWindowsProduceNoAssignments() {
        XCTAssertTrue(StageGroupLayout.assignments(
            slots: slots, visibleWindowIDs: [], visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 900)
        ).isEmpty)
    }

    func testAdjacentPairsRequireBothWindowsToBeVisible() {
        XCTAssertEqual(StageGroupLayout.adjacentPairs(slots: slots, visibleWindowIDs: [1, 2]).map { [$0.left, $0.right] }, [[1, 2]])
        XCTAssertTrue(StageGroupLayout.adjacentPairs(slots: slots, visibleWindowIDs: [1, 3]).isEmpty)
    }
}

final class VisibleWindowMatchingTests: XCTestCase {
    private let expected = CGRect(x: 100, y: 100, width: 800, height: 600)

    func testExactWindowNumberTakesPriority() {
        let candidates = [
            VisibleWindowCandidate(windowID: nil, frame: expected, wasPreviouslyMatched: true),
            VisibleWindowCandidate(windowID: 42, frame: expected, wasPreviouslyMatched: false)
        ]
        XCTAssertEqual(VisibleWindowMatching.candidateIndex(
            for: 42, expectedFrame: expected, candidates: candidates
        ), 1)
    }

    func testPreviousUnnumberedWindowSurvivesFrameLagDuringDrag() {
        let movingFrame = expected.offsetBy(dx: 500, dy: 0)
        let candidates = [
            VisibleWindowCandidate(windowID: nil, frame: movingFrame, wasPreviouslyMatched: true)
        ]
        XCTAssertEqual(VisibleWindowMatching.candidateIndex(
            for: 42,
            expectedFrame: expected,
            candidates: candidates,
            allowPreviousFrameMismatch: true
        ), 0)
        XCTAssertNil(VisibleWindowMatching.candidateIndex(
            for: 42, expectedFrame: expected, candidates: candidates
        ))
    }

    func testExactWindowNumberDoesNotDependOnDecorationFrameAgreement() {
        let thumbnailFrame = CGRect(x: 20, y: 300, width: 180, height: 120)
        let candidates = [
            VisibleWindowCandidate(windowID: 42, frame: expected, wasPreviouslyMatched: true)
        ]
        XCTAssertEqual(VisibleWindowMatching.candidateIndex(
            for: 42, expectedFrame: thumbnailFrame, candidates: candidates
        ), 0)
    }

    func testNormalWindowServerDecorationDifferencesStillMatch() {
        let decoratedFrame = CGRect(x: 78, y: 84, width: 836, height: 632)
        let candidates = [
            VisibleWindowCandidate(windowID: 42, frame: expected, wasPreviouslyMatched: false)
        ]
        XCTAssertEqual(VisibleWindowMatching.candidateIndex(
            for: 42, expectedFrame: decoratedFrame, candidates: candidates
        ), 0)
        XCTAssertTrue(VisibleWindowMatching.framesApproximatelyMatch(expected, decoratedFrame))
    }

    func testDifferentExplicitWindowNumberCannotUsePreviousMatch() {
        let candidates = [
            VisibleWindowCandidate(windowID: 99, frame: expected, wasPreviouslyMatched: true)
        ]
        XCTAssertNil(VisibleWindowMatching.candidateIndex(
            for: 42, expectedFrame: expected, candidates: candidates
        ))
    }

    func testClosestFrameSelectsFocusedWindowWhenWindowNumberIsUnavailable() {
        let candidates = [
            CGRect(x: 20, y: 300, width: 180, height: 120),
            CGRect(x: 82, y: 76, width: 834, height: 638),
            CGRect(x: 900, y: 100, width: 500, height: 500)
        ]
        XCTAssertEqual(VisibleWindowMatching.closestFrameIndex(to: expected, candidates: candidates), 1)
        XCTAssertNil(VisibleWindowMatching.closestFrameIndex(to: expected, candidates: []))
    }

    func testUnnumberedWindowCanInitiallyMatchByFrame() {
        let candidates = [
            VisibleWindowCandidate(windowID: nil, frame: expected.offsetBy(dx: 5, dy: -5), wasPreviouslyMatched: false)
        ]
        XCTAssertEqual(VisibleWindowMatching.candidateIndex(
            for: 42, expectedFrame: expected, candidates: candidates
        ), 0)
    }
}

final class ScreenGeometryTests: XCTestCase {
    private let frames = [
        CGRect(x: -1200, y: 0, width: 1200, height: 900),
        CGRect(x: 0, y: 0, width: 1200, height: 900)
    ]

    func testContainmentSupportsNegativeAndTranslatedScreens() {
        XCTAssertEqual(ScreenGeometry.index(containing: CGPoint(x: -600, y: 400), frames: frames), 0)
        XCTAssertEqual(ScreenGeometry.index(containing: CGPoint(x: 600, y: 400), frames: frames), 1)
    }

    func testContainmentUsesTwoPointTolerance() {
        XCTAssertEqual(ScreenGeometry.index(containing: CGPoint(x: -1201.9, y: 400), frames: frames), 0)
        XCTAssertNil(ScreenGeometry.index(containing: CGPoint(x: -1202.1, y: 400), frames: frames))
    }

    func testOverlappingExpandedRegionsChooseFirstScreen() {
        XCTAssertEqual(ScreenGeometry.index(containing: CGPoint(x: 1, y: 400), frames: frames), 0)
    }

    func testWindowSelectionUsesFirstIntersectionAndFallback() {
        let crossing = CGRect(x: -10, y: 100, width: 100, height: 100)
        XCTAssertEqual(ScreenGeometry.index(intersecting: crossing, frames: frames, fallbackIndex: 1), 0)
        XCTAssertEqual(ScreenGeometry.index(intersecting: CGRect(x: 5000, y: 0, width: 10, height: 10), frames: frames, fallbackIndex: 1), 1)
    }
}

final class AutoTileGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)

    func testOneWindowUsesFullScreenLayout() {
        let windows = [VisibleWindowGeometry(windowID: 1, frame: CGRect(x: 400, y: 200, width: 300, height: 400))]
        XCTAssertEqual(AutoTileGeometry.placements(for: windows, screenFrames: [screen]), [
            PlacedSlot(windowID: 1, start: 0, end: 6, screenID: 0)
        ])
    }

    func testTwoWindowsAreOrderedByGeometricCenter() {
        let windows = [
            VisibleWindowGeometry(windowID: 2, frame: CGRect(x: 800, y: 100, width: 300, height: 500)),
            VisibleWindowGeometry(windowID: 1, frame: CGRect(x: 100, y: 100, width: 300, height: 500))
        ]
        XCTAssertEqual(AutoTileGeometry.placements(for: windows, screenFrames: [screen]), [
            PlacedSlot(windowID: 1, start: 0, end: 3, screenID: 0),
            PlacedSlot(windowID: 2, start: 3, end: 6, screenID: 0)
        ])
    }

    func testThreeWindowsUseThirds() {
        let windows = [100, 500, 900].enumerated().map {
            VisibleWindowGeometry(windowID: UInt32($0.offset + 1),
                                  frame: CGRect(x: $0.element, y: 100, width: 200, height: 400))
        }
        let placements = AutoTileGeometry.placements(for: windows, screenFrames: [screen])
        XCTAssertEqual(placements.map(\.start), [0, 2, 4])
        XCTAssertEqual(placements.map(\.end), [2, 4, 6])
    }

    func testMoreThanThreeKeepsFrontmostInputWindows() {
        let windows = [
            VisibleWindowGeometry(windowID: 1, frame: CGRect(x: 900, y: 100, width: 100, height: 400)),
            VisibleWindowGeometry(windowID: 2, frame: CGRect(x: 500, y: 100, width: 100, height: 400)),
            VisibleWindowGeometry(windowID: 3, frame: CGRect(x: 100, y: 100, width: 100, height: 400)),
            VisibleWindowGeometry(windowID: 4, frame: CGRect(x: 300, y: 100, width: 100, height: 400))
        ]
        let placements = AutoTileGeometry.placements(for: windows, screenFrames: [screen])
        XCTAssertEqual(placements.map(\.windowID), [3, 2, 1])
        XCTAssertFalse(placements.contains { $0.windowID == 4 })
    }

    func testWindowsAreAssignedIndependentlyByCenterOnEachScreen() {
        let screens = [CGRect(x: -1200, y: 0, width: 1200, height: 900), screen]
        let windows = [
            VisibleWindowGeometry(windowID: 1, frame: CGRect(x: -900, y: 100, width: 300, height: 400)),
            VisibleWindowGeometry(windowID: 2, frame: CGRect(x: 400, y: 100, width: 300, height: 400))
        ]
        XCTAssertEqual(AutoTileGeometry.placements(for: windows, screenFrames: screens), [
            PlacedSlot(windowID: 1, start: 0, end: 6, screenID: 0),
            PlacedSlot(windowID: 2, start: 0, end: 6, screenID: 1)
        ])
    }

    func testWindowCrossingDisplaysUsesTheScreenContainingItsCenter() {
        let screens = [CGRect(x: -1200, y: 0, width: 1200, height: 900), screen]
        let window = VisibleWindowGeometry(windowID: 1, frame: CGRect(x: -100, y: 100, width: 400, height: 400))
        XCTAssertEqual(AutoTileGeometry.placements(for: [window], screenFrames: screens).first?.screenID, 1)
    }

    func testZeroMaximumDisablesPlacement() {
        let window = VisibleWindowGeometry(windowID: 1, frame: screen)
        XCTAssertTrue(AutoTileGeometry.placements(for: [window], screenFrames: [screen], maximumWindowsPerScreen: 0).isEmpty)
    }
}

final class CoupledDragGeometryTests: XCTestCase {
    private let left = CGRect(x: 0, y: 20, width: 300, height: 600)
    private let right = CGRect(x: 315, y: 20, width: 300, height: 600)
    private let initialDivider: CGFloat = 307.5

    func testGrowingLeftShrinksRightBeforeGrowingLeft() throws {
        let plan = try XCTUnwrap(CoupledDragGeometry.plan(
            left: left, right: right, requestedDivider: 400, previousDivider: initialDivider,
            leftMinimumWidth: 100, rightMinimumWidth: 100
        ))
        XCTAssertEqual(plan.writeOrder, .rightThenLeft)
        XCTAssertEqual(plan.left.maxX, 392.5)
        XCTAssertEqual(plan.right.minX, 407.5)
        XCTAssertEqual(plan.right.minX - plan.left.maxX, 15)
    }

    func testGrowingRightShrinksLeftBeforeGrowingRight() throws {
        let plan = try XCTUnwrap(CoupledDragGeometry.plan(
            left: left, right: right, requestedDivider: 200, previousDivider: initialDivider,
            leftMinimumWidth: 100, rightMinimumWidth: 100
        ))
        XCTAssertEqual(plan.writeOrder, .leftThenRight)
        XCTAssertEqual(plan.left.maxX, 192.5)
        XCTAssertEqual(plan.right.minX, 207.5)
    }

    func testReportedMinimumWidthsClampBothDividerExtremes() throws {
        let farLeft = try XCTUnwrap(CoupledDragGeometry.plan(
            left: left, right: right, requestedDivider: -100, previousDivider: initialDivider,
            leftMinimumWidth: 140, rightMinimumWidth: 180
        ))
        XCTAssertEqual(farLeft.left.width, 140)

        let farRight = try XCTUnwrap(CoupledDragGeometry.plan(
            left: left, right: right, requestedDivider: 1000, previousDivider: initialDivider,
            leftMinimumWidth: 140, rightMinimumWidth: 180
        ))
        XCTAssertEqual(farRight.right.width, 180)
    }

    func testLegalRangeIncludesHalfGapAroundMinimumWidths() {
        XCTAssertEqual(CoupledDragGeometry.legalDividerRange(
            left: left, right: right, leftMinimumWidth: 100, rightMinimumWidth: 150
        ), 107.5...457.5)
    }

    func testImpossibleMinimumWidthsProduceNoPlan() {
        let narrowRight = CGRect(x: 115, y: 20, width: 85, height: 600)
        XCTAssertNil(CoupledDragGeometry.plan(
            left: CGRect(x: 0, y: 20, width: 100, height: 600), right: narrowRight,
            requestedDivider: 100, previousDivider: 100,
            leftMinimumWidth: 100, rightMinimumWidth: 100
        ))
    }

    func testAcceptedFramesNeedNoReleaseCorrection() {
        XCTAssertNil(CoupledDragGeometry.correctionDivider(
            desiredDivider: 400,
            actualLeft: CGRect(x: 0, y: 20, width: 392.5, height: 600),
            actualRight: CGRect(x: 407.5, y: 20, width: 207.5, height: 600),
            legalRange: 107.5...507.5
        ))
    }

    func testReleaseCorrectionUsesTheWindowThatRejectedItsFrame() {
        let expectedRight = CGRect(x: 407.5, y: 20, width: 207.5, height: 600)
        XCTAssertEqual(CoupledDragGeometry.correctionDivider(
            desiredDivider: 400,
            actualLeft: CGRect(x: 0, y: 20, width: 350, height: 600),
            actualRight: expectedRight,
            legalRange: 107.5...507.5
        ), 357.5)

        let expectedLeft = CGRect(x: 0, y: 20, width: 392.5, height: 600)
        XCTAssertEqual(CoupledDragGeometry.correctionDivider(
            desiredDivider: 400,
            actualLeft: expectedLeft,
            actualRight: CGRect(x: 450, y: 20, width: 165, height: 600),
            legalRange: 107.5...507.5
        ), 442.5)
    }

    func testReleaseCorrectionAveragesTwoRejectedEdgesAndClampsToLegalRange() {
        XCTAssertEqual(CoupledDragGeometry.correctionDivider(
            desiredDivider: 400,
            actualLeft: CGRect(x: 0, y: 20, width: 0, height: 600),
            actualRight: CGRect(x: 700, y: 20, width: 100, height: 600),
            legalRange: 107.5...300
        ), 300)
    }
}

final class LinkedResizeGeometryTests: XCTestCase {
    private let expectedLeft = CGRect(x: 0, y: 10, width: 100, height: 500)
    private let expectedRight = CGRect(x: 115, y: 10, width: 100, height: 500)

    func testExactChangeThresholdIsIgnored() {
        let left = CGRect(x: 0, y: 10, width: 101.5, height: 500)
        XCTAssertNil(LinkedResizeGeometry.update(left: left, right: expectedRight,
                                                 expectedLeft: expectedLeft, expectedRight: expectedRight))
    }

    func testPositionOnlyMovementIsIgnored() {
        let left = CGRect(x: 2, y: 10, width: 100, height: 500)
        XCTAssertNil(LinkedResizeGeometry.update(left: left, right: expectedRight,
                                                 expectedLeft: expectedLeft, expectedRight: expectedRight))
    }

    func testLeftResizeMovesRightAndPreservesRightOuterEdge() {
        let left = CGRect(x: 0, y: 10, width: 110, height: 500)
        let wideRight = CGRect(x: 115, y: 10, width: 200, height: 500)
        let update = LinkedResizeGeometry.update(left: left, right: wideRight,
                                                 expectedLeft: expectedLeft, expectedRight: wideRight)
        XCTAssertEqual(update?.source, .left)
        XCTAssertEqual(update?.right.minX, 125)
        XCTAssertEqual(update?.right.maxX, wideRight.maxX)
    }

    func testRightResizeMovesLeftDividerAndPreservesLeftOrigin() {
        let right = CGRect(x: 125, y: 10, width: 90, height: 500)
        let update = LinkedResizeGeometry.update(left: expectedLeft, right: right,
                                                 expectedLeft: expectedLeft, expectedRight: expectedRight)
        XCTAssertEqual(update?.source, .right)
        XCTAssertEqual(update?.left.minX, expectedLeft.minX)
        XCTAssertEqual(update?.left.maxX, 110)
    }

    func testBothChangedGivesLeftResizePrecedence() {
        let left = CGRect(x: 0, y: 10, width: 105, height: 500)
        let right = CGRect(x: 120, y: 10, width: 95, height: 500)
        let update = LinkedResizeGeometry.update(left: left, right: right,
                                                 expectedLeft: expectedLeft, expectedRight: expectedRight)
        XCTAssertEqual(update?.source, .left)
    }

    func testLinkDistanceIncludesFortyButRejectsMore() {
        let leftAtLimit = CGRect(x: 0, y: 10, width: 75, height: 500)
        XCTAssertNotNil(LinkedResizeGeometry.update(left: leftAtLimit, right: expectedRight,
                                                    expectedLeft: expectedLeft, expectedRight: expectedRight))
        let leftOutside = CGRect(x: 0, y: 10, width: 74.9, height: 500)
        XCTAssertNil(LinkedResizeGeometry.update(left: leftOutside, right: expectedRight,
                                                 expectedLeft: expectedLeft, expectedRight: expectedRight))
    }
}

final class BoundaryGeometryTests: XCTestCase {
    func testDividerUsesActualWindowEdges() {
        let left = CGRect(x: 10, y: 0, width: 380, height: 500)
        let right = CGRect(x: 410, y: 0, width: 300, height: 500)
        XCTAssertEqual(BoundaryGeometry.dividerX(left: left, right: right), 400)
    }

    func testHitDistanceIsStrict() {
        XCTAssertTrue(BoundaryGeometry.isHit(pointX: 439.9, dividerX: 400))
        XCTAssertFalse(BoundaryGeometry.isHit(pointX: 440, dividerX: 400))
    }

    func testVerticalEligibilityIncludesInsetBoundaries() {
        let visible = CGRect(x: 0, y: 100, width: 1000, height: 700)
        XCTAssertTrue(BoundaryGeometry.isVerticallyEligible(y: 115, visibleFrame: visible))
        XCTAssertTrue(BoundaryGeometry.isVerticallyEligible(y: 785, visibleFrame: visible))
        XCTAssertFalse(BoundaryGeometry.isVerticallyEligible(y: 114.9, visibleFrame: visible))
        XCTAssertFalse(BoundaryGeometry.isVerticallyEligible(y: 785.1, visibleFrame: visible))
    }
}

final class PaletteGeometryTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 198, height: 126)

    func testLayoutsHaveExpectedOrderAndRanges() {
        XCTAssertEqual(PaletteGeometry.layouts, [
            PaletteLayout(start: 0, end: 3), PaletteLayout(start: 0, end: 6),
            PaletteLayout(start: 3, end: 6), PaletteLayout(start: 0, end: 2),
            PaletteLayout(start: 2, end: 4), PaletteLayout(start: 4, end: 6)
        ])
    }

    func testOriginCentersBelowButtonWhenUnconstrained() {
        let origin = PaletteGeometry.origin(
            below: CGRect(x: 500, y: 500, width: 20, height: 20),
            paletteSize: CGSize(width: 198, height: 126),
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 900)
        )
        XCTAssertEqual(origin, CGPoint(x: 411, y: 368))
    }

    func testOriginClampsToTranslatedScreenLeftRightAndBottom() {
        let visible = CGRect(x: 100, y: 50, width: 500, height: 400)
        let size = CGSize(width: 198, height: 126)
        XCTAssertEqual(PaletteGeometry.origin(below: CGRect(x: 90, y: 40, width: 10, height: 10), paletteSize: size, visibleFrame: visible), CGPoint(x: 108, y: 58))
        XCTAssertEqual(PaletteGeometry.origin(below: CGRect(x: 590, y: 400, width: 10, height: 10), paletteSize: size, visibleFrame: visible).x, 394)
    }

    func testHitTestingMapsAllSixCellCenters() {
        let grid = PaletteGeometry.grid(in: bounds)
        let cellWidth = grid.width / 3
        let cellHeight = grid.height / 2
        for index in 0..<6 {
            let column = index % 3
            let row = index / 3
            let point = CGPoint(x: grid.minX + (CGFloat(column) + 0.5) * cellWidth,
                                y: grid.minY + (CGFloat(1 - row) + 0.5) * cellHeight)
            XCTAssertEqual(PaletteGeometry.layoutIndex(at: point, in: bounds), index)
        }
    }

    func testHitTestingRejectsHeaderAndOutsideGrid() {
        XCTAssertNil(PaletteGeometry.layoutIndex(at: CGPoint(x: 50, y: 115), in: bounds))
        XCTAssertNil(PaletteGeometry.layoutIndex(at: CGPoint(x: 8, y: 20), in: bounds))
        XCTAssertNil(PaletteGeometry.layoutIndex(at: CGPoint(x: 50, y: 8), in: bounds))
    }

    func testSelectionRectUsesSixths() {
        let screen = CGRect(x: 20, y: 10, width: 120, height: 40)
        XCTAssertEqual(PaletteGeometry.selectedRect(for: PaletteLayout(start: 2, end: 4), in: screen),
                       CGRect(x: 60, y: 10, width: 40, height: 40))
    }
}

final class OverlayGeometryTests: XCTestCase {
    private let visibleFrame = CGRect(x: -1200, y: 50, width: 1200, height: 850)

    func testLayoutWidgetAppearsInsideTopRightOfVisibleFrame() {
        XCTAssertEqual(OverlayGeometry.layoutWidgetOrigin(
            panelSize: CGSize(width: 220, height: 92), visibleFrame: visibleFrame
        ), CGPoint(x: -235, y: 793))
    }

    func testLeftSnapPreviewMatchesFirstWindowLayout() {
        XCTAssertEqual(OverlayGeometry.snapPreviewFrame(
            existingCount: 0, zone: .left, visibleFrame: visibleFrame
        ), TilingGeometry.frame(for: LayoutSlot(windowID: 0, start: 0, end: 3), in: visibleFrame))
    }

    func testRightSnapPreviewMatchesThreeWindowLayout() {
        XCTAssertEqual(OverlayGeometry.snapPreviewFrame(
            existingCount: 2, zone: .right, visibleFrame: visibleFrame
        ), TilingGeometry.frame(for: LayoutSlot(windowID: 0, start: 4, end: 6), in: visibleFrame))
    }

    func testTopSnapPreviewUsesFullVisibleFrameWithMargins() {
        XCTAssertEqual(OverlayGeometry.snapPreviewFrame(
            existingCount: 2, zone: .top, visibleFrame: visibleFrame
        ), CGRect(x: -1185, y: 65, width: 1170, height: 820))
    }
}

final class CoordinateGeometryTests: XCTestCase {
    func testVerticalFlipPreservesHorizontalGeometryAndSize() {
        let frame = CGRect(x: -20, y: 100, width: 300, height: 200)
        XCTAssertEqual(CoordinateGeometry.flipVertically(frame, displayHeight: 1000),
                       CGRect(x: -20, y: 700, width: 300, height: 200))
    }

    func testVerticalFlipRoundTrips() {
        let frame = CGRect(x: 50, y: -100, width: 400, height: 250)
        let flipped = CoordinateGeometry.flipVertically(frame, displayHeight: 900)
        XCTAssertEqual(CoordinateGeometry.flipVertically(flipped, displayHeight: 900), frame)
    }
}

import CoreGraphics

public enum MousePhase: Equatable {
    case down
    case dragged
    case up
}

public struct MouseSequenceGate {
    public private(set) var isButtonDown = false
    private var ignoresCurrentSequence = false

    public init() {}

    public mutating func update(isDown: Bool, ignoreNewPress: Bool = false) -> MousePhase? {
        let phase: MousePhase?
        if isDown {
            if isButtonDown {
                phase = ignoresCurrentSequence ? nil : .dragged
            } else {
                ignoresCurrentSequence = ignoreNewPress
                phase = ignoresCurrentSequence ? nil : .down
            }
        } else if isButtonDown {
            phase = ignoresCurrentSequence ? nil : .up
            ignoresCurrentSequence = false
        } else {
            phase = nil
        }
        isButtonDown = isDown
        return phase
    }
}

public struct PlacedSlot<ScreenID: Hashable>: Equatable {
    public let windowID: UInt32
    public let start: Int
    public let end: Int
    public let screenID: ScreenID

    public init(windowID: UInt32, start: Int, end: Int, screenID: ScreenID) {
        self.windowID = windowID
        self.start = start
        self.end = end
        self.screenID = screenID
    }
}

public struct WindowIdentity: Hashable, Equatable {
    public let windowID: UInt32
    public let ownerPID: Int32

    public init(windowID: UInt32, ownerPID: Int32) {
        self.windowID = windowID
        self.ownerPID = ownerPID
    }
}

public struct StageGroupID: Hashable, Equatable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct StageGroupKey<ScreenID: Hashable>: Hashable {
    public let groupID: StageGroupID
    public let screenID: ScreenID

    public init(groupID: StageGroupID, screenID: ScreenID) {
        self.groupID = groupID
        self.screenID = screenID
    }
}

public struct StageGroupContext<ScreenID: Hashable>: Equatable {
    public let key: StageGroupKey<ScreenID>
    public let visibleWindows: Set<WindowIdentity>
    public let generation: UInt64

    public init(key: StageGroupKey<ScreenID>, visibleWindows: Set<WindowIdentity>, generation: UInt64) {
        self.key = key
        self.visibleWindows = visibleWindows
        self.generation = generation
    }
}

public enum StageGroupObservation<ScreenID: Hashable>: Equatable {
    case none
    case transitioning
    case active(StageGroupContext<ScreenID>)
}

private struct StageGroupRecord<ScreenID: Hashable> {
    let key: StageGroupKey<ScreenID>
    var signature: Set<WindowIdentity>
    var slots: [LayoutSlot]
}

private struct PendingStageGroup {
    var signature: Set<WindowIdentity>
    var sampleCount: Int
}

public struct StageGroupStore<ScreenID: Hashable> {
    private var records: [StageGroupKey<ScreenID>: StageGroupRecord<ScreenID>] = [:]
    private var activeContexts: [ScreenID: StageGroupContext<ScreenID>] = [:]
    private var pending: [ScreenID: PendingStageGroup] = [:]
    private var nextGroupID: UInt64 = 1
    private var generation: UInt64 = 0
    private let requiredStableSamples: Int

    public init(requiredStableSamples: Int = 2) {
        self.requiredStableSamples = max(1, requiredStableSamples)
    }

    public mutating func observe(
        screenID: ScreenID,
        visibleWindows: Set<WindowIdentity>
    ) -> StageGroupObservation<ScreenID> {
        guard !visibleWindows.isEmpty else {
            if activeContexts.removeValue(forKey: screenID) != nil { generation += 1 }
            pending.removeValue(forKey: screenID)
            return .none
        }

        if let active = activeContexts[screenID], active.visibleWindows == visibleWindows {
            return .active(active)
        }

        if pending[screenID]?.signature == visibleWindows {
            pending[screenID]?.sampleCount += 1
        } else {
            generation += 1
            activeContexts.removeValue(forKey: screenID)
            pending[screenID] = PendingStageGroup(signature: visibleWindows, sampleCount: 1)
        }

        guard let candidate = pending[screenID], candidate.sampleCount >= requiredStableSamples else {
            return .transitioning
        }
        pending.removeValue(forKey: screenID)

        let key = matchingKey(screenID: screenID, signature: visibleWindows) ?? createRecord(
            screenID: screenID,
            signature: visibleWindows
        )
        records[key]?.signature = visibleWindows
        generation += 1
        let context = StageGroupContext(key: key, visibleWindows: visibleWindows, generation: generation)
        activeContexts[screenID] = context
        return .active(context)
    }

    public func activeContext(on screenID: ScreenID) -> StageGroupContext<ScreenID>? {
        activeContexts[screenID]
    }

    public func isCurrent(_ context: StageGroupContext<ScreenID>) -> Bool {
        activeContexts[context.key.screenID] == context
    }

    public func slots(in context: StageGroupContext<ScreenID>) -> [LayoutSlot] {
        guard isCurrent(context) else { return [] }
        let visibleIDs = Set(context.visibleWindows.map(\.windowID))
        return records[context.key]?.slots.filter { visibleIDs.contains($0.windowID) } ?? []
    }

    public mutating func setSlots(_ slots: [LayoutSlot], in context: StageGroupContext<ScreenID>) {
        guard isCurrent(context) else { return }
        records[context.key]?.slots = slots
    }

    public func permits(window: WindowIdentity, in context: StageGroupContext<ScreenID>) -> Bool {
        isCurrent(context) && context.visibleWindows.contains(window)
    }

    public var storedGroupCount: Int { records.count }

    private func matchingKey(screenID: ScreenID, signature: Set<WindowIdentity>) -> StageGroupKey<ScreenID>? {
        let localRecords = records.values.filter { $0.key.screenID == screenID }
        if let exact = localRecords.first(where: { $0.signature == signature }) { return exact.key }

        let matches = localRecords.compactMap { record -> (StageGroupKey<ScreenID>, Double)? in
            let intersection = record.signature.intersection(signature).count
            guard intersection > 0 else { return nil }
            let union = record.signature.union(signature).count
            let score = Double(intersection) / Double(union)
            return score >= 0.5 ? (record.key, score) : nil
        }.sorted { $0.1 > $1.1 }
        guard let best = matches.first else { return nil }
        if matches.count > 1, matches[1].1 == best.1 { return nil }
        return best.0
    }

    private mutating func createRecord(
        screenID: ScreenID,
        signature: Set<WindowIdentity>
    ) -> StageGroupKey<ScreenID> {
        let key = StageGroupKey(groupID: StageGroupID(rawValue: nextGroupID), screenID: screenID)
        nextGroupID += 1
        records[key] = StageGroupRecord(key: key, signature: signature, slots: [])
        return key
    }
}

public struct WindowFrameAssignment: Equatable {
    public let windowID: UInt32
    public let frame: CGRect

    public init(windowID: UInt32, frame: CGRect) {
        self.windowID = windowID
        self.frame = frame
    }
}

public enum StageGroupLayout {
    public static func assignments(
        slots: [LayoutSlot],
        visibleWindowIDs: Set<UInt32>,
        visibleFrame: CGRect
    ) -> [WindowFrameAssignment] {
        slots.filter { visibleWindowIDs.contains($0.windowID) }.map {
            WindowFrameAssignment(windowID: $0.windowID, frame: TilingGeometry.frame(for: $0, in: visibleFrame))
        }
    }

    public static func adjacentPairs(
        slots: [LayoutSlot],
        visibleWindowIDs: Set<UInt32>
    ) -> [(left: UInt32, right: UInt32)] {
        let visible = slots.filter { visibleWindowIDs.contains($0.windowID) }
        return visible.flatMap { left in
            visible.filter { $0.start == left.end }.map { (left.windowID, $0.windowID) }
        }
    }
}

public struct VisibleWindowCandidate: Equatable {
    public let windowID: UInt32?
    public let frame: CGRect?
    public let wasPreviouslyMatched: Bool

    public init(windowID: UInt32?, frame: CGRect?, wasPreviouslyMatched: Bool) {
        self.windowID = windowID
        self.frame = frame
        self.wasPreviouslyMatched = wasPreviouslyMatched
    }
}

public enum VisibleWindowMatching {
    public static func candidateIndex(
        for windowID: UInt32,
        expectedFrame: CGRect,
        candidates: [VisibleWindowCandidate],
        frameTolerance: CGFloat = 12,
        allowPreviousFrameMismatch: Bool = false
    ) -> Int? {
        func framesMatch(_ frame: CGRect?) -> Bool {
            guard let frame else { return false }
            return abs(frame.minX - expectedFrame.minX) < frameTolerance &&
                abs(frame.minY - expectedFrame.minY) < frameTolerance &&
                abs(frame.width - expectedFrame.width) < frameTolerance &&
                abs(frame.height - expectedFrame.height) < frameTolerance
        }

        if let exact = candidates.firstIndex(where: { $0.windowID == windowID && framesMatch($0.frame) }) {
            return exact
        }
        if allowPreviousFrameMismatch, let retained = candidates.firstIndex(where: {
            ($0.windowID == nil || $0.windowID == windowID) && $0.wasPreviouslyMatched
        }) {
            return retained
        }
        return candidates.firstIndex {
            $0.windowID == nil && framesMatch($0.frame)
        }
    }
}

public enum TilingState {
    public static func updatingForSnap<ScreenID: Hashable>(
        _ slots: [PlacedSlot<ScreenID>],
        inserting windowID: UInt32,
        on screenID: ScreenID,
        in zone: SnapZone
    ) -> [PlacedSlot<ScreenID>] {
        let local = slots.filter { $0.screenID == screenID && $0.windowID != windowID }.map {
            LayoutSlot(windowID: $0.windowID, start: $0.start, end: $0.end)
        }
        let arranged = TilingGeometry.arrange(existing: local, inserting: windowID, in: zone)
        let retained = slots.filter { $0.screenID != screenID && $0.windowID != windowID }
        return retained + arranged.map {
            PlacedSlot(windowID: $0.windowID, start: $0.start, end: $0.end, screenID: screenID)
        }
    }

    public static func updatingForPalette<ScreenID: Hashable>(
        _ slots: [PlacedSlot<ScreenID>],
        placing windowID: UInt32,
        start: Int,
        end: Int,
        on screenID: ScreenID
    ) -> [PlacedSlot<ScreenID>] {
        let retained = slots.filter {
            $0.windowID != windowID &&
                ($0.screenID != screenID || $0.start >= end || $0.end <= start)
        }
        return retained + [PlacedSlot(windowID: windowID, start: start, end: end, screenID: screenID)]
    }
}

public enum ScreenGeometry {
    public static func index(containing point: CGPoint, frames: [CGRect], tolerance: CGFloat = 2) -> Int? {
        frames.firstIndex { $0.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
    }

    public static func index(
        intersecting windowFrame: CGRect,
        frames: [CGRect],
        fallbackIndex: Int?
    ) -> Int? {
        frames.firstIndex { $0.intersects(windowFrame) } ?? fallbackIndex
    }
}

public struct VisibleWindowGeometry: Equatable {
    public let windowID: UInt32
    public let frame: CGRect

    public init(windowID: UInt32, frame: CGRect) {
        self.windowID = windowID
        self.frame = frame
    }
}

public enum AutoTileGeometry {
    public static func placements(
        for windows: [VisibleWindowGeometry],
        screenFrames: [CGRect],
        maximumWindowsPerScreen: Int = 3
    ) -> [PlacedSlot<Int>] {
        guard maximumWindowsPerScreen > 0 else { return [] }
        var result: [PlacedSlot<Int>] = []
        for (screenIndex, screenFrame) in screenFrames.enumerated() {
            let selected = windows.filter {
                screenFrame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
            }.prefix(maximumWindowsPerScreen).sorted {
                if $0.frame.midX == $1.frame.midX {
                    if $0.frame.midY == $1.frame.midY { return $0.windowID < $1.windowID }
                    return $0.frame.midY > $1.frame.midY
                }
                return $0.frame.midX < $1.frame.midX
            }
            let boundaries: [Int]
            switch selected.count {
            case 1: boundaries = [0, 6]
            case 2: boundaries = [0, 3, 6]
            case 3: boundaries = [0, 2, 4, 6]
            default: continue
            }
            result += selected.enumerated().map {
                PlacedSlot(windowID: $0.element.windowID,
                           start: boundaries[$0.offset],
                           end: boundaries[$0.offset + 1],
                           screenID: screenIndex)
            }
        }
        return result
    }
}

public enum LinkedResizeSource: Equatable {
    case left
    case right
}

public enum WindowFrameWriteOrder: Equatable {
    case leftThenRight
    case rightThenLeft
}

public struct CoupledDragPlan: Equatable {
    public let divider: CGFloat
    public let left: CGRect
    public let right: CGRect
    public let writeOrder: WindowFrameWriteOrder

    public init(divider: CGFloat, left: CGRect, right: CGRect, writeOrder: WindowFrameWriteOrder) {
        self.divider = divider
        self.left = left
        self.right = right
        self.writeOrder = writeOrder
    }
}

public enum CoupledDragGeometry {
    public static func plan(
        left: CGRect,
        right: CGRect,
        requestedDivider: CGFloat,
        previousDivider: CGFloat,
        leftMinimumWidth: CGFloat,
        rightMinimumWidth: CGFloat,
        gap: CGFloat = TilingGeometry.margin
    ) -> CoupledDragPlan? {
        let halfGap = gap / 2
        let minimumDivider = left.minX + leftMinimumWidth + halfGap
        let maximumDivider = right.maxX - rightMinimumWidth - halfGap
        guard minimumDivider <= maximumDivider else { return nil }
        let divider = min(maximumDivider, max(minimumDivider, requestedDivider))
        var newLeft = left
        var newRight = right
        newLeft.size.width = divider - halfGap - left.minX
        newRight.origin.x = divider + halfGap
        newRight.size.width = right.maxX - newRight.minX
        let writeOrder: WindowFrameWriteOrder = divider > previousDivider ? .rightThenLeft : .leftThenRight
        return CoupledDragPlan(divider: divider, left: newLeft, right: newRight, writeOrder: writeOrder)
    }

    public static func correctionDivider(
        desiredDivider: CGFloat,
        actualLeft: CGRect,
        actualRight: CGRect,
        legalRange: ClosedRange<CGFloat>,
        gap: CGFloat = TilingGeometry.margin,
        tolerance: CGFloat = 1.5
    ) -> CGFloat? {
        let halfGap = gap / 2
        let leftDivider = actualLeft.maxX + halfGap
        let rightDivider = actualRight.minX - halfGap
        let leftRejected = abs(leftDivider - desiredDivider) > tolerance
        let rightRejected = abs(rightDivider - desiredDivider) > tolerance
        guard leftRejected || rightRejected else { return nil }

        let correction: CGFloat
        if leftRejected && rightRejected {
            correction = (leftDivider + rightDivider) / 2
        } else if leftRejected {
            correction = leftDivider
        } else {
            correction = rightDivider
        }
        return min(legalRange.upperBound, max(legalRange.lowerBound, correction))
    }

    public static func legalDividerRange(
        left: CGRect,
        right: CGRect,
        leftMinimumWidth: CGFloat,
        rightMinimumWidth: CGFloat,
        gap: CGFloat = TilingGeometry.margin
    ) -> ClosedRange<CGFloat>? {
        let halfGap = gap / 2
        let lowerBound = left.minX + leftMinimumWidth + halfGap
        let upperBound = right.maxX - rightMinimumWidth - halfGap
        guard lowerBound <= upperBound else { return nil }
        return lowerBound...upperBound
    }
}

public struct LinkedResizeUpdate: Equatable {
    public let source: LinkedResizeSource
    public let left: CGRect
    public let right: CGRect

    public init(source: LinkedResizeSource, left: CGRect, right: CGRect) {
        self.source = source
        self.left = left
        self.right = right
    }
}

public enum LinkedResizeGeometry {
    public static func update(
        left: CGRect,
        right: CGRect,
        expectedLeft: CGRect,
        expectedRight: CGRect,
        changeThreshold: CGFloat = 1.5,
        linkingDistance: CGFloat = 40,
        minimumWidth: CGFloat = 100
    ) -> LinkedResizeUpdate? {
        let leftChanged = abs(left.maxX - expectedLeft.maxX) > changeThreshold &&
            abs(left.width - expectedLeft.width) > changeThreshold
        let rightChanged = abs(right.minX - expectedRight.minX) > changeThreshold &&
            abs(right.width - expectedRight.width) > changeThreshold

        if leftChanged && abs(left.maxX - right.minX) <= linkingDistance {
            var linkedRight = right
            linkedRight.origin.x = left.maxX + TilingGeometry.margin
            linkedRight.size.width = max(minimumWidth, right.maxX - linkedRight.minX)
            return LinkedResizeUpdate(source: .left, left: left, right: linkedRight)
        }
        if rightChanged && abs(right.minX - left.maxX) <= linkingDistance {
            var linkedLeft = left
            linkedLeft.size.width = max(minimumWidth, right.minX - TilingGeometry.margin - left.minX)
            return LinkedResizeUpdate(source: .right, left: linkedLeft, right: right)
        }
        return nil
    }
}

public enum BoundaryGeometry {
    public static func dividerX(left: CGRect, right: CGRect) -> CGFloat {
        (left.maxX + right.minX) / 2
    }

    public static func isHit(pointX: CGFloat, dividerX: CGFloat, distance: CGFloat = 40) -> Bool {
        abs(pointX - dividerX) < distance
    }

    public static func isVerticallyEligible(y: CGFloat, visibleFrame: CGRect) -> Bool {
        y >= visibleFrame.minY + TilingGeometry.margin && y <= visibleFrame.maxY - TilingGeometry.margin
    }
}

public struct PaletteLayout: Equatable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

public enum PaletteGeometry {
    public static let layouts = [
        PaletteLayout(start: 0, end: 3),
        PaletteLayout(start: 0, end: 6),
        PaletteLayout(start: 3, end: 6),
        PaletteLayout(start: 0, end: 2),
        PaletteLayout(start: 2, end: 4),
        PaletteLayout(start: 4, end: 6)
    ]

    public static func origin(below button: CGRect, paletteSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        let x = min(visibleFrame.maxX - paletteSize.width - 8,
                    max(visibleFrame.minX + 8, button.midX - paletteSize.width / 2))
        let y = max(visibleFrame.minY + 8, button.minY - paletteSize.height - 6)
        return CGPoint(x: x, y: y)
    }

    public static func grid(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + 9, y: bounds.minY + 9, width: bounds.width - 18, height: bounds.height - 34)
    }

    public static func layoutIndex(at point: CGPoint, in bounds: CGRect) -> Int? {
        let grid = grid(in: bounds)
        guard grid.contains(point) else { return nil }
        let column = min(2, max(0, Int((point.x - grid.minX) / (grid.width / 3))))
        let row = point.y >= grid.midY ? 0 : 1
        return row * 3 + column
    }

    public static func selectedRect(for layout: PaletteLayout, in screenRect: CGRect) -> CGRect {
        CGRect(x: screenRect.minX + screenRect.width * CGFloat(layout.start) / 6,
               y: screenRect.minY,
               width: screenRect.width * CGFloat(layout.end - layout.start) / 6,
               height: screenRect.height)
    }
}

public enum OverlayGeometry {
    public static func layoutWidgetOrigin(panelSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        CGPoint(x: visibleFrame.maxX - panelSize.width - TilingGeometry.margin,
                y: visibleFrame.maxY - panelSize.height - TilingGeometry.margin)
    }

    public static func snapPreviewFrame(existingCount: Int, zone: SnapZone, visibleFrame: CGRect) -> CGRect {
        let range = TilingGeometry.previewRange(existingCount: existingCount, zone: zone)
        return TilingGeometry.frame(
            for: LayoutSlot(windowID: 0,
                            start: Int(round(range.lowerBound * 6)),
                            end: Int(round(range.upperBound * 6))),
            in: visibleFrame
        )
    }
}

public enum CoordinateGeometry {
    public static func flipVertically(_ frame: CGRect, displayHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: displayHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}

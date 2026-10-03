import CoreGraphics

public enum SnapZone: Equatable {
    case left
    case right
    case top
}

public struct LayoutSlot: Equatable {
    public let windowID: UInt32
    public let start: Int
    public let end: Int

    public init(windowID: UInt32, start: Int, end: Int) {
        self.windowID = windowID
        self.start = start
        self.end = end
    }
}

public struct LayoutInsertionTarget: Equatable {
    public let index: Int
    public let indicatorFrame: CGRect

    public init(index: Int, indicatorFrame: CGRect) {
        self.index = index
        self.indicatorFrame = indicatorFrame
    }
}

public struct LayoutReplacementTarget: Equatable {
    public let windowID: UInt32
    public let frame: CGRect

    public init(windowID: UInt32, frame: CGRect) {
        self.windowID = windowID
        self.frame = frame
    }
}

public enum TilingGeometry {
    public static let margin: CGFloat = 15
    public static let sideSnapDistance: CGFloat = 60
    public static let topSnapDistance: CGFloat = 30
    public static let leftStageManagerInset: CGFloat = 140
    public static let leftSnapWidth: CGFloat = sideSnapDistance * 4
    public static let leftSnapHeight: CGFloat = sideSnapDistance * 4
    public static let insertionHitDistance: CGFloat = 30
    public static let insertionIndicatorWidth: CGFloat = 8
    public static let replacementTargetFraction: CGFloat = 0.25
    public static let titleBarDragHeight: CGFloat = 40

    public static func snapZone(at point: CGPoint, in screen: CGRect) -> SnapZone? {
        if abs(point.y - screen.maxY) < topSnapDistance { return .top }
        let leftZone = CGRect(x: screen.minX + leftStageManagerInset,
                              y: screen.minY,
                              width: leftSnapWidth,
                              height: leftSnapHeight)
        if leftZone.contains(point) { return .left }
        if abs(point.x - screen.maxX) < sideSnapDistance { return .right }
        return nil
    }

    public static func shouldHaptic(from oldZone: SnapZone?, to newZone: SnapZone?) -> Bool {
        oldZone != newZone && (oldZone != nil || newZone != nil)
    }

    public static func shouldIgnoreMouseDown(
        at point: CGPoint,
        screenVisibleFrame: CGRect,
        overInteractiveTilesWindow: Bool
    ) -> Bool {
        point.x < screenVisibleFrame.minX + leftStageManagerInset ||
            point.y >= screenVisibleFrame.maxY || overInteractiveTilesWindow
    }

    public static func isTitleBarDragStart(
        at point: CGPoint,
        windowFrame: CGRect,
        titleBarHeight: CGFloat = titleBarDragHeight
    ) -> Bool {
        guard windowFrame.contains(point), titleBarHeight > 0 else { return false }
        return point.y >= windowFrame.maxY - min(titleBarHeight, windowFrame.height)
    }

    public static func isCenteredInStageManagerStrip(windowFrame: CGRect, screenFrame: CGRect) -> Bool {
        windowFrame.midX < screenFrame.minX + leftStageManagerInset
    }

    public static func arrange(existing: [LayoutSlot], inserting windowID: UInt32, in zone: SnapZone) -> [LayoutSlot] {
        if zone == .top { return [LayoutSlot(windowID: windowID, start: 0, end: 6)] }

        var ordered = existing.filter { $0.windowID != windowID }.sorted { $0.start < $1.start }
        while ordered.count >= 3 {
            ordered.remove(at: zone == .left ? 0 : ordered.count - 1)
        }
        if ordered.isEmpty {
            return [LayoutSlot(windowID: windowID, start: zone == .left ? 0 : 3, end: zone == .left ? 3 : 6)]
        }
        return arrange(
            existing: ordered,
            inserting: windowID,
            at: zone == .left ? 0 : ordered.count
        )
    }

    public static func arrange(existing: [LayoutSlot], inserting windowID: UInt32, at index: Int) -> [LayoutSlot] {
        var ordered = existing.sorted { $0.start < $1.start }
        let oldIndex = ordered.firstIndex { $0.windowID == windowID }
        ordered.removeAll { $0.windowID == windowID }
        var insertionIndex = min(max(0, index - ((oldIndex.map { $0 < index }) == true ? 1 : 0)), ordered.count)

        while ordered.count >= 3 {
            if insertionIndex <= ordered.count / 2 {
                ordered.removeLast()
            } else {
                ordered.removeFirst()
                insertionIndex -= 1
            }
        }
        ordered.insert(LayoutSlot(windowID: windowID, start: 0, end: 0), at: insertionIndex)

        if ordered.count == 1 { return [LayoutSlot(windowID: windowID, start: 0, end: 6)] }
        let boundaries = ordered.count == 2 ? [0, 3, 6] : [0, 2, 4, 6]
        return ordered.enumerated().map {
            LayoutSlot(windowID: $0.element.windowID, start: boundaries[$0.offset], end: boundaries[$0.offset + 1])
        }
    }

    public static func insertionTarget(
        at point: CGPoint,
        orderedFrames: [CGRect],
        hitDistance: CGFloat = insertionHitDistance,
        indicatorWidth: CGFloat = insertionIndicatorWidth
    ) -> LayoutInsertionTarget? {
        guard orderedFrames.count >= 2 else { return nil }
        var nearest: (distance: CGFloat, target: LayoutInsertionTarget)?
        for index in 1..<orderedFrames.count {
            let left = orderedFrames[index - 1]
            let right = orderedFrames[index]
            let minY = max(left.minY, right.minY)
            let maxY = min(left.maxY, right.maxY)
            guard minY < maxY, point.y >= minY, point.y <= maxY else { continue }
            let dividerX = (left.maxX + right.minX) / 2
            let distance = abs(point.x - dividerX)
            guard distance <= hitDistance,
                  distance < (nearest?.distance ?? .greatestFiniteMagnitude) else { continue }
            nearest = (distance, LayoutInsertionTarget(
                index: index,
                indicatorFrame: CGRect(
                    x: dividerX - indicatorWidth / 2,
                    y: minY,
                    width: indicatorWidth,
                    height: maxY - minY
                )
            ))
        }
        return nearest?.target
    }

    public static func replacementTarget(
        at point: CGPoint,
        slots: [LayoutSlot],
        visibleFrame: CGRect,
        targetFraction: CGFloat = replacementTargetFraction
    ) -> LayoutReplacementTarget? {
        for slot in slots.sorted(by: { $0.start < $1.start }) {
            let slotFrame = frame(for: slot, in: visibleFrame)
            let fraction = min(1, max(0, targetFraction))
            let targetFrame = CGRect(
                x: slotFrame.minX,
                y: slotFrame.maxY - slotFrame.height * fraction,
                width: slotFrame.width,
                height: slotFrame.height * fraction
            )
            if targetFrame.contains(point) {
                return LayoutReplacementTarget(windowID: slot.windowID, frame: slotFrame)
            }
        }
        return nil
    }

    public static func replacing(
        existing: [LayoutSlot],
        window targetWindowID: UInt32,
        with replacementWindowID: UInt32
    ) -> [LayoutSlot] {
        guard existing.contains(where: { $0.windowID == targetWindowID }) else { return existing }
        return existing.filter { $0.windowID != replacementWindowID }.map {
            guard $0.windowID == targetWindowID else { return $0 }
            return LayoutSlot(windowID: replacementWindowID, start: $0.start, end: $0.end)
        }
    }

    public static func frame(for slot: LayoutSlot, in visibleFrame: CGRect) -> CGRect {
        let unit = visibleFrame.width / 6
        let leftInset = slot.start == 0 ? margin : margin / 2
        let rightInset = slot.end == 6 ? margin : margin / 2
        return CGRect(
            x: visibleFrame.minX + CGFloat(slot.start) * unit + leftInset,
            y: visibleFrame.minY + margin,
            width: CGFloat(slot.end - slot.start) * unit - leftInset - rightInset,
            height: visibleFrame.height - margin * 2
        )
    }

    public static func previewRange(existingCount: Int, zone: SnapZone) -> ClosedRange<CGFloat> {
        if zone == .top { return 0...1 }
        let columns = max(2, min(3, existingCount + 1))
        if zone == .left { return 0...(1 / CGFloat(columns)) }
        return (CGFloat(columns - 1) / CGFloat(columns))...1
    }

    public static func linkedFrames(
        left: CGRect,
        right: CGRect,
        divider: CGFloat,
        minimumWidth: CGFloat = 100
    ) -> (left: CGRect, right: CGRect) {
        let halfGap = margin / 2
        let clamped = min(right.maxX - minimumWidth - halfGap,
                          max(left.minX + minimumWidth + halfGap, divider))
        var linkedLeft = left
        var linkedRight = right
        linkedLeft.size.width = clamped - halfGap - left.minX
        linkedRight.origin.x = clamped + halfGap
        linkedRight.size.width = right.maxX - linkedRight.minX
        return (linkedLeft, linkedRight)
    }
}

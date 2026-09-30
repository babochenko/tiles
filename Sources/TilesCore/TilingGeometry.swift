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

public enum TilingGeometry {
    public static let margin: CGFloat = 15
    public static let sideSnapDistance: CGFloat = 60
    public static let topSnapDistance: CGFloat = 30
    public static let leftStageManagerInset: CGFloat = 140
    public static let leftSnapWidth: CGFloat = sideSnapDistance * 4
    public static let leftSnapHeight: CGFloat = sideSnapDistance * 2

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

    public static func arrange(existing: [LayoutSlot], inserting windowID: UInt32, in zone: SnapZone) -> [LayoutSlot] {
        if zone == .top { return [LayoutSlot(windowID: windowID, start: 0, end: 6)] }

        var ordered = existing.filter { $0.windowID != windowID }.sorted { $0.start < $1.start }
        while ordered.count >= 3 {
            ordered.remove(at: zone == .left ? 0 : ordered.count - 1)
        }
        let placeholder = LayoutSlot(windowID: windowID, start: 0, end: 0)
        if zone == .left { ordered.insert(placeholder, at: 0) } else { ordered.append(placeholder) }

        if ordered.count == 1 {
            return [LayoutSlot(windowID: windowID, start: zone == .left ? 0 : 3, end: zone == .left ? 3 : 6)]
        }
        let boundaries = ordered.count == 2 ? [0, 3, 6] : [0, 2, 4, 6]
        return ordered.enumerated().map {
            LayoutSlot(windowID: $0.element.windowID, start: boundaries[$0.offset], end: boundaries[$0.offset + 1])
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

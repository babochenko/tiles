import CoreGraphics

public struct SnapDragGesture {
    public static let activationDistance: CGFloat = 4

    private var mouseDownPoint: CGPoint?
    public private(set) var isActive = false

    public init() {}

    public mutating func mouseDown(at point: CGPoint) {
        mouseDownPoint = point
        isActive = false
    }

    public mutating func mouseDragged(to point: CGPoint) -> Bool {
        guard let mouseDownPoint else { return false }
        if !isActive {
            let deltaX = point.x - mouseDownPoint.x
            let deltaY = point.y - mouseDownPoint.y
            let distanceSquared = deltaX * deltaX + deltaY * deltaY
            isActive = distanceSquared >= Self.activationDistance * Self.activationDistance
        }
        return isActive
    }

    public mutating func mouseUp() -> Bool {
        let shouldSnap = isActive
        reset()
        return shouldSnap
    }

    public mutating func reset() {
        mouseDownPoint = nil
        isActive = false
    }
}

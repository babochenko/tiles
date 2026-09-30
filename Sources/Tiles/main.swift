import AppKit
import ApplicationServices
import ServiceManagement
import TilesCore

private let margin = TilingGeometry.margin
private let snapDistance: CGFloat = 40
// ApplicationServices exposes this attribute at runtime but not in every SDK's Swift overlay.
private let axWindowNumberAttribute = "AXWindowNumber"
private typealias Slot = PlacedSlot<NSScreen>

final class WindowManager {
    private var slots: [Slot] = []
    private var expected: [CGWindowID: CGRect] = [:]
    private var elements: [CGWindowID: AXUIElement] = [:]
    private var timer: Timer?
    private var mouseSequenceGate = MouseSequenceGate()
    private var boundaryDrag: (left: CGWindowID, right: CGWindowID, leftFrame: CGRect, rightFrame: CGRect)?
    private var draggedWindow: (id: CGWindowID, element: AXUIElement)?
    private var lastExternalWindow: (id: CGWindowID, element: AXUIElement)?
    private var overlay: BoundaryOverlay?
    private var preview: SnapPreviewPanel?
    private var layoutWidget: LayoutPreviewPanel?
    private var zoomPalette: ZoomPalettePanel?
    private var zoomPaletteWindowID: CGWindowID?
    private var cursorIsResizing = false
    private var activeSnapZone: SnapZone?
    private var lastZoomCheck = Date.distantPast
    private var lastSlotCleanup = Date.distantPast
    private var pendingSnap = false
    private var snapDragGesture = SnapDragGesture()

    func start() {
        requestAccessibility()
        let refreshTimer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.reconcileAndShowBoundary()
        }
        refreshTimer.tolerance = 0
        RunLoop.main.add(refreshTimer, forMode: .common)
        timer = refreshTimer
        NSLog("Tiles: running. Drag a window to a physical screen edge and release it.")
    }

    func tileFocusedWindow(start: Int, end: Int) {
        guard let window = focusedWindow() ?? lastExternalWindow else {
            showAccessibilityAlertIfNeeded()
            return
        }
        elements[window.id] = window.element
        let screens = NSScreen.screens
        let fallbackIndex = NSScreen.main.flatMap { main in screens.firstIndex(of: main) }
        guard let windowFrame = frame(of: window.id),
              let screenIndex = ScreenGeometry.index(
                  intersecting: windowFrame,
                  frames: screens.map(\.frame),
                  fallbackIndex: fallbackIndex
              ) else { return }
        let screen = screens[screenIndex]
        applyPaletteLayout(to: window, start: start, end: end, screen: screen)
    }

    func tileVisibleWindows() {
        let screens = NSScreen.screens
        let displayHeight = screens.first?.frame.maxY ?? 0
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        var candidates: [VisibleWindowGeometry] = []

        for info in windowInfo {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != ownPID,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary else { continue }
            var quartzFrame = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds, &quartzFrame) else { continue }
            let frame = CoordinateGeometry.flipVertically(quartzFrame, displayHeight: displayHeight)
            let windowID = CGWindowID(number.uint32Value)
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let element = visibleWindowElement(for: windowID, pid: pid, expectedFrame: frame) else { continue }
            elements[windowID] = element
            candidates.append(VisibleWindowGeometry(windowID: windowID, frame: frame))
        }

        let placements = AutoTileGeometry.placements(for: candidates, screenFrames: screens.map(\.frame))
        guard !placements.isEmpty else {
            NSLog("Tiles: no visible standard windows found to tile.")
            return
        }
        let affectedScreenIndices = Set(placements.map(\.screenID))
        let affectedScreens = Set(affectedScreenIndices.map { screens[$0] })
        let selectedWindowIDs = Set(placements.map(\.windowID))
        slots.removeAll { affectedScreens.contains($0.screenID) || selectedWindowIDs.contains($0.windowID) }
        slots += placements.map {
            Slot(windowID: $0.windowID, start: $0.start, end: $0.end, screenID: screens[$0.screenID])
        }
        for screenIndex in affectedScreenIndices {
            applyLayout(on: screens[screenIndex])
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        NSLog("Tiles: tiled %d visible windows.", placements.count)
    }

    func snapFocusedWindow(at point: CGPoint) {
        guard let window = focusedWindow() ?? lastExternalWindow else {
            NSLog("Tiles: no focused window found. Check Accessibility permission for Tiles/Terminal.")
            showAccessibilityAlertIfNeeded()
            return
        }
        snap(window: window, at: point)
    }

    private func snap(window: (id: CGWindowID, element: AXUIElement), at point: CGPoint) {
        guard let screen = screen(containing: point) else { return }
        elements[window.id] = window.element
        let zone = TilingGeometry.snapZone(at: point, in: screen.frame) ?? (point.x < screen.frame.midX ? .left : .right)
        slots = TilingState.updatingForSnap(slots, inserting: window.id, on: screen, in: zone)
        applyLayout(on: screen)
        NSLog(zone == .top ? "Tiles: maximized window %u" : "Tiles: snapped window %u", window.id)
    }

    private func applyLayout(on screen: NSScreen) {
        let screenSlots = slots.filter { $0.screenID == screen }
        for slot in screenSlots {
            let frame = TilingGeometry.frame(
                for: LayoutSlot(windowID: slot.windowID, start: slot.start, end: slot.end),
                in: screen.visibleFrame
            )
            setFrame(frame, for: slot.windowID)
            expected[slot.windowID] = frame
        }
    }

    private func reconcileAndShowBoundary() {
        pollMouse()
        // Boundary dragging is the latency-sensitive path. Avoid AX reads,
        // CGWindow scans, and overlay work after writing both window frames.
        guard boundaryDrag == nil else { return }
        if Date().timeIntervalSince(lastSlotCleanup) >= 1 {
            lastSlotCleanup = Date()
            slots = slots.filter { windowExists($0.windowID) }
        }
        syncLinkedResize()
        if Date().timeIntervalSince(lastZoomCheck) >= 0.08 {
            lastZoomCheck = Date()
            updateZoomPalette()
        }
        let mouse = NSEvent.mouseLocation
        var nearestX: CGFloat?
        for screen in NSScreen.screens {
            let onScreen = slots.filter { $0.screenID == screen }
            for boundary in 1..<6 where onScreen.contains(where: { $0.end == boundary }) && onScreen.contains(where: { $0.start == boundary }) {
                guard let x = boundaryX(on: screen, at: boundary) else { continue }
                if BoundaryGeometry.isHit(pointX: mouse.x, dividerX: x, distance: snapDistance) &&
                    BoundaryGeometry.isVerticallyEligible(y: mouse.y, visibleFrame: screen.visibleFrame) {
                    nearestX = x
                }
            }
        }
        overlay?.close()
        if let nearestX {
            NSCursor.resizeLeftRight.set()
            cursorIsResizing = true
            overlay = BoundaryOverlay(x: nearestX, y: mouse.y); overlay?.show()
        } else if cursorIsResizing {
            NSCursor.arrow.set()
            cursorIsResizing = false
        }
    }

    private func pollMouse() {
        let isDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let point = NSEvent.mouseLocation
        var shouldIgnoreNewPress = false
        if isDown && !mouseSequenceGate.isButtonDown {
            let inTilesWindow = NSApp.windows.contains {
                $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(point)
            }
            shouldIgnoreNewPress = screen(containing: point).map {
                TilingGeometry.shouldIgnoreMouseDown(at: point, screenVisibleFrame: $0.visibleFrame,
                                                     overInteractiveTilesWindow: inTilesWindow)
            } ?? inTilesWindow
        }
        switch mouseSequenceGate.update(isDown: isDown, ignoreNewPress: shouldIgnoreNewPress) {
        case .down: mouseDown(at: point)
        case .dragged: mouseDragged(at: point)
        case .up: mouseUp(at: point)
        case nil: break
        }
    }

    private func syncLinkedResize() {
        for left in slots {
            for right in slots where right.screenID == left.screenID && right.start == left.end {
                guard let leftFrame = frame(of: left.windowID), let rightFrame = frame(of: right.windowID),
                      let oldLeft = expected[left.windowID], let oldRight = expected[right.windowID] else { continue }
                guard let update = LinkedResizeGeometry.update(
                    left: leftFrame,
                    right: rightFrame,
                    expectedLeft: oldLeft,
                    expectedRight: oldRight,
                    linkingDistance: snapDistance
                ) else { continue }

                if update.source == .left {
                    setFrame(update.right, for: right.windowID)
                } else {
                    setFrame(update.left, for: left.windowID)
                }
                expected[left.windowID] = update.left
                expected[right.windowID] = update.right
            }
        }
    }

    fileprivate func mouseDown(at point: CGPoint) {
        if let candidate = boundaryAt(point) {
            boundaryDrag = candidate
            NSCursor.resizeLeftRight.set()
            cursorIsResizing = true
            overlay?.close()
            preview?.close()
            pendingSnap = false
            snapDragGesture.reset()
        } else {
            pendingSnap = true
            snapDragGesture.mouseDown(at: point)
            draggedWindow = focusedWindow()
        }
    }

    fileprivate func mouseDragged(at point: CGPoint) {
        guard let drag = boundaryDrag else {
            guard snapDragGesture.mouseDragged(to: point) else { return }
            // On mouse-down the clicked application may not yet have become
            // frontmost. Resolve it again once the system starts the drag.
            draggedWindow = focusedWindow() ?? draggedWindow
            updatePreview(at: point)
            return
        }
        let frames = TilingGeometry.linkedFrames(left: drag.leftFrame, right: drag.rightFrame, divider: point.x)
        setFrame(frames.left, for: drag.left); setFrame(frames.right, for: drag.right)
        expected[drag.left] = frames.left; expected[drag.right] = frames.right
    }

    fileprivate func mouseUp(at point: CGPoint) {
        preview?.close()
        preview = nil
        layoutWidget?.close()
        layoutWidget = nil
        activeSnapZone = nil
        let shouldSnap = snapDragGesture.mouseUp()
        if pendingSnap && shouldSnap {
            if let screen = screen(containing: point), TilingGeometry.snapZone(at: point, in: screen.frame) != nil {
                if let window = draggedWindow ?? focusedWindow() {
                    snap(window: window, at: point)
                } else {
                    NSLog("Tiles: reached an edge but could not identify the dragged window.")
                }
            }
        }
        pendingSnap = false
        draggedWindow = nil
        boundaryDrag = nil
        if cursorIsResizing { NSCursor.arrow.set(); cursorIsResizing = false }
    }

    private func boundaryAt(_ point: CGPoint) -> (left: CGWindowID, right: CGWindowID, leftFrame: CGRect, rightFrame: CGRect)? {
        for screen in NSScreen.screens {
            for boundary in 1..<6 {
                guard let left = slots.first(where: { $0.screenID == screen && $0.end == boundary }),
                      let right = slots.first(where: { $0.screenID == screen && $0.start == boundary }),
                      let leftFrame = frame(of: left.windowID), let rightFrame = frame(of: right.windowID) else { continue }
                let x = BoundaryGeometry.dividerX(left: leftFrame, right: rightFrame)
                if BoundaryGeometry.isHit(pointX: point.x, dividerX: x, distance: snapDistance) {
                    return (left.windowID, right.windowID, leftFrame, rightFrame)
                }
            }
        }
        return nil
    }

    private func boundaryX(on screen: NSScreen, at boundary: Int) -> CGFloat? {
        guard let left = slots.first(where: { $0.screenID == screen && $0.end == boundary }),
              let right = slots.first(where: { $0.screenID == screen && $0.start == boundary }),
              let leftFrame = frame(of: left.windowID), let rightFrame = frame(of: right.windowID) else { return nil }
        return BoundaryGeometry.dividerX(left: leftFrame, right: rightFrame)
    }

    private func updatePreview(at point: CGPoint) {
        guard let screen = screen(containing: point) else {
            preview?.close(); preview = nil
            layoutWidget?.close(); layoutWidget = nil
            activeSnapZone = nil
            return
        }
        let zone = TilingGeometry.snapZone(at: point, in: screen.frame)
        if TilingGeometry.shouldHaptic(from: activeSnapZone, to: zone) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        activeSnapZone = zone
        let current = slots.filter { $0.screenID == screen && $0.windowID != draggedWindow?.id }
            .map { (CGFloat($0.start) / 6, CGFloat($0.end) / 6) }
        var future: (CGFloat, CGFloat)?
        if let zone {
            let range = TilingGeometry.previewRange(existingCount: current.count, zone: zone)
            future = (range.lowerBound, range.upperBound)
        }
        if layoutWidget == nil { layoutWidget = LayoutPreviewPanel() }
        layoutWidget?.show(on: screen, current: current, future: future)

        guard let zone else {
            preview?.close(); preview = nil
            return
        }

        let range = TilingGeometry.previewRange(existingCount: current.count, zone: zone)
        let target = TilingGeometry.frame(
            for: LayoutSlot(windowID: 0, start: Int(round(range.lowerBound * 6)), end: Int(round(range.upperBound * 6))),
            in: screen.visibleFrame
        )
        if preview == nil { preview = SnapPreviewPanel() }
        preview?.show(frame: target)
    }

    private func updateZoomPalette() {
        guard !pendingSnap, boundaryDrag == nil else {
            zoomPalette?.close(); zoomPalette = nil; zoomPaletteWindowID = nil
            return
        }
        let mouse = NSEvent.mouseLocation
        if let palette = zoomPalette, palette.frame.insetBy(dx: -8, dy: -8).contains(mouse) { return }
        guard let window = focusedWindow(), let buttonFrame = zoomButtonFrame(of: window.element),
              buttonFrame.insetBy(dx: -6, dy: -6).contains(mouse),
              let screen = screen(containing: mouse) else {
            zoomPalette?.close(); zoomPalette = nil; zoomPaletteWindowID = nil
            return
        }
        elements[window.id] = window.element
        if zoomPaletteWindowID != window.id {
            zoomPalette?.close()
            zoomPalette = nil
        }
        if zoomPalette == nil {
            zoomPalette = ZoomPalettePanel { [weak self] start, end in
                self?.applyPaletteLayout(to: window, start: start, end: end, screen: screen)
            }
            zoomPaletteWindowID = window.id
        }
        zoomPalette?.show(below: buttonFrame, on: screen)
    }

    private func zoomButtonFrame(of window: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXZoomButtonAttribute as CFString, &value) == .success,
              let value, let frame = axFrame(of: value as! AXUIElement) else { return nil }
        let displayHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CoordinateGeometry.flipVertically(frame, displayHeight: displayHeight)
    }

    private func applyPaletteLayout(to window: (id: CGWindowID, element: AXUIElement), start: Int, end: Int, screen: NSScreen) {
        elements[window.id] = window.element
        slots = TilingState.updatingForPalette(slots, placing: window.id, start: start, end: end, on: screen)
        applyLayout(on: screen)
        zoomPalette?.close(); zoomPalette = nil; zoomPaletteWindowID = nil
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func focusedWindow() -> (id: CGWindowID, element: AXUIElement)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value)
        guard let value else { return nil }
        let window = value as! AXUIElement
        var number: CFTypeRef?
        AXUIElementCopyAttributeValue(window, axWindowNumberAttribute as CFString, &number)
        if let number = number as? NSNumber {
            let result = (id: CGWindowID(number.uint32Value), element: window)
            lastExternalWindow = result
            return result
        }

        // AXWindowNumber is not exported by all macOS SDKs and is absent for
        // some applications. Match the focused AX window to its CG window by
        // PID and bounds instead of silently making snapping a no-op.
        let pid = app.processIdentifier
        guard let axFrame = axFrame(of: window) else { return nil }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in windows where (info[kCGWindowOwnerPID as String] as? pid_t) == pid {
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
            var cgFrame = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds, &cgFrame), abs(cgFrame.width - axFrame.width) < 3,
                  abs(cgFrame.height - axFrame.height) < 3 else { continue }
            let result = (id: CGWindowID(number.uint32Value), element: window)
            lastExternalWindow = result
            return result
        }
        return nil
    }

    private func visibleWindowElement(for id: CGWindowID, pid: pid_t, expectedFrame: CGRect) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        let displayHeight = NSScreen.screens.first?.frame.maxY ?? 0
        for item in (value as? [AXUIElement] ?? []) {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXRoleAttribute as CFString, &role)
            guard role as? String == kAXWindowRole else { continue }
            var minimized: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXMinimizedAttribute as CFString, &minimized)
            if (minimized as? NSNumber)?.boolValue == true { continue }

            var number: CFTypeRef?
            AXUIElementCopyAttributeValue(item, axWindowNumberAttribute as CFString, &number)
            if let number = number as? NSNumber, number.uint32Value != id { continue }
            guard let frame = axFrame(of: item).map({
                CoordinateGeometry.flipVertically($0, displayHeight: displayHeight)
            }), framesApproximatelyMatch(frame, expectedFrame) else { continue }
            return item
        }
        return nil
    }

    private func framesApproximatelyMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 12 && abs(lhs.minY - rhs.minY) < 12 &&
            abs(lhs.width - rhs.width) < 12 && abs(lhs.height - rhs.height) < 12
    }

    private func axFrame(of window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?; var size: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position)
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size)
        guard let position, let size else { return nil }
        var point = CGPoint.zero; var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func setFrame(_ frame: CGRect, for id: CGWindowID) {
        if let item = elements[id] {
            setFrame(frame, on: item)
            return
        }
        guard let app = application(for: id) else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        for item in (value as? [AXUIElement] ?? []) {
            var number: CFTypeRef?
            AXUIElementCopyAttributeValue(item, axWindowNumberAttribute as CFString, &number)
            guard (number as? NSNumber)?.uint32Value == id else { continue }
            elements[id] = item
            setFrame(frame, on: item)
            return
        }
    }

    private func setFrame(_ frame: CGRect, on item: AXUIElement) {
        let displayHeight = NSScreen.screens.first?.frame.maxY ?? 0
        var point = CoordinateGeometry.flipVertically(frame, displayHeight: displayHeight).origin
        var size = CGSize(width: frame.width, height: frame.height)
        let positionResult = AXUIElementSetAttributeValue(item, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &point)!)
        let sizeResult = AXUIElementSetAttributeValue(item, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
        if positionResult != .success || sizeResult != .success {
            NSLog("Tiles: macOS rejected window movement (%d, %d). Check Accessibility access.", positionResult.rawValue, sizeResult.rawValue)
        }
    }

    private func frame(of id: CGWindowID) -> CGRect? {
        if let item = elements[id], let axFrame = axFrame(of: item) {
            let displayHeight = NSScreen.screens.first?.frame.maxY ?? 0
            return CoordinateGeometry.flipVertically(axFrame, displayHeight: displayHeight)
        }
        guard let app = application(for: id) else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        for item in (value as? [AXUIElement] ?? []) {
            var number: CFTypeRef?
            AXUIElementCopyAttributeValue(item, axWindowNumberAttribute as CFString, &number)
            guard (number as? NSNumber)?.uint32Value == id else { continue }
            var position: CFTypeRef?; var size: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &position)
            AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size)
            guard let position, let size else { return nil }
            var point = CGPoint.zero; var dimensions = CGSize.zero
            AXValueGetValue(position as! AXValue, .cgPoint, &point)
            AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
            let axFrame = CGRect(origin: point, size: dimensions)
            let displayHeight = NSScreen.screens.first?.frame.maxY ?? 0
            return CoordinateGeometry.flipVertically(axFrame, displayHeight: displayHeight)
        }
        return nil
    }

    private func application(for id: CGWindowID) -> NSRunningApplication? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let pid = info.first?[kCGWindowOwnerPID as String] as? pid_t else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    private func windowExists(_ id: CGWindowID) -> Bool { application(for: id) != nil }
    private func screen(containing point: CGPoint) -> NSScreen? {
        let screens = NSScreen.screens
        guard let index = ScreenGeometry.index(containing: point, frames: screens.map(\.frame)) else { return nil }
        return screens[index]
    }
    private func requestAccessibility() { if !AXIsProcessTrusted() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) } }
    private func showAccessibilityAlertIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let alert = NSAlert()
        alert.messageText = "Tiles needs Accessibility access"
        alert.informativeText = "Enable Tiles in System Settings → Privacy & Security → Accessibility, then relaunch Tiles."
        alert.runModal()
    }
}

final class BoundaryOverlay: NSPanel {
    init(x: CGFloat, y: CGFloat) {
        super.init(contentRect: NSRect(x: x - 13, y: y - 13, width: 26, height: 26), styleMask: .borderless, backing: .buffered, defer: false)
        isFloatingPanel = true; level = .screenSaver; backgroundColor = .clear; isOpaque = false; ignoresMouseEvents = true
        contentView = GripView()
    }
    func show() { orderFrontRegardless() }
}

final class SnapPreviewPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = SnapPreviewView()
    }

    func show(frame: CGRect) {
        setFrame(frame, display: true)
        orderFrontRegardless()
    }
}

final class SnapPreviewView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        NSColor.controlAccentColor.withAlphaComponent(0.24).setFill()
        path.fill()
        path.lineWidth = 2
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }
}

final class GripView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 6, yRadius: 6).fill()
        let text = NSString(string: "↔")
        text.draw(at: NSPoint(x: 5, y: 4), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 14, weight: .bold)])
    }
}

final class LayoutPreviewPanel: NSPanel {
    private let previewView = LayoutPreviewView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 220, height: 92), styleMask: .borderless, backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = previewView
    }

    func show(on screen: NSScreen, current: [(CGFloat, CGFloat)], future: (CGFloat, CGFloat)?) {
        let size = frame.size
        setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - size.width - margin,
                               y: screen.visibleFrame.maxY - size.height - margin))
        previewView.current = current
        previewView.future = future
        previewView.needsDisplay = true
        orderFrontRegardless()
    }
}

final class LayoutPreviewView: NSView {
    var current: [(CGFloat, CGFloat)] = []
    var future: (CGFloat, CGFloat)?

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        background.fill()

        let title = NSString(string: future == nil ? "Current layout" : "Drop preview")
        title.draw(at: NSPoint(x: 12, y: 66), withAttributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        ])

        let canvas = NSRect(x: 12, y: 12, width: bounds.width - 24, height: 46)
        NSColor.separatorColor.setStroke()
        let outline = NSBezierPath(roundedRect: canvas, xRadius: 5, yRadius: 5)
        outline.lineWidth = 1
        outline.stroke()

        for range in current {
            let rect = NSRect(x: canvas.minX + canvas.width * range.0 + 2,
                              y: canvas.minY + 2,
                              width: canvas.width * (range.1 - range.0) - 4,
                              height: canvas.height - 4)
            NSColor.secondaryLabelColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        }

        if let future {
            let rect = NSRect(x: canvas.minX + canvas.width * future.0 + 2,
                              y: canvas.minY + 2,
                              width: canvas.width * (future.1 - future.0) - 4,
                              height: canvas.height - 4)
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            NSColor.controlAccentColor.withAlphaComponent(0.55).setFill()
            path.fill()
            path.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }
}

final class ZoomPalettePanel: NSPanel {
    init(selection: @escaping (Int, Int) -> Void) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 198, height: 126),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = ZoomPaletteView(selection: selection)
    }

    override var canBecomeKey: Bool { false }

    func show(below button: CGRect, on screen: NSScreen) {
        setFrameOrigin(PaletteGeometry.origin(below: button, paletteSize: frame.size, visibleFrame: screen.visibleFrame))
        orderFrontRegardless()
    }
}

final class ZoomPaletteView: NSView {
    private let selection: (Int, Int) -> Void

    init(selection: @escaping (Int, Int) -> Void) {
        self.selection = selection
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = PaletteGeometry.layoutIndex(at: point, in: bounds) else { return }
        let layout = PaletteGeometry.layouts[index]
        selection(layout.start, layout.end)
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        background.fill()
        NSString(string: "Tile window").draw(at: NSPoint(x: 10, y: bounds.height - 21), withAttributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold)
        ])

        let grid = PaletteGeometry.grid(in: bounds)
        let cellWidth = grid.width / 3
        let cellHeight = grid.height / 2
        for index in PaletteGeometry.layouts.indices {
            let column = index % 3
            let row = index / 3
            let cell = NSRect(x: grid.minX + CGFloat(column) * cellWidth + 3,
                              y: grid.minY + CGFloat(1 - row) * cellHeight + 3,
                              width: cellWidth - 6, height: cellHeight - 6)
            NSColor.separatorColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: cell, xRadius: 6, yRadius: 6).fill()

            let screen = cell.insetBy(dx: 9, dy: 8)
            let layout = PaletteGeometry.layouts[index]
            let selected = PaletteGeometry.selectedRect(for: layout, in: screen)
            NSColor.controlAccentColor.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: selected, xRadius: 2, yRadius: 2).fill()
            NSColor.tertiaryLabelColor.setStroke()
            NSBezierPath(roundedRect: screen, xRadius: 2, yRadius: 2).stroke()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let manager = WindowManager()
    private var statusItem: NSStatusItem?
    private var launchAtStartupItem: NSMenuItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.title = "▦"
        let menu = NSMenu()
        menu.delegate = self
        let launchItem = menu.addItem(withTitle: "Launch at startup", action: #selector(toggleLaunchAtStartup), keyEquivalent: "")
        launchItem.target = self
        launchAtStartupItem = launchItem
        menu.addItem(.separator())
        let tileItem = NSMenuItem(title: "Tile focused window", action: nil, keyEquivalent: "")
        let tileMenu = NSMenu(title: "Tile focused window")
        for option in [("Left half", 0, 3), ("Full screen", 0, 6), ("Right half", 3, 6),
                       ("Left third", 0, 2), ("Center third", 2, 4), ("Right third", 4, 6)] {
            let optionItem = tileMenu.addItem(withTitle: option.0, action: #selector(tileFromMenu(_:)), keyEquivalent: "")
            optionItem.target = self
            optionItem.tag = option.1 * 10 + option.2
        }
        tileItem.submenu = tileMenu
        menu.addItem(tileItem)
        let tileVisibleItem = menu.addItem(withTitle: "Tile visible windows", action: #selector(tileVisibleWindows), keyEquivalent: "")
        tileVisibleItem.target = self
        let snapItem = menu.addItem(withTitle: "Snap focused window under cursor", action: #selector(snap), keyEquivalent: "")
        snapItem.target = self
        let accessibilityItem = menu.addItem(withTitle: "Accessibility status", action: #selector(accessibilityStatus), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "Quit Tiles", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        item.menu = menu
        updateLaunchAtStartupItem()
        manager.start()
    }
    func menuWillOpen(_ menu: NSMenu) { updateLaunchAtStartupItem() }
    @objc private func tileFromMenu(_ sender: NSMenuItem) {
        manager.tileFocusedWindow(start: sender.tag / 10, end: sender.tag % 10)
    }
    @objc private func tileVisibleWindows() { manager.tileVisibleWindows() }
    @objc private func toggleLaunchAtStartup() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            updateLaunchAtStartupItem()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not update Launch at startup"
            alert.informativeText = "Install Tiles in Applications and try again.\n\n\(error.localizedDescription)"
            alert.runModal()
        }
    }
    private func updateLaunchAtStartupItem() {
        launchAtStartupItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    @objc private func snap() { manager.snapFocusedWindow(at: NSEvent.mouseLocation) }
    @objc private func accessibilityStatus() {
        let message = AXIsProcessTrusted() ? "Accessibility access is enabled." : "Accessibility access is missing. Enable Tiles or Terminal in System Settings → Privacy & Security → Accessibility."
        let alert = NSAlert(); alert.messageText = message; alert.runModal()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(); app.delegate = delegate
app.run()

import AppKit
import ApplicationServices

private let margin: CGFloat = 15
private let innerMargin = margin / 2
private let snapDistance: CGFloat = 40
// ApplicationServices exposes this attribute at runtime but not in every SDK's Swift overlay.
private let axWindowNumberAttribute = "AXWindowNumber"

struct Slot: Equatable {
    let windowID: CGWindowID
    let start: Int
    let end: Int
    let screenID: NSScreen

    static func == (lhs: Slot, rhs: Slot) -> Bool {
        lhs.windowID == rhs.windowID && lhs.start == rhs.start && lhs.end == rhs.end && lhs.screenID == rhs.screenID
    }
}

final class WindowManager {
    private var slots: [Slot] = []
    private var expected: [CGWindowID: CGRect] = [:]
    private var elements: [CGWindowID: AXUIElement] = [:]
    private var timer: Timer?
    private var globalMonitor: Any?
    private var boundaryDrag: (left: CGWindowID, right: CGWindowID, leftFrame: CGRect, rightFrame: CGRect)?
    private var draggedWindow: (id: CGWindowID, element: AXUIElement)?
    private var overlay: BoundaryOverlay?
    private var preview: SnapPreviewPanel?
    private var cursorIsResizing = false
    private var pendingSnap = false

    func start() {
        requestAccessibility()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.reconcileAndShowBoundary()
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return }
            let point = NSEvent.mouseLocation
            switch event.type {
            case .leftMouseDown: self.mouseDown(at: point)
            case .leftMouseDragged: self.mouseDragged(at: point)
            case .leftMouseUp: self.mouseUp(at: point)
            default: break
            }
        }
        NSLog("Tiles: running. Drag a window to a physical screen edge and release it.")
    }

    func snapFocusedWindow(at point: CGPoint) {
        guard let window = focusedWindow() else {
            NSLog("Tiles: no focused window found. Check Accessibility permission for Tiles/Terminal.")
            return
        }
        snap(window: window, at: point)
    }

    private func snap(window: (id: CGWindowID, element: AXUIElement), at point: CGPoint) {
        guard let screen = screen(containing: point) else { return }
        elements[window.id] = window.element
        if abs(point.y - screen.frame.maxY) < 40 {
            slots.removeAll { $0.screenID == screen || $0.windowID == window.id }
            slots.append(Slot(windowID: window.id, start: 0, end: 6, screenID: screen))
            applyLayout(on: screen)
            NSLog("Tiles: maximized window %u", window.id)
            return
        }
        let column = min(2, max(0, Int((point.x - screen.visibleFrame.minX) / (screen.visibleFrame.width / 3))))
        var ordered = slots.filter { $0.screenID == screen && $0.windowID != window.id }.sorted { $0.start < $1.start }
        if ordered.count == 3 {
            ordered.remove(at: column == 0 ? 0 : column == 2 ? 2 : 1)
        }
        let insertion = column == 0 ? 0 : column == 2 ? ordered.count : ordered.count / 2
        ordered.insert(Slot(windowID: window.id, start: 0, end: 0, screenID: screen), at: insertion)

        slots.removeAll { $0.screenID == screen || $0.windowID == window.id }
        if ordered.count == 1 {
            let range = column == 2 ? (3, 6) : column == 1 ? (1, 5) : (0, 3)
            slots.append(Slot(windowID: window.id, start: range.0, end: range.1, screenID: screen))
        } else {
            let boundaries = ordered.count == 2 ? [0, 3, 6] : [0, 2, 4, 6]
            for (index, slot) in ordered.enumerated() {
                slots.append(Slot(windowID: slot.windowID, start: boundaries[index], end: boundaries[index + 1], screenID: screen))
            }
        }
        applyLayout(on: screen)
        NSLog("Tiles: snapped window %u", window.id)
    }

    private func applyLayout(on screen: NSScreen) {
        let screenSlots = slots.filter { $0.screenID == screen }
        let unit = screen.visibleFrame.width / 6
        for slot in screenSlots {
            let leftInset = slot.start == 0 ? margin : innerMargin
            let rightInset = slot.end == 6 ? margin : innerMargin
            let frame = CGRect(x: screen.visibleFrame.minX + CGFloat(slot.start) * unit + leftInset,
                               y: screen.visibleFrame.minY + margin,
                               width: CGFloat(slot.end - slot.start) * unit - leftInset - rightInset,
                               height: screen.visibleFrame.height - margin * 2)
            setFrame(frame, for: slot.windowID)
            expected[slot.windowID] = frame
        }
    }

    private func reconcileAndShowBoundary() {
        slots = slots.filter { windowExists($0.windowID) }
        syncLinkedResize()
        guard boundaryDrag == nil else { return }
        let mouse = NSEvent.mouseLocation
        var nearestX: CGFloat?
        for screen in NSScreen.screens {
            let onScreen = slots.filter { $0.screenID == screen }
            for boundary in 1..<6 where onScreen.contains(where: { $0.end == boundary }) && onScreen.contains(where: { $0.start == boundary }) {
                guard let x = boundaryX(on: screen, at: boundary) else { continue }
                if abs(mouse.x - x) < snapDistance && mouse.y >= screen.visibleFrame.minY + margin && mouse.y <= screen.visibleFrame.maxY - margin {
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

    private func syncLinkedResize() {
        for left in slots {
            for right in slots where right.screenID == left.screenID && right.start == left.end {
                guard let leftFrame = frame(of: left.windowID), let rightFrame = frame(of: right.windowID),
                      let oldLeft = expected[left.windowID], let oldRight = expected[right.windowID] else { continue }
                let leftChanged = abs(leftFrame.maxX - oldLeft.maxX) > 1.5 && abs(leftFrame.width - oldLeft.width) > 1.5
                let rightChanged = abs(rightFrame.minX - oldRight.minX) > 1.5 && abs(rightFrame.width - oldRight.width) > 1.5
                guard leftChanged || rightChanged else { continue }

                if leftChanged && abs(leftFrame.maxX - rightFrame.minX) <= snapDistance {
                    var linkedRight = rightFrame
                    linkedRight.origin.x = leftFrame.maxX + margin
                    linkedRight.size.width = max(100, rightFrame.maxX - linkedRight.minX)
                    setFrame(linkedRight, for: right.windowID)
                    expected[left.windowID] = leftFrame; expected[right.windowID] = linkedRight
                } else if rightChanged && abs(rightFrame.minX - leftFrame.maxX) <= snapDistance {
                    var linkedLeft = leftFrame
                    linkedLeft.size.width = max(100, rightFrame.minX - margin - leftFrame.minX)
                    setFrame(linkedLeft, for: left.windowID)
                    expected[left.windowID] = linkedLeft; expected[right.windowID] = rightFrame
                }
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
        } else {
            pendingSnap = true
            draggedWindow = focusedWindow()
        }
    }

    fileprivate func mouseDragged(at point: CGPoint) {
        guard let drag = boundaryDrag else {
            // On mouse-down the clicked application may not yet have become
            // frontmost. Resolve it again once the system starts the drag.
            draggedWindow = focusedWindow() ?? draggedWindow
            updatePreview(at: point)
            return
        }
        let divider = min(drag.rightFrame.maxX - 100 - innerMargin, max(drag.leftFrame.minX + 100 + innerMargin, point.x))
        var leftFrame = drag.leftFrame
        var rightFrame = drag.rightFrame
        leftFrame.size.width = divider - innerMargin - leftFrame.minX
        rightFrame.origin.x = divider + innerMargin
        rightFrame.size.width = drag.rightFrame.maxX - rightFrame.minX
        setFrame(leftFrame, for: drag.left); setFrame(rightFrame, for: drag.right)
        expected[drag.left] = leftFrame; expected[drag.right] = rightFrame
    }

    fileprivate func mouseUp(at point: CGPoint) {
        preview?.close()
        preview = nil
        if pendingSnap {
            if let screen = screen(containing: point),
               (abs(point.x - screen.frame.minX) < 40 || abs(point.x - screen.frame.maxX) < 40 || abs(point.y - screen.frame.maxY) < 40) {
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
                let x = (leftFrame.maxX + rightFrame.minX) / 2
                if abs(point.x - x) < snapDistance { return (left.windowID, right.windowID, leftFrame, rightFrame) }
            }
        }
        return nil
    }

    private func boundaryX(on screen: NSScreen, at boundary: Int) -> CGFloat? {
        guard let left = slots.first(where: { $0.screenID == screen && $0.end == boundary }),
              let right = slots.first(where: { $0.screenID == screen && $0.start == boundary }),
              let leftFrame = frame(of: left.windowID), let rightFrame = frame(of: right.windowID) else { return nil }
        return (leftFrame.maxX + rightFrame.minX) / 2
    }

    private func updatePreview(at point: CGPoint) {
        guard let screen = screen(containing: point) else {
            preview?.close(); preview = nil
            return
        }
        let nearTop = abs(point.y - screen.frame.maxY) < 60
        let nearLeft = abs(point.x - screen.frame.minX) < 60
        let nearRight = abs(point.x - screen.frame.maxX) < 60
        guard nearTop || nearLeft || nearRight else {
            preview?.close(); preview = nil
            return
        }

        let target: CGRect
        if nearTop {
            target = screen.visibleFrame.insetBy(dx: margin, dy: margin)
        } else {
            let existingCount = slots.filter { $0.screenID == screen && $0.windowID != draggedWindow?.id }.count
            let columns = max(2, min(3, existingCount + 1))
            let isLeft = nearLeft
            let index = isLeft ? 0 : columns - 1
            let columnWidth = screen.visibleFrame.width / CGFloat(columns)
            let leftInset = index == 0 ? margin : innerMargin
            let rightInset = index == columns - 1 ? margin : innerMargin
            target = CGRect(x: screen.visibleFrame.minX + CGFloat(index) * columnWidth + leftInset,
                            y: screen.visibleFrame.minY + margin,
                            width: columnWidth - leftInset - rightInset,
                            height: screen.visibleFrame.height - margin * 2)
        }
        if preview == nil { preview = SnapPreviewPanel() }
        preview?.show(frame: target)
    }

    private func focusedWindow() -> (id: CGWindowID, element: AXUIElement)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value)
        guard let value else { return nil }
        let window = value as! AXUIElement
        var number: CFTypeRef?
        AXUIElementCopyAttributeValue(window, axWindowNumberAttribute as CFString, &number)
        if let number = number as? NSNumber { return (CGWindowID(number.uint32Value), window) }

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
            return (CGWindowID(number.uint32Value), window)
        }
        return nil
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
        var point = CGPoint(x: frame.minX, y: displayHeight - frame.maxY)
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
            return CGRect(x: axFrame.minX, y: displayHeight - axFrame.maxY, width: axFrame.width, height: axFrame.height)
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
            return CGRect(origin: point, size: dimensions)
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
        NSScreen.screens.first { $0.frame.insetBy(dx: -2, dy: -2).contains(point) }
    }
    private func requestAccessibility() { if !AXIsProcessTrusted() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) } }
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager = WindowManager()
    private var statusItem: NSStatusItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.title = "▦"
        let menu = NSMenu(); menu.addItem(withTitle: "Snap focused window under cursor", action: #selector(snap), keyEquivalent: "s"); menu.addItem(withTitle: "Accessibility status", action: #selector(accessibilityStatus), keyEquivalent: ""); menu.addItem(.separator()); menu.addItem(withTitle: "Quit Tiles", action: #selector(quit), keyEquivalent: "q")
        item.menu = menu
        manager.start()
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

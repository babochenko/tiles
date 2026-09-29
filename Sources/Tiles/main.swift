import AppKit
import ApplicationServices

private let margin: CGFloat = 15
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
    private var boundaryDrag: (screen: NSScreen, boundary: Int, startX: CGFloat, original: [Slot])?
    private var draggedWindow: (id: CGWindowID, element: AXUIElement)?
    private var overlay: BoundaryOverlay?
    private var pendingSnap = false

    func start() {
        requestAccessibility()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
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
            let frame = CGRect(x: screen.visibleFrame.minX + CGFloat(slot.start) * unit + margin,
                               y: screen.visibleFrame.minY + margin,
                               width: CGFloat(slot.end - slot.start) * unit - margin * 2,
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
        var nearest: (NSScreen, Int)?
        for screen in NSScreen.screens {
            let onScreen = slots.filter { $0.screenID == screen }
            for boundary in 1..<6 where onScreen.contains(where: { $0.end == boundary }) && onScreen.contains(where: { $0.start == boundary }) {
                let x = screen.visibleFrame.minX + CGFloat(boundary) * screen.visibleFrame.width / 6
                if abs(mouse.x - x) < snapDistance && mouse.y >= screen.visibleFrame.minY + margin && mouse.y <= screen.visibleFrame.maxY - margin {
                    nearest = (screen, boundary)
                }
            }
        }
        overlay?.close()
        if let nearest { overlay = BoundaryOverlay(screen: nearest.0, boundary: nearest.1); overlay?.show() }
    }

    private func syncLinkedResize() {
        for left in slots {
            guard let leftFrame = frame(of: left.windowID), let oldFrame = expected[left.windowID],
                  abs(leftFrame.maxX - oldFrame.maxX) > 2 || abs(leftFrame.minX - oldFrame.minX) > 2 else { continue }
            for right in slots where right.screenID == left.screenID && right.start == left.end {
                guard let rightFrame = frame(of: right.windowID), abs(leftFrame.maxX - rightFrame.minX) < snapDistance else { continue }
                let shared = (leftFrame.maxX + rightFrame.minX) / 2
                var newLeft = leftFrame; newLeft.size.width = max(80, shared - 7 - newLeft.minX)
                var newRight = rightFrame; newRight.origin.x = shared + 7; newRight.size.width = max(80, rightFrame.maxX - newRight.minX)
                setFrame(newLeft, for: left.windowID); setFrame(newRight, for: right.windowID)
                expected[left.windowID] = newLeft; expected[right.windowID] = newRight
            }
        }
    }

    fileprivate func mouseDown(at point: CGPoint) {
        if let candidate = boundaryAt(point) {
            boundaryDrag = (candidate.screen, candidate.boundary, point.x, slots)
            overlay?.close()
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
            return
        }
        let delta = point.x - drag.startX
        let screen = drag.screen
        let unit = screen.visibleFrame.width / 6
        let change = Int(round(delta / unit))
        guard change != 0 else { return }
        slots = drag.original.map { slot in
            guard slot.screenID == screen else { return slot }
            if slot.end == drag.boundary { return Slot(windowID: slot.windowID, start: slot.start, end: max(slot.start + 1, min(5, drag.boundary + change)), screenID: screen) }
            if slot.start == drag.boundary { return Slot(windowID: slot.windowID, start: max(1, min(drag.boundary + change, slot.end - 1)), end: slot.end, screenID: screen) }
            return slot
        }
        applyLayout(on: screen)
    }

    fileprivate func mouseUp(at point: CGPoint) {
        if pendingSnap {
            if let screen = screen(containing: point),
               (abs(point.x - screen.frame.minX) < 40 || abs(point.x - screen.frame.maxX) < 40) {
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
    }

    private func boundaryAt(_ point: CGPoint) -> (screen: NSScreen, boundary: Int)? {
        for screen in NSScreen.screens {
            let unit = screen.visibleFrame.width / 6
            for boundary in 1..<6 {
                let x = screen.visibleFrame.minX + CGFloat(boundary) * unit
                let left = slots.contains { $0.screenID == screen && $0.end == boundary }
                let right = slots.contains { $0.screenID == screen && $0.start == boundary }
                if left && right && abs(point.x - x) < snapDistance { return (screen, boundary) }
            }
        }
        return nil
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
    init(screen: NSScreen, boundary: Int) {
        let x = screen.visibleFrame.minX + CGFloat(boundary) * screen.visibleFrame.width / 6
        super.init(contentRect: NSRect(x: x - 13, y: screen.visibleFrame.midY - 13, width: 26, height: 26), styleMask: .borderless, backing: .buffered, defer: false)
        isFloatingPanel = true; level = .screenSaver; backgroundColor = .clear; isOpaque = false; ignoresMouseEvents = true
        contentView = GripView()
    }
    func show() { orderFrontRegardless() }
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

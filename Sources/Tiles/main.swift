import AppKit
import ApplicationServices

private let margin: CGFloat = 15
private let snapDistance: CGFloat = 28
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
    private var timer: Timer?
    private var eventTap: CFMachPort?
    private var boundaryDrag: (screen: NSScreen, boundary: Int, startX: CGFloat, original: [Slot])?
    private var overlay: BoundaryOverlay?
    private var pendingSnap = false

    func start() {
        requestAccessibility()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.reconcileAndShowBoundary()
        }
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue |
                               1 << CGEventType.leftMouseDragged.rawValue |
                               1 << CGEventType.leftMouseUp.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                     options: .listenOnly, eventsOfInterest: mask, callback: eventCallback,
                                     userInfo: context)
        if let eventTap {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    func snapFocusedWindow(at point: CGPoint) {
        guard let window = focusedWindow(), let screen = screen(containing: point) else { return }
        let column = min(2, max(0, Int((point.x - screen.visibleFrame.minX) / (screen.visibleFrame.width / 3))))
        let target: (Int, Int) = slots.isEmpty ? (column == 0 ? (0, 3) : column == 2 ? (3, 6) : (1, 5)) : freeTarget(column: column)
        slots.removeAll { $0.windowID == window.id || $0.screenID == screen }
        slots.append(Slot(windowID: window.id, start: target.0, end: target.1, screenID: screen))
        applyLayout(on: screen)
    }

    private func freeTarget(column: Int) -> (Int, Int) {
        let occupied = slots.filter { $0.start <= column && $0.end > column }
        if occupied.isEmpty { return (column, column + 1) }
        if slots.count >= 3 { // Three columns are the limit: replace the nearest slot.
            let nearest = slots.min { abs(($0.start + $0.end) / 2 - column) < abs(($1.start + $1.end) / 2 - column) }
            if let nearest { slots.removeAll { $0 == nearest } }
        }
        return (column, column + 1)
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
        }
    }

    fileprivate func mouseDragged(at point: CGPoint) {
        guard let drag = boundaryDrag else { return }
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

    fileprivate func mouseUp() {
        if pendingSnap {
            let point = NSEvent.mouseLocation
            if let screen = screen(containing: point),
               (abs(point.x - screen.visibleFrame.minX) < 32 || abs(point.x - screen.visibleFrame.maxX) < 32) {
                snapFocusedWindow(at: point)
            }
        }
        pendingSnap = false
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
        return (number as? NSNumber).map { (CGWindowID($0.uint32Value), window) }
    }

    private func setFrame(_ frame: CGRect, for id: CGWindowID) {
        guard let app = application(for: id) else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        for item in (value as? [AXUIElement] ?? []) {
            var number: CFTypeRef?
            AXUIElementCopyAttributeValue(item, axWindowNumberAttribute as CFString, &number)
            guard (number as? NSNumber)?.uint32Value == id else { continue }
            var point = CGPoint(x: frame.minX, y: NSScreen.screens.first?.frame.maxY ?? 0 - frame.maxY)
            var size = CGSize(width: frame.width, height: frame.height)
            AXUIElementSetAttributeValue(item, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &point)!)
            AXUIElementSetAttributeValue(item, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
            return
        }
    }

    private func frame(of id: CGWindowID) -> CGRect? {
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
    private func screen(containing point: CGPoint) -> NSScreen? { NSScreen.screens.first { $0.frame.contains(point) } }
    private func requestAccessibility() { if !AXIsProcessTrusted() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) } }
}

private func eventCallback(_: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<WindowManager>.fromOpaque(userInfo).takeUnretainedValue()
    let point = event.location
    switch type { case .leftMouseDown: manager.mouseDown(at: point); case .leftMouseDragged: manager.mouseDragged(at: point); case .leftMouseUp: manager.mouseUp(); default: break }
    return Unmanaged.passUnretained(event)
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "▦"
        let menu = NSMenu(); menu.addItem(withTitle: "Snap focused window under cursor", action: #selector(snap), keyEquivalent: "s"); menu.addItem(.separator()); menu.addItem(withTitle: "Quit Tiles", action: #selector(quit), keyEquivalent: "q")
        item.menu = menu
        manager.start()
    }
    @objc private func snap() { manager.snapFocusedWindow(at: NSEvent.mouseLocation) }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(); app.delegate = delegate
app.run()

import AppKit
import ApplicationServices
import ServiceManagement
import TilesCore

private let margin = TilingGeometry.margin
private let snapDistance: CGFloat = 40
// ApplicationServices exposes this attribute at runtime but not in every SDK's Swift overlay.
private let axWindowNumberAttribute = "AXWindowNumber"
private let axMinimumSizeAttribute = "AXMinSize"
private typealias DisplayID = UInt32

private struct VisibleRuntimeWindow {
    let identity: WindowIdentity
    let frame: CGRect
    let element: AXUIElement
    let screenID: DisplayID
}

private enum WindowDropTarget: Equatable {
    case zone(SnapZone)
    case insertion(Int)
}

private struct ResolvedWindowDropTarget {
    let target: WindowDropTarget
    let indicatorFrame: CGRect?
}

private struct BoundaryDrag {
    let left: CGWindowID
    let right: CGWindowID
    let leftFrame: CGRect
    let rightFrame: CGRect
    let leftMinimumWidth: CGFloat
    let rightMinimumWidth: CGFloat
    let legalDividerRange: ClosedRange<CGFloat>
    let context: StageGroupContext<DisplayID>
    var lastDivider: CGFloat
}

final class WindowManager {
    private var stageGroups = StageGroupStore<DisplayID>()
    private var visibleWindows: [WindowIdentity: VisibleRuntimeWindow] = [:]
    private var visibleWindowOrder: [WindowIdentity] = []
    private var expected: [CGWindowID: CGRect] = [:]
    private var elements: [CGWindowID: AXUIElement] = [:]
    private var timer: Timer?
    private var mouseEventMonitor: Any?
    private var ignoringMouseSequence = false
    private var boundaryDrag: BoundaryDrag?
    private var boundarySettlePending = false
    private var draggedWindow: (id: CGWindowID, element: AXUIElement)?
    private var overlay: BoundaryOverlay?
    private var preview: SnapPreviewPanel?
    private var previewScreen: NSScreen?
    private var layoutWidget: LayoutPreviewPanel?
    private var layoutWidgetScreen: NSScreen?
    private var zoomPalette: ZoomPalettePanel?
    private var zoomPaletteWindowID: CGWindowID?
    private var cursorIsResizing = false
    private var activeDropTarget: WindowDropTarget?
    private var lastZoomCheck = Date.distantPast
    private var pendingSnap = false
    private var snapDragGesture = SnapDragGesture()

    func start() {
        requestAccessibility()
        mouseEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            let point = NSEvent.mouseLocation
            DispatchQueue.main.async {
                self?.handleMouseEvent(event.type, at: point)
            }
        }
        let refreshTimer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.reconcileAndShowBoundary()
        }
        refreshTimer.tolerance = 0
        RunLoop.main.add(refreshTimer, forMode: .common)
        timer = refreshTimer
        NSLog("Tiles: running. Drag a window to a physical screen edge and release it.")
    }

    deinit {
        if let mouseEventMonitor { NSEvent.removeMonitor(mouseEventMonitor) }
    }

    func tileFocusedWindow(start: Int, end: Int) {
        refreshVisibleGroups()
        guard let window = focusedWindow() else {
            showAccessibilityAlertIfNeeded()
            return
        }
        elements[window.id] = window.element
        let screens = NSScreen.screens
        guard let windowFrame = frame(of: window.id),
              let screenIndex = ScreenGeometry.index(
                  intersecting: windowFrame,
                  frames: screens.map(\.frame),
                  fallbackIndex: nil
              ) else { return }
        let screen = screens[screenIndex]
        applyPaletteLayout(to: window, start: start, end: end, screen: screen)
    }

    func tileVisibleWindows() {
        refreshVisibleGroups()
        let screens = NSScreen.screens
        var tiledCount = 0
        for screen in screens {
            let id = displayID(for: screen)
            guard let context = stageGroups.activeContext(on: id) else { continue }
            let candidates = visibleWindowOrder.compactMap { visibleWindows[$0] }
                .filter { $0.screenID == id && context.visibleWindows.contains($0.identity) }
                .map { VisibleWindowGeometry(windowID: $0.identity.windowID, frame: $0.frame) }
            let placements = AutoTileGeometry.placements(for: candidates, screenFrames: [screen.frame])
            let newSlots = placements.map {
                LayoutSlot(windowID: $0.windowID, start: $0.start, end: $0.end)
            }
            guard !newSlots.isEmpty else { continue }
            stageGroups.setSlots(newSlots, in: context)
            applyLayout(in: context, on: screen)
            tiledCount += newSlots.count
        }
        guard tiledCount > 0 else {
            NSLog("Tiles: no visible standard windows found to tile.")
            return
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        NSLog("Tiles: tiled %d visible windows.", tiledCount)
    }

    func snapFocusedWindow(at point: CGPoint) {
        refreshVisibleGroups()
        guard let window = focusedWindow() else {
            NSLog("Tiles: no focused window found. Check Accessibility permission for Tiles/Terminal.")
            showAccessibilityAlertIfNeeded()
            return
        }
        snap(window: window, at: point)
    }

    private func snap(
        window: (id: CGWindowID, element: AXUIElement),
        at point: CGPoint,
        requestedTarget: WindowDropTarget? = nil
    ) {
        refreshVisibleGroups()
        guard let screen = screen(containing: point),
              let context = stageGroups.activeContext(on: displayID(for: screen)),
              let identity = identity(for: window.id), stageGroups.permits(window: identity, in: context) else { return }
        elements[window.id] = window.element
        let fallback = WindowDropTarget.zone(point.x < screen.frame.midX ? .left : .right)
        let target = requestedTarget ?? resolvedDropTarget(at: point, on: screen, in: context)?.target ?? fallback
        let existing = stageGroups.slots(in: context)
        let arranged: [LayoutSlot]
        switch target {
        case let .zone(zone):
            arranged = TilingGeometry.arrange(existing: existing, inserting: window.id, in: zone)
        case let .insertion(index):
            arranged = TilingGeometry.arrange(existing: existing, inserting: window.id, at: index)
        }
        stageGroups.setSlots(arranged, in: context)
        applyLayout(in: context, on: screen)
        if case .zone(.top) = target {
            NSLog("Tiles: maximized window %u", window.id)
        } else {
            NSLog("Tiles: snapped window %u", window.id)
        }
    }

    private func applyLayout(in context: StageGroupContext<DisplayID>, on screen: NSScreen) {
        let visibleIDs = Set(context.visibleWindows.map(\.windowID))
        let assignments = StageGroupLayout.assignments(
            slots: stageGroups.slots(in: context), visibleWindowIDs: visibleIDs, visibleFrame: screen.visibleFrame
        )
        for assignment in assignments {
            guard setFrame(assignment.frame, for: assignment.windowID, in: context) else { continue }
            expected[assignment.windowID] = assignment.frame
        }
    }

    private func reconcileAndShowBoundary() {
        // Boundary dragging is the latency-sensitive path. Avoid AX reads,
        // CGWindow scans, and overlay work after writing both window frames.
        guard boundaryDrag == nil, !boundarySettlePending else { return }
        if Date().timeIntervalSince(lastZoomCheck) >= 0.08 {
            lastZoomCheck = Date()
            refreshVisibleGroups()
            updateZoomPalette()
        }
        syncLinkedResize()
        let mouse = NSEvent.mouseLocation
        var nearestX: CGFloat?
        for screen in NSScreen.screens {
            guard let context = stageGroups.activeContext(on: displayID(for: screen)) else { continue }
            let onScreen = stageGroups.slots(in: context)
            for boundary in 1..<6 where onScreen.contains(where: { $0.end == boundary }) && onScreen.contains(where: { $0.start == boundary }) {
                guard let x = boundaryX(in: context, at: boundary) else { continue }
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

    private func handleMouseEvent(_ type: NSEvent.EventType, at point: CGPoint) {
        switch type {
        case .leftMouseDown:
            let inTilesWindow = NSApp.windows.contains {
                $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(point)
            }
            ignoringMouseSequence = screen(containing: point).map {
                TilingGeometry.shouldIgnoreMouseDown(at: point, screenVisibleFrame: $0.visibleFrame,
                                                     overInteractiveTilesWindow: inTilesWindow)
            } ?? inTilesWindow
            if !ignoringMouseSequence { mouseDown(at: point) }
        case .leftMouseDragged:
            if !ignoringMouseSequence { mouseDragged(at: point) }
        case .leftMouseUp:
            if !ignoringMouseSequence { mouseUp(at: point) }
            ignoringMouseSequence = false
        default:
            break
        }
    }

    private func syncLinkedResize() {
        for screen in NSScreen.screens {
            guard let context = stageGroups.activeContext(on: displayID(for: screen)) else { continue }
            let slots = stageGroups.slots(in: context)
            let visibleIDs = Set(context.visibleWindows.map(\.windowID))
            for pair in StageGroupLayout.adjacentPairs(slots: slots, visibleWindowIDs: visibleIDs) {
                guard let leftFrame = frame(of: pair.left), let rightFrame = frame(of: pair.right),
                      let oldLeft = expected[pair.left], let oldRight = expected[pair.right] else { continue }
                guard let update = LinkedResizeGeometry.update(
                    left: leftFrame,
                    right: rightFrame,
                    expectedLeft: oldLeft,
                    expectedRight: oldRight,
                    linkingDistance: snapDistance
                ) else { continue }

                if update.source == .left {
                    guard setFrame(update.right, for: pair.right, in: context) else { continue }
                } else {
                    guard setFrame(update.left, for: pair.left, in: context) else { continue }
                }
                expected[pair.left] = update.left
                expected[pair.right] = update.right
            }
        }
    }

    fileprivate func mouseDown(at point: CGPoint) {
        if let candidate = boundaryAt(point) {
            boundaryDrag = candidate
            NSCursor.resizeLeftRight.set()
            cursorIsResizing = true
            overlay?.close()
            preview?.close(); preview = nil; previewScreen = nil
            layoutWidget?.close(); layoutWidget = nil; layoutWidgetScreen = nil
            pendingSnap = false
            snapDragGesture.reset()
        } else {
            pendingSnap = true
            snapDragGesture.mouseDown(at: point)
            draggedWindow = focusedWindow()
        }
    }

    fileprivate func mouseDragged(at point: CGPoint) {
        guard var drag = boundaryDrag else {
            guard snapDragGesture.mouseDragged(to: point) else { return }
            // On mouse-down the clicked application may not yet have become
            // frontmost. Resolve it again once the system starts the drag.
            draggedWindow = focusedWindow() ?? draggedWindow
            updatePreview(at: point)
            return
        }
        guard let plan = CoupledDragGeometry.plan(
            left: drag.leftFrame,
            right: drag.rightFrame,
            requestedDivider: point.x,
            previousDivider: drag.lastDivider,
            leftMinimumWidth: drag.leftMinimumWidth,
            rightMinimumWidth: drag.rightMinimumWidth
        ), abs(plan.divider - drag.lastDivider) >= 0.01 else { return }
        applyCoupledDragPlan(plan, left: drag.left, right: drag.right, in: drag.context)
        expected[drag.left] = plan.left
        expected[drag.right] = plan.right
        drag.lastDivider = plan.divider
        boundaryDrag = drag
    }

    fileprivate func mouseUp(at point: CGPoint) {
        if let boundaryDrag {
            boundarySettlePending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.settleBoundaryDrag(boundaryDrag)
                self?.boundarySettlePending = false
            }
        }
        preview?.close()
        preview = nil
        previewScreen = nil
        layoutWidget?.close()
        layoutWidget = nil
        layoutWidgetScreen = nil
        activeDropTarget = nil
        let shouldSnap = snapDragGesture.mouseUp()
        if pendingSnap && shouldSnap {
            if let screen = screen(containing: point),
               let context = stageGroups.activeContext(on: displayID(for: screen)),
               let target = resolvedDropTarget(at: point, on: screen, in: context)?.target {
                if let window = draggedWindow ?? focusedWindow() {
                    snap(window: window, at: point, requestedTarget: target)
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

    private func boundaryAt(_ point: CGPoint) -> BoundaryDrag? {
        for screen in NSScreen.screens {
            guard BoundaryGeometry.isVerticallyEligible(y: point.y, visibleFrame: screen.visibleFrame),
                  let context = stageGroups.activeContext(on: displayID(for: screen)) else { continue }
            let slots = stageGroups.slots(in: context)
            for boundary in 1..<6 {
                guard let left = slots.first(where: { $0.end == boundary }),
                      let right = slots.first(where: { $0.start == boundary }),
                      let leftFrame = frame(of: left.windowID), let rightFrame = frame(of: right.windowID) else { continue }
                let x = BoundaryGeometry.dividerX(left: leftFrame, right: rightFrame)
                if BoundaryGeometry.isHit(pointX: point.x, dividerX: x, distance: snapDistance) {
                    let leftMinimumWidth = minimumWidth(for: left.windowID)
                    let rightMinimumWidth = minimumWidth(for: right.windowID)
                    guard let legalDividerRange = CoupledDragGeometry.legalDividerRange(
                        left: leftFrame,
                        right: rightFrame,
                        leftMinimumWidth: leftMinimumWidth,
                        rightMinimumWidth: rightMinimumWidth
                    ) else { continue }
                    return BoundaryDrag(
                        left: left.windowID,
                        right: right.windowID,
                        leftFrame: leftFrame,
                        rightFrame: rightFrame,
                        leftMinimumWidth: leftMinimumWidth,
                        rightMinimumWidth: rightMinimumWidth,
                        legalDividerRange: legalDividerRange,
                        context: context,
                        lastDivider: x
                    )
                }
            }
        }
        return nil
    }

    private func applyCoupledDragPlan(
        _ plan: CoupledDragPlan,
        left: CGWindowID,
        right: CGWindowID,
        in context: StageGroupContext<DisplayID>
    ) {
        guard stageGroups.isCurrent(context) else { return }
        if plan.writeOrder == .rightThenLeft {
            guard setFrame(plan.right, for: right, in: context) else { return }
            _ = setFrame(plan.left, for: left, in: context)
        } else {
            guard setFrame(plan.left, for: left, in: context) else { return }
            _ = setFrame(plan.right, for: right, in: context)
        }
    }

    private func settleBoundaryDrag(_ drag: BoundaryDrag) {
        refreshVisibleGroups()
        guard stageGroups.isCurrent(drag.context),
              let actualLeft = frame(of: drag.left), let actualRight = frame(of: drag.right),
              let divider = CoupledDragGeometry.correctionDivider(
                  desiredDivider: drag.lastDivider,
                  actualLeft: actualLeft,
                  actualRight: actualRight,
                  legalRange: drag.legalDividerRange
              ), let plan = CoupledDragGeometry.plan(
                  left: drag.leftFrame,
                  right: drag.rightFrame,
                  requestedDivider: divider,
                  previousDivider: drag.lastDivider,
                  leftMinimumWidth: drag.leftMinimumWidth,
                  rightMinimumWidth: drag.rightMinimumWidth
              ) else { return }
        applyCoupledDragPlan(plan, left: drag.left, right: drag.right, in: drag.context)
        expected[drag.left] = plan.left
        expected[drag.right] = plan.right
    }

    private func boundaryX(in context: StageGroupContext<DisplayID>, at boundary: Int) -> CGFloat? {
        let slots = stageGroups.slots(in: context)
        guard let left = slots.first(where: { $0.end == boundary }),
              let right = slots.first(where: { $0.start == boundary }),
              let leftFrame = frame(of: left.windowID), let rightFrame = frame(of: right.windowID) else { return nil }
        return BoundaryGeometry.dividerX(left: leftFrame, right: rightFrame)
    }

    private func updatePreview(at point: CGPoint) {
        guard let screen = screen(containing: point),
              let context = stageGroups.activeContext(on: displayID(for: screen)) else {
            preview?.close(); preview = nil
            previewScreen = nil
            layoutWidget?.close(); layoutWidget = nil
            layoutWidgetScreen = nil
            activeDropTarget = nil
            return
        }
        let resolvedTarget = resolvedDropTarget(at: point, on: screen, in: context)
        let dropTarget = resolvedTarget?.target
        if activeDropTarget != dropTarget && (activeDropTarget != nil || dropTarget != nil) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        activeDropTarget = dropTarget
        let slots = stageGroups.slots(in: context)
        var current = slots.filter { $0.windowID != draggedWindow?.id }
            .map { (CGFloat($0.start) / 6, CGFloat($0.end) / 6) }
        var future: (CGFloat, CGFloat)?
        if case let .zone(zone) = dropTarget {
            let range = TilingGeometry.previewRange(existingCount: current.count, zone: zone)
            future = (range.lowerBound, range.upperBound)
        } else if case let .insertion(index) = dropTarget {
            let insertedWindowID = draggedWindow?.id ?? UInt32.max
            let arranged = TilingGeometry.arrange(existing: slots, inserting: insertedWindowID, at: index)
            current = arranged.filter { $0.windowID != insertedWindowID }
                .map { (CGFloat($0.start) / 6, CGFloat($0.end) / 6) }
            if let inserted = arranged.first(where: { $0.windowID == insertedWindowID }) {
                future = (CGFloat(inserted.start) / 6, CGFloat(inserted.end) / 6)
            }
        }
        if layoutWidgetScreen != screen {
            layoutWidget?.close()
            layoutWidget = nil
        }
        if layoutWidget == nil {
            layoutWidget = LayoutPreviewPanel()
            layoutWidgetScreen = screen
        }
        layoutWidget?.show(on: screen, current: current, future: future)

        guard let resolvedTarget else {
            preview?.close(); preview = nil
            previewScreen = nil
            return
        }

        let target: CGRect
        switch resolvedTarget.target {
        case let .zone(zone):
            target = OverlayGeometry.snapPreviewFrame(
                existingCount: current.count, zone: zone, visibleFrame: screen.visibleFrame
            )
        case .insertion:
            guard let indicatorFrame = resolvedTarget.indicatorFrame else { return }
            target = indicatorFrame
        }
        if previewScreen != screen {
            preview?.close()
            preview = nil
        }
        if preview == nil {
            preview = SnapPreviewPanel()
            previewScreen = screen
        }
        preview?.show(frame: target)
    }

    private func resolvedDropTarget(
        at point: CGPoint,
        on screen: NSScreen,
        in context: StageGroupContext<DisplayID>
    ) -> ResolvedWindowDropTarget? {
        if let zone = TilingGeometry.snapZone(at: point, in: screen.frame) {
            return ResolvedWindowDropTarget(target: .zone(zone), indicatorFrame: nil)
        }
        let slots = stageGroups.slots(in: context).sorted { $0.start < $1.start }
        if slots.count >= 3, !slots.contains(where: { $0.windowID == draggedWindow?.id }) { return nil }
        let orderedFrames = slots.map {
            TilingGeometry.frame(for: $0, in: screen.visibleFrame)
        }
        guard let insertion = TilingGeometry.insertionTarget(at: point, orderedFrames: orderedFrames) else {
            return nil
        }
        return ResolvedWindowDropTarget(
            target: .insertion(insertion.index), indicatorFrame: insertion.indicatorFrame
        )
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
        guard let context = stageGroups.activeContext(on: displayID(for: screen)),
              let identity = identity(for: window.id), stageGroups.permits(window: identity, in: context) else {
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
        refreshVisibleGroups()
        guard let context = stageGroups.activeContext(on: displayID(for: screen)),
              let identity = identity(for: window.id), stageGroups.permits(window: identity, in: context) else { return }
        elements[window.id] = window.element
        let retained = stageGroups.slots(in: context).filter {
            $0.windowID != window.id && ($0.start >= end || $0.end <= start)
        }
        stageGroups.setSlots(retained + [LayoutSlot(windowID: window.id, start: start, end: end)], in: context)
        applyLayout(in: context, on: screen)
        zoomPalette?.close(); zoomPalette = nil; zoomPaletteWindowID = nil
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func refreshVisibleGroups() {
        let screens = NSScreen.screens
        let displayHeight = screens.first?.frame.maxY ?? 0
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        var scanned: [WindowIdentity: VisibleRuntimeWindow] = [:]
        var order: [WindowIdentity] = []

        for info in windowInfo {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != ownPID,
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary else { continue }
            var quartzFrame = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds, &quartzFrame) else { continue }
            let frame = CoordinateGeometry.flipVertically(quartzFrame, displayHeight: displayHeight)
            guard let screenIndex = ScreenGeometry.index(
                containing: CGPoint(x: frame.midX, y: frame.midY), frames: screens.map(\.frame), tolerance: 0
            ) else { continue }
            guard !TilingGeometry.isCenteredInStageManagerStrip(
                windowFrame: frame, screenFrame: screens[screenIndex].frame
            ) else { continue }
            let windowID = CGWindowID(number.uint32Value)
            guard let element = visibleWindowElement(for: windowID, pid: pid, expectedFrame: frame) else { continue }
            let identity = WindowIdentity(windowID: windowID, ownerPID: pid)
            let record = VisibleRuntimeWindow(
                identity: identity, frame: frame, element: element, screenID: displayID(for: screens[screenIndex])
            )
            scanned[identity] = record
            order.append(identity)
            elements[windowID] = element
        }

        // Some applications, notably Safari, do not expose enough metadata on
        // every AX window for the CG/AX scan above to pair them reliably. The
        // frontmost focused AX window is authoritative and necessarily belongs
        // to the active Stage Manager group, so merge it into the snapshot.
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ownPID,
           let focused = focusedWindow(),
           let rawFrame = axFrame(of: focused.element) {
            let frame = CoordinateGeometry.flipVertically(rawFrame, displayHeight: displayHeight)
            if let screenIndex = ScreenGeometry.index(
                containing: CGPoint(x: frame.midX, y: frame.midY), frames: screens.map(\.frame), tolerance: 0
            ), !TilingGeometry.isCenteredInStageManagerStrip(
                windowFrame: frame, screenFrame: screens[screenIndex].frame
            ) {
                let identity = WindowIdentity(windowID: focused.id, ownerPID: app.processIdentifier)
                scanned[identity] = VisibleRuntimeWindow(
                    identity: identity,
                    frame: frame,
                    element: focused.element,
                    screenID: displayID(for: screens[screenIndex])
                )
                if !order.contains(identity) { order.insert(identity, at: 0) }
                elements[focused.id] = focused.element
            }
        }

        visibleWindows = scanned
        visibleWindowOrder = order
        for screen in screens {
            let screenID = displayID(for: screen)
            let signature = Set(scanned.values.filter { $0.screenID == screenID }.map(\.identity))
            let previous = stageGroups.activeContext(on: screenID)
            let observation = stageGroups.observe(screenID: screenID, visibleWindows: signature)
            switch observation {
            case let .active(context):
                if previous != context {
                    for identity in context.visibleWindows {
                        if let currentFrame = scanned[identity]?.frame { expected[identity.windowID] = currentFrame }
                    }
                }
            case .none, .transitioning:
                closeSnapOverlays()
                if boundaryDrag?.context.key.screenID == screenID { boundaryDrag = nil }
            }
        }
    }

    private func closeSnapOverlays() {
        preview?.close(); preview = nil; previewScreen = nil
        layoutWidget?.close(); layoutWidget = nil; layoutWidgetScreen = nil
        activeDropTarget = nil
    }

    private func displayID(for screen: NSScreen) -> DisplayID {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return number.uint32Value
        }
        return DisplayID(NSScreen.screens.firstIndex(of: screen) ?? 0) + 1
    }

    private func identity(for windowID: CGWindowID) -> WindowIdentity? {
        visibleWindows.keys.first { $0.windowID == windowID }
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
            return result
        }

        // AXWindowNumber is not exported by all macOS SDKs and is absent for
        // some applications. Match the focused AX window to its CG window by
        // PID and bounds instead of silently making snapping a no-op.
        let pid = app.processIdentifier
        guard let axFrame = axFrame(of: window) else { return nil }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var candidates: [(id: CGWindowID, frame: CGRect)] = []
        for info in windows where (info[kCGWindowOwnerPID as String] as? pid_t) == pid {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
            var cgFrame = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds, &cgFrame) else { continue }
            candidates.append((CGWindowID(number.uint32Value), cgFrame))
        }
        guard let index = VisibleWindowMatching.closestFrameIndex(
            to: axFrame, candidates: candidates.map(\.frame)
        ) else { return nil }
        return (id: candidates[index].id, element: window)
    }

    private func visibleWindowElement(for id: CGWindowID, pid: pid_t, expectedFrame: CGRect) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        let displayHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let previous = visibleWindows[WindowIdentity(windowID: id, ownerPID: pid)]?.element
        var candidates: [(element: AXUIElement, match: VisibleWindowCandidate)] = []
        for item in (value as? [AXUIElement] ?? []) {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXRoleAttribute as CFString, &role)
            guard role as? String == kAXWindowRole else { continue }
            var minimized: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXMinimizedAttribute as CFString, &minimized)
            if (minimized as? NSNumber)?.boolValue == true { continue }

            var number: CFTypeRef?
            AXUIElementCopyAttributeValue(item, axWindowNumberAttribute as CFString, &number)
            let frame = axFrame(of: item).map({
                CoordinateGeometry.flipVertically($0, displayHeight: displayHeight)
            })
            candidates.append((item, VisibleWindowCandidate(
                windowID: (number as? NSNumber)?.uint32Value,
                frame: frame,
                wasPreviouslyMatched: previous.map { CFEqual(item, $0) } ?? false
            )))
        }
        guard let index = VisibleWindowMatching.candidateIndex(
            for: id,
            expectedFrame: expectedFrame,
            candidates: candidates.map(\.match),
            allowPreviousFrameMismatch: snapDragGesture.isActive && draggedWindow?.id == id
        ) else { return nil }
        return candidates[index].element
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

    private func minimumWidth(for id: CGWindowID) -> CGFloat {
        guard let item = elements[id] else { return 100 }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, axMinimumSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return 100 }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size), size.width > 0 else { return 100 }
        return size.width
    }

    private func setFrame(
        _ frame: CGRect,
        for id: CGWindowID,
        in context: StageGroupContext<DisplayID>
    ) -> Bool {
        guard stageGroups.isCurrent(context), let identity = identity(for: id),
              stageGroups.permits(window: identity, in: context), visibleWindows[identity] != nil else { return false }
        return setFrameUnchecked(frame, for: id)
    }

    private func setFrameUnchecked(_ frame: CGRect, for id: CGWindowID) -> Bool {
        if let item = elements[id] {
            setFrame(frame, on: item)
            return true
        }
        guard let app = application(for: id) else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        for item in (value as? [AXUIElement] ?? []) {
            var number: CFTypeRef?
            AXUIElementCopyAttributeValue(item, axWindowNumberAttribute as CFString, &number)
            guard (number as? NSNumber)?.uint32Value == id else { continue }
            elements[id] = item
            setFrame(frame, on: item)
            return true
        }
        return false
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
        super.init(contentRect: NSRect(x: x - 13, y: y - 13, width: 26, height: 26),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configureAsOverlay()
        contentView = GripView()
    }
    func show() { contentView?.needsDisplay = true; orderFrontRegardless() }
}

final class SnapPreviewPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configureAsOverlay()
        hasShadow = false
        contentView = SnapPreviewView()
    }

    func show(frame: CGRect) {
        setFrame(frame, display: true)
        contentView?.needsDisplay = true
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
        super.init(contentRect: NSRect(x: 0, y: 0, width: 220, height: 92),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configureAsOverlay()
        hasShadow = true
        contentView = previewView
    }

    func show(on screen: NSScreen, current: [(CGFloat, CGFloat)], future: (CGFloat, CGFloat)?) {
        setFrameOrigin(OverlayGeometry.layoutWidgetOrigin(panelSize: frame.size, visibleFrame: screen.visibleFrame))
        previewView.current = current
        previewView.future = future
        previewView.needsDisplay = true
        orderFrontRegardless()
    }
}

private extension NSPanel {
    func configureAsOverlay() {
        isFloatingPanel = true
        level = .modalPanel
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
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

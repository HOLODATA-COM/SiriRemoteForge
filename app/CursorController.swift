//
//  CursorController.swift
//  HyperVibe
//
//  Controls cursor movement and clicking using CGEvent
//

import CoreGraphics
import CoreFoundation
import Foundation
import AppKit

class CursorController {
    var isDragging: Bool = false
    var isClickActive: Bool = false

    // Sub-pixel accumulator: a slow, precise move can be <1px/frame; accumulate the fraction so it
    // adds up to whole-pixel steps (true ~1px control) instead of being lost to rounding. The delta
    // passed in is already fully speed/accel-scaled by TouchHandler — no extra scaling here.
    private var accumX: CGFloat = 0
    private var accumY: CGFloat = 0

    /// Reset the sub-pixel accumulator (call at the start of each touch so a stale fraction from the
    /// previous gesture doesn't carry over).
    func resetMoveAccumulator() { accumX = 0; accumY = 0 }

    // Cached display rects, in the same global top-left-origin space as event locations. Read from
    // the multitouch callback thread, refreshed on the main thread when displays change.
    private let displayLock = NSLock()
    private var displayBounds: [CGRect] = []
    private var screenObserver: NSObjectProtocol?

    init() {
        refreshDisplayBounds()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.refreshDisplayBounds() }
    }

    deinit {
        if let observer = screenObserver { NotificationCenter.default.removeObserver(observer) }
    }

    private func refreshDisplayBounds() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return }
        let rects = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
        displayLock.lock()
        displayBounds = Array(rects)
        displayLock.unlock()
    }

    /// Keep a move target on a real display.
    ///
    /// `CGEvent(source: nil).location` reports the last position we POSTED, not where the cursor
    /// actually came to rest. macOS clamps the cursor to the desktop, but that clamp is invisible
    /// from here — so pushing into an edge walks the reported position further and further
    /// off-screen, and moving back has to pay off that invisible debt before anything visibly
    /// moves. Clamping the target ourselves keeps the reported position and the real cursor in
    /// agreement, so an edge stops the cursor dead and it leaves the edge on the very first move.
    ///
    /// A target that already lands on some display is left alone — that is how the cursor crosses
    /// between monitors. Only a target on no display at all gets pulled back, into whichever
    /// display the cursor is currently on.
    private func clampToDisplays(_ target: CGPoint, from current: CGPoint) -> CGPoint {
        displayLock.lock()
        let rects = displayBounds
        displayLock.unlock()
        guard !rects.isEmpty else { return target }
        if rects.contains(where: { $0.contains(target) }) { return target }

        let home = rects.first(where: { $0.contains(current) }) ?? rects.min {
            hypot(current.x - $0.midX, current.y - $0.midY)
                < hypot(current.x - $1.midX, current.y - $1.midY)
        }
        guard let r = home else { return target }
        // maxX/maxY are exclusive: a point exactly on them is already off the display.
        return CGPoint(x: min(max(target.x, r.minX), r.maxX - 1),
                       y: min(max(target.y, r.minY), r.maxY - 1))
    }

    // Double/triple-click tracking: macOS only recognizes a multi-click when the click-state
    // field is 2/3 on clicks within the system double-click interval.
    private var lastClickTime: TimeInterval = 0
    private var clickState: Int = 1

    // MARK: - Cursor Movement

    /// Move the cursor by an already-scaled delta (pixels). Thread-safe: reads the position and
    /// posts the move via CoreGraphics only, so it can run directly on the multitouch callback
    /// thread with NO main-thread hop (that hop was the main source of cursor stutter). Sub-pixel
    /// deltas accumulate into whole-pixel steps, and `clampToDisplays` keeps the target on-screen.
    func moveCursor(deltaX: CGFloat, deltaY: CGFloat) {
        accumX += deltaX
        accumY += deltaY
        let moveX = accumX.rounded(.towardZero)
        let moveY = accumY.rounded(.towardZero)
        guard moveX != 0 || moveY != 0 else { return }
        accumX -= moveX
        accumY -= moveY

        // Current position in global Quartz coords (top-left origin).
        let pos = CGEvent(source: nil)?.location ?? .zero
        let target = clampToDisplays(CGPoint(x: pos.x + moveX, y: pos.y + moveY), from: pos)

        let eventType: CGEventType = isDragging ? .leftMouseDragged : .mouseMoved
        guard let event = CGEvent(mouseEventSource: nil, mouseType: eventType,
                                  mouseCursorPosition: target, mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }

    func performClick() {
        let currentPosition = CGEvent(source: nil)?.location ?? .zero

        // Track click count so consecutive clicks within the system double-click interval register
        // as a double (2) / triple (3) click instead of separate single clicks.
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastClickTime <= NSEvent.doubleClickInterval {
            clickState = min(clickState + 1, 3)
        } else {
            clickState = 1
        }
        lastClickTime = now

        // Mouse down
        guard let downEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: currentPosition, mouseButton: .left) else {
            return
        }
        downEvent.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        downEvent.post(tap: CGEventTapLocation.cghidEventTap)

        // Small delay
        usleep(10000) // 10ms

        // Mouse up
        guard let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: currentPosition, mouseButton: .left) else {
            return
        }
        upEvent.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        upEvent.post(tap: CGEventTapLocation.cghidEventTap)
    }

    func mouseDown() {
        let currentPosition = CGEvent(source: nil)?.location ?? .zero
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: currentPosition, mouseButton: .left) else {
            return
        }
        event.post(tap: CGEventTapLocation.cghidEventTap)
    }

    func mouseUp() {
        let currentPosition = CGEvent(source: nil)?.location ?? .zero
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: currentPosition, mouseButton: .left) else {
            return
        }
        event.post(tap: CGEventTapLocation.cghidEventTap)
    }

    func scroll(deltaX: Int32, deltaY: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0) else {
            return
        }
        event.post(tap: CGEventTapLocation.cghidEventTap)
    }
}

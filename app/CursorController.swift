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

    // Double/triple-click tracking: macOS only recognizes a multi-click when the click-state
    // field is 2/3 on clicks within the system double-click interval.
    private var lastClickTime: TimeInterval = 0
    private var clickState: Int = 1

    // MARK: - Cursor Movement

    /// Move the cursor by an already-scaled delta (pixels). Thread-safe: reads the position and
    /// posts the move via CoreGraphics only, so it can run directly on the multitouch callback
    /// thread with NO main-thread hop (that hop was the main source of cursor stutter). Sub-pixel
    /// deltas accumulate into whole-pixel steps, and macOS clamps the target to the visible area.
    func moveCursor(deltaX: CGFloat, deltaY: CGFloat) {
        accumX += deltaX
        accumY += deltaY
        let moveX = accumX.rounded(.towardZero)
        let moveY = accumY.rounded(.towardZero)
        guard moveX != 0 || moveY != 0 else { return }
        accumX -= moveX
        accumY -= moveY

        // Current position in global Quartz coords (top-left origin). Reading the live position each
        // frame lets macOS's own edge-clamping keep us on-screen with no drift.
        let pos = CGEvent(source: nil)?.location ?? .zero
        let target = CGPoint(x: pos.x + moveX, y: pos.y + moveY)

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

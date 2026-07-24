//
//  TouchSnapshot.swift
//  HyperVibe
//
//  A plain copy of one MTTouch, taken on the multitouch callback thread so the C struct never
//  escapes it. Carries every field the framework populates, including the ones the gesture code
//  ignores — the point of the monitor is to see what is actually there.
//

import Foundation

struct TouchSnapshot: Identifiable {
    let id: Int32              // pathIndex — stable for the life of one contact
    let fingerID: Int32
    let state: MTTouchState
    let normalized: CGPoint
    let velocity: CGPoint
    let absoluteMM: CGPoint
    let zTotal: Float
    let zDensity: Float
    let majorAxis: Float
    let minorAxis: Float
    let angle: Float

    init(_ t: MTTouch) {
        id = t.pathIndex
        fingerID = t.fingerID
        state = t.state
        normalized = CGPoint(x: CGFloat(t.normalizedVector.position.x),
                             y: CGFloat(t.normalizedVector.position.y))
        velocity = CGPoint(x: CGFloat(t.normalizedVector.velocity.x),
                           y: CGFloat(t.normalizedVector.velocity.y))
        absoluteMM = CGPoint(x: CGFloat(t.absoluteVector.position.x),
                             y: CGFloat(t.absoluteVector.position.y))
        zTotal = t.zTotal
        zDensity = t.zDensity
        majorAxis = t.majorAxis
        minorAxis = t.minorAxis
        angle = t.angle
    }

    var stateName: String {
        switch state {
        case MTTouchStateNotTracking:  return "NotTracking"
        case MTTouchStateStartInRange: return "StartInRange"
        case MTTouchStateHoverInRange: return "HoverInRange"
        case MTTouchStateMakeTouch:    return "MakeTouch"
        case MTTouchStateTouching:     return "Touching"
        case MTTouchStateBreakTouch:   return "BreakTouch"
        case MTTouchStateLingerInRange: return "Linger"
        case MTTouchStateOutOfRange:   return "OutOfRange"
        default: return "state \(state.rawValue)"
        }
    }

    /// True while the finger is near the surface but not on it — the hover band, measured at
    /// roughly z 0.08…0.48 with contact starting around 0.5.
    var isHovering: Bool {
        state == MTTouchStateHoverInRange || state == MTTouchStateStartInRange
            || state == MTTouchStateLingerInRange
    }
}

// Replay remote touch frames through the production callback. Collect output without posting
// system input or opening a physical device.
import AppKit

enum RemoteInputHandler {
    static var isInputGuarded = false
    static var isTouchGuarded = false
}
enum Brightness { static func restoreIfDimmed() {} }
func rmDebug(_ message: String) {}
enum ContinuousScrollPhase { case began, changed, ended }
final class CursorController {
    var isClickActive = false, isDragging = false
    var wheels = 0, moves = 0, clicks = 0
    var phases: [ContinuousScrollPhase] = []
    func resetMoveAccumulator() {}
    func performClick() { clicks += 1 }
    func moveCursor(deltaX: CGFloat, deltaY: CGFloat) { moves += 1 }
    func scroll(deltaX: Int32, deltaY: Int32) { wheels += 1 }
    func scrollContinuousHorizontal(deltaX: Int32, phase: ContinuousScrollPhase) { phases.append(phase) }
}

let cursor = CursorController()
let handler = TouchHandler(cursorController: cursor)
handler.tryReconnectTrackpad()
var time = 0.0
func send(_ contacts: [MTTouch], from handle: Int32 = 0) {
    time += 0.016
    var contacts = contacts
    contacts.withUnsafeMutableBufferPointer { emitFrame(handle, $0.baseAddress, $0.count, time) }
}
func touch(_ id: Int32, _ state: MTTouchState, _ x: Double, _ y: Double) -> MTTouch {
    var t = MTTouch()
    t.fingerID = id
    t.pathIndex = id
    t.state = state
    t.normalizedVector.position = MTPoint(x: Float(x), y: Float(y))
    return t
}
func ring(_ id: Int32, from handle: Int32 = 0, firstState: MTTouchState = MTTouchStateMakeTouch) {
    for frame in 0...48 {
        let angle = Double(frame) * .pi / 24
        send([touch(id, frame == 0 ? firstState : MTTouchStateTouching,
                    0.5 + 0.45 * cos(angle), 0.5 + 0.45 * sin(angle))], from: handle)
    }
}
func drain() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
func check(_ passed: Bool, _ message: String) {
    precondition(passed, message)
    print("PASS \(message)")
}

let baseline = handler.circularMotionRevision
send([touch(1, MTTouchStateMakeTouch, 0.5, 0.5)])
ring(1, firstState: MTTouchStateTouching)
send([])
drain()
check(cursor.wheels == 0 && cursor.moves > 0 && baseline == handler.circularMotionRevision,
      "a continuous centre-to-edge stroke stays a pointer gesture")

send([touch(2, MTTouchStateMakeTouch, 0.5, 0.5)])
ring(3, firstState: MTTouchStateTouching)
check(handler.circularMotionRevision != baseline, "ring use is visible to layer release before enqueued scroll output")
send([])
drain()
check(cursor.wheels > 0 && cursor.clicks == 0, "a new contact after a missing centre lift can immediately scroll")

handler.setCircularScrollAxis(.horizontal)
ring(4)
RemoteInputHandler.isTouchGuarded = true
send([])
RemoteInputHandler.isTouchGuarded = false
ring(5)
// Missing lift, same numeric contact ID, explicit MakeTouch from the next contact.
ring(5)
send([])
drain()
check(cursor.phases.filter { $0 != .changed } == [.began, .ended, .began, .ended, .began, .ended],
      "guarded lift and reused contact ID each close exactly one horizontal phase")

var twoFingerTaps = 0
handler.onTwoFingerTap = { twoFingerTaps += 1 }
let first = touch(6, MTTouchStateTouching, 0.50, 0.50)
let second = touch(7, MTTouchStateTouching, 0.51, 0.51)
send([first]); send([first, second]); send([second]); send([])
drain()
check(twoFingerTaps == 1 && cursor.clicks == 0, "lifting one of two fingers preserves the two-finger tap")

refreshFirstWrapper()
handler.tryReconnectTrackpad()
check(startCount(0) == 1 && startCount(1) == 0 && stopCount(0) == 0, "a fresh wrapper for the same service keeps its callbacks")
ring(8)
replaceFirstService()
failNextStart()
handler.tryReconnectTrackpad()
handler.tryReconnectTrackpad()
check(stopCount(0) == 1 && startCount(2) == 2, "same-ID replacement detaches once and retries a failed start")
check(startCount(3) == 1 && stopCount(3) == 0, "reconnecting one remote leaves the other attached")
cursor.phases = []
drain()
check(cursor.phases.last == .ended, "retiring an active service closes its horizontal scroll")
cursor.phases = []
ring(9, from: 2)
send([touch(10, MTTouchStateBreakTouch, 0.5, 0.5)], from: 3)
ring(11, from: 0)
send([], from: 0)
send([], from: 2)
drain()
check(cursor.phases.filter { $0 != .changed } == [.began, .ended] && cursor.clicks == 0,
      "the replacement scrolls and ignores late callbacks from other surfaces")
handler.stop()

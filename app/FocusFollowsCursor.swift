//
//  FocusFollowsCursor.swift
//  HyperVibe
//
//  Focus the app the cursor is over, so a keystroke binding lands where you are pointing rather
//  than wherever you last clicked. Scrolling a browser on another display and then pressing a
//  button used to send that shortcut to the app you left behind.
//
//  RESTRICTED TO APPS THAT ALREADY FILL A DISPLAY, deliberately. macOS has no public way to give an
//  app keyboard focus without also raising it, so an unrestricted focus-follows-mouse would reshuffle
//  the window stack every time the pointer crossed something — unusable while working normally. An
//  app already covering a whole display has nothing to disturb: raising it changes nothing visible.
//  That is what makes this safe to run continuously.
//
//  "Fills a display" rather than "is fullscreen", on purpose. Native fullscreen is the obvious case,
//  but a maximised window — menu bar still showing — is just as safe and far more common; testing
//  for literal fullscreen bounds matched none of the author's own windows.
//
//  The test is a COVERAGE FRACTION rather than an exact match, for two measured reasons. Chrome (and
//  others) split their tab strip and content into separate CGWindows that only cover the display
//  taken together, so the app's windows are unioned. And `NSScreen.visibleFrame` cannot be used as
//  the target: on a display that is not currently active macOS reports it equal to the full frame,
//  reserving no menu bar, even though windows there are still laid out below one — so an exact-cover
//  test failed on exactly the kind of window it was meant to accept.
//
//  Consequence worth knowing: a small or partially-covering window is never focused this way. That
//  is the point, not a gap.
//

import AppKit
import ApplicationServices
import QuartzCore

final class FocusFollowsCursor {

    /// Off by default — this changes which app receives input, which no one should discover by
    /// surprise. Enabled from config (`settings.focusFollowsCursor`).
    var enabled: Bool = false {
        didSet {
            guard enabled != oldValue else { return }
            enabled ? start() : stop()
        }
    }

    private var timer: Timer?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// The last resting point already acted on. While the cursor sits still this keeps the whole
    /// path — including the window-list query — from running again, so idling costs nothing.
    private var handledPoint: CGPoint?
    private var restingPoint: CGPoint = .zero
    private var restingSince: CFTimeInterval = 0

    /// How still, and for how long, the cursor must be before its app is focused. Without a dwell,
    /// every window the pointer was dragged across would be focused in turn.
    private let dwell: TimeInterval = 0.15
    private let stillRadius: CGFloat = 4

    /// How much of a display an app's windows must cover before focusing it counts as harmless.
    /// A judgement call: high enough that side-by-side windows (~50% each) are refused, low enough
    /// to absorb the menu bar and the Dock. Measured on real windows: a maximised Warp covers 99%,
    /// Chrome 98%, Music 97%, and a display with a Dock still clears 93%.
    private let minCoverage: CGFloat = 0.9

    deinit { stop() }

    // MARK: - Polling

    private func start() {
        stop()
        // 20 Hz: at a 0.15s dwell a 10 Hz poll leaves only one or two ticks inside the window, so
        // the delay you actually feel swings by a whole tick depending on where the cursor stopped.
        // The early-outs below mean a still cursor never reaches the expensive part either way.
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        handledPoint = nil
    }

    private func tick() {
        let point = CGEvent(source: nil)?.location ?? .zero
        let now = CACurrentMediaTime()

        // Still moving → restart the dwell clock.
        if hypot(point.x - restingPoint.x, point.y - restingPoint.y) > stillRadius {
            restingPoint = point
            restingSince = now
            return
        }
        guard now - restingSince >= dwell else { return }
        if let handled = handledPoint,
           hypot(point.x - handled.x, point.y - handled.y) <= stillRadius { return }

        handledPoint = point
        focus(at: point)
    }

    // MARK: - Focusing

    private func focus(at point: CGPoint) {
        guard let pid = fillingAppPID(under: point), pid != ownPID else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else { return }
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular else { return }

        // Measured: this returns true and works from this background accessory app. But macOS's
        // cooperative activation rules can refuse it (another app holding activation), and the
        // refusal is silent apart from the return value — so fall back to the Accessibility route,
        // which this app already has permission for since it synthesizes input anyway. The log line
        // records which path ran, so a change in macOS behaviour shows up rather than going quiet.
        let cooperative = app.activate(options: [])
        let name = app.localizedName ?? "pid \(pid)"
        if cooperative {
            rmDebug("🎯 focus follows cursor → \(name) (activate)")
            return
        }
        let axApp = AXUIElementCreateApplication(pid)
        let result = AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString,
                                                  kCFBooleanTrue)
        rmDebug("🎯 focus follows cursor → \(name) (activate=false, AX=\(result.rawValue))")
    }

    /// PID of the app under `point`, but only if that app's windows already cover essentially the
    /// whole display the point is on. Nil otherwise — including when something small sits on top.
    private func fillingAppPID(under point: CGPoint) -> pid_t? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]],
              let display = displayBounds().first(where: { $0.contains(point) }),
              display.width > 0, display.height > 0
        else { return nil }

        let normal = windows.compactMap { window -> (pid: pid_t, bounds: CGRect)? in
            guard (window[kCGWindowLayer as String] as? Int) == 0,           // ordinary app windows
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict)
            else { return nil }
            return (pid, bounds)
        }

        // Front-to-back order, so the first window containing the point is the one a click would
        // hit. Whatever owns it is the only candidate — never reach past it to something behind.
        guard let owner = normal.first(where: { $0.bounds.contains(point) })?.pid else { return nil }

        // Union the owner's windows ON THIS DISPLAY, then clip to the display so a window hanging
        // off the edge cannot inflate its own coverage.
        let mine = normal.filter { $0.pid == owner && $0.bounds.intersects(display) }
        guard var union = mine.first?.bounds else { return nil }
        for window in mine.dropFirst() { union = union.union(window.bounds) }
        let covered = union.intersection(display)

        let fraction = (covered.width * covered.height) / (display.width * display.height)
        return fraction >= minCoverage ? owner : nil
    }

    private func displayBounds() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
}

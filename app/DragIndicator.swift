//
//  DragIndicator.swift
//  HyperVibe
//
//  A small badge pinned beside the pointer for as long as sticky drag is carrying something.
//
//  Sticky drag survives releasing the button and lifting the finger, which means that without this
//  there is no evidence at all that the mouse is still held down — the hold card has long since
//  faded. Finder answers the same problem the same way, with a badge attached to the cursor.
//
//  Not done by swapping NSCursor: the cursor belongs to whichever app is under it, and that app
//  resets it constantly, so a background process cannot hold a cursor shape reliably. A borderless
//  click-through window following the pointer is the only thing that stays put.
//

import AppKit
import QuartzCore

final class DragIndicator {

    /// Offset from the hot spot, down and to the right, where a drag badge conventionally sits and
    /// where it cannot hide what is being pointed at.
    private let offset = CGPoint(x: 15, y: -20)
    private let side: CGFloat = 24

    private var window: NSWindow?
    private var followTimer: Timer?

    deinit { hide() }

    func show() {
        onMain { [weak self] in
            guard let self = self else { return }
            self.ensureWindow()
            self.reposition()
            self.window?.alphaValue = 0
            self.window?.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                self.window?.animator().alphaValue = 1
            }
            self.startFollowing()
        }
    }

    func hide() {
        onMain { [weak self] in
            guard let self = self else { return }
            self.followTimer?.invalidate()
            self.followTimer = nil
            guard let window = self.window, window.isVisible else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                window.animator().alphaValue = 0
            }, completionHandler: { window.orderOut(nil) })
        }
    }

    // MARK: - Following

    private func startFollowing() {
        followTimer?.invalidate()
        // 60 Hz. The pointer also moves from the real trackpad, not only from us, so this polls the
        // live location rather than piggy-backing on our own cursor writes.
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.reposition() }
        RunLoop.main.add(t, forMode: .common)
        followTimer = t
    }

    private func reposition() {
        guard let window = window, let screen = NSScreen.screens.first else { return }
        // Event locations are Quartz (top-left of the primary display); windows are AppKit.
        let p = CGEvent(source: nil)?.location ?? .zero
        let flipped = screen.frame.maxY - p.y
        window.setFrameOrigin(NSPoint(x: p.x + offset.x, y: flipped + offset.y))
    }

    // MARK: - Window

    private func ensureWindow() {
        guard window == nil else { return }
        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        let win = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let container = NSView(frame: rect)
        container.wantsLayer = true
        // Accent-filled circle so it reads as "the app is holding this", against any backdrop.
        let disc = CALayer()
        disc.frame = container.bounds
        disc.cornerRadius = side / 2
        disc.backgroundColor = NSColor.controlAccentColor.cgColor
        disc.shadowColor = NSColor.black.cgColor
        disc.shadowOpacity = 0.28
        disc.shadowRadius = 3
        disc.shadowOffset = CGSize(width: 0, height: -1)
        container.layer?.addSublayer(disc)

        let cfg = NSImage.SymbolConfiguration(pointSize: side * 0.55, weight: .semibold)
        let icon = NSImageView(frame: rect.insetBy(dx: 4, dy: 4))
        icon.image = NSImage(systemSymbolName: "hand.draw.fill", accessibilityDescription: "Dragging")?
            .withSymbolConfiguration(cfg)
        icon.contentTintColor = .white
        icon.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(icon)

        win.contentView = container
        window = win
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

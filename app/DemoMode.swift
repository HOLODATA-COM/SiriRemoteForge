//
//  DemoMode.swift
//  HyperVibe
//
//  A remote-only floating visualiser driven by the same deduplicated HID edges and raw
//  MultitouchSupport frames as normal operation. It never activates HyperVibe or intercepts input.
//

import AppKit
import SwiftUI

// MARK: - Live model

final class DemoModeModel: ObservableObject {
    @Published private(set) var pressedKeys: Set<String> = []
    @Published private(set) var touchPoints: [RemoteTouchPoint] = []
    @Published private(set) var connected = false

    /// More than one HID usage can represent one face control (`menu` and `back`, for example).
    /// Retaining raw ground truth prevents one usage's release from clearing another usage's press.
    private var rawPressed: Set<String> = []

    func setConnected(_ value: Bool) {
        withAnimation(.easeOut(duration: 0.18)) {
            connected = value
            if !value { resetTransient() }
        }
    }

    func setPhysicalButton(_ rawName: String, pressed: Bool) {
        withAnimation(.easeOut(duration: 0.16)) {
            if pressed { rawPressed.insert(rawName) }
            else { rawPressed.remove(rawName) }
            pressedKeys = Set(rawPressed.compactMap { Self.visualKey(for: $0) })
        }
    }

    func ingest(_ snapshots: [TouchSnapshot]) {
        let next = snapshots.compactMap { snapshot -> RemoteTouchPoint? in
            switch snapshot.state {
            case MTTouchStateMakeTouch, MTTouchStateTouching,
                 MTTouchStateStartInRange, MTTouchStateHoverInRange,
                 MTTouchStateLingerInRange:
                return RemoteTouchPoint(
                    id: snapshot.id,
                    normalized: snapshot.normalized,
                    isHovering: snapshot.isHovering,
                    strength: CGFloat(snapshot.zTotal)
                )
            default:
                return nil
            }
        }

        // Arrival/departure gets a short material transition; live positions do not interpolate,
        // otherwise the contact marker visibly trails behind the presenter's finger.
        if next.isEmpty != touchPoints.isEmpty {
            withAnimation(.easeOut(duration: 0.12)) { touchPoints = next }
        } else {
            touchPoints = next
        }
    }

    func resetTransient() {
        rawPressed.removeAll()
        pressedKeys.removeAll()
        touchPoints.removeAll()
    }

    static func visualKey(for rawName: String) -> String? {
        switch rawName {
        case "menu", "back":        return "button.menu"
        case "ringUp":               return "ring.up"
        case "ringDown":             return "ring.down"
        case "ringLeft":             return "ring.left"
        case "ringRight":            return "ring.right"
        case "siri":                 return "button.siri"
        case "tv":                   return "button.tv"
        case "select":               return "select"
        case "playPause", "nextTrack", "prevTrack":
            return "button.playPause"
        case "volumeUp":             return "button.volumeUp"
        case "volumeDown":           return "button.volumeDown"
        case "power":                return "button.power"
        case "mute":                 return "button.mute"
        default:                      return nil
        }
    }
}

// MARK: - Remote-only SwiftUI surface

private struct DemoRemoteView: View {
    @ObservedObject var model: DemoModeModel
    @State private var noSelection: String? = nil

    var body: some View {
        GeometryReader { geometry in
            // Scale the existing 150×512 remote uniformly. The fixed breathing room contains its
            // authored body shadow, so resizing never crops the silhouette or deforms its geometry.
            let scale = max(0.1, min((geometry.size.width - 24) / 150,
                                     (geometry.size.height - 38) / 512))
            RemoteView(highlightedKey: $noSelection,
                       pressedKeys: model.pressedKeys,
                       touchPoints: model.touchPoints,
                       showsOuterShadow: false,
                       showsOuterStroke: false)
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(Color.clear)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L("Live Siri Remote"))
        }
    }
}

// MARK: - Floating window

final class DemoModeWindowController: NSObject, NSWindowDelegate {
    private final class DemoPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private enum SizePreset: Int, CaseIterable {
        case small, medium, large

        var width: CGFloat {
            switch self {
            case .small:  return 110
            case .medium: return 156
            case .large:  return 234
            }
        }

        var title: String {
            switch self {
            case .small:  return L("Small")
            case .medium: return L("Medium")
            case .large:  return L("Large")
            }
        }
    }

    /// An invisible interaction layer sits above SwiftUI. The remote remains the only visible
    /// object: its centre drags the window, while any corner resizes it without changing aspect.
    private final class DragSurfaceView: NSView {
        private enum Corner { case bottomLeft, bottomRight, topLeft, topRight }
        private enum DragMode { case move, resize(Corner) }

        private let minimumSize: NSSize
        private let maximumSize: NSSize
        private let resizeZone: CGFloat = 18
        private var mode: DragMode?
        private var startMouse = NSPoint.zero
        private var startFrame = NSRect.zero
        var currentWidth: (() -> CGFloat)?
        var onSelectSize: ((SizePreset) -> Void)?
        var onClose: (() -> Void)?

        init(frame frameRect: NSRect, minimumSize: NSSize, maximumSize: NSSize) {
            self.minimumSize = minimumSize
            self.maximumSize = maximumSize
            super.init(frame: frameRect)
        }

        required init?(coder: NSCoder) { nil }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
            addCursorRect(NSRect(x: 0, y: 0, width: resizeZone, height: resizeZone),
                          cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: bounds.maxX - resizeZone, y: 0,
                                 width: resizeZone, height: resizeZone),
                          cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: 0, y: bounds.maxY - resizeZone,
                                 width: resizeZone, height: resizeZone),
                          cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: bounds.maxX - resizeZone,
                                 y: bounds.maxY - resizeZone,
                                 width: resizeZone, height: resizeZone),
                          cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            guard let window = window else { return }
            startMouse = NSEvent.mouseLocation
            startFrame = window.frame
            mode = corner(at: convert(event.locationInWindow, from: nil)).map(DragMode.resize)
                ?? .move
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window = window, let mode = mode else { return }
            let mouse = NSEvent.mouseLocation
            switch mode {
            case .move:
                let delta = NSPoint(x: mouse.x - startMouse.x, y: mouse.y - startMouse.y)
                window.setFrameOrigin(NSPoint(x: startFrame.minX + delta.x,
                                              y: startFrame.minY + delta.y))
            case .resize(let corner):
                resize(window: window, corner: corner, mouse: mouse)
            }
        }

        override func mouseUp(with event: NSEvent) { mode = nil }

        override func rightMouseDown(with event: NSEvent) {
            NSMenu.popUpContextMenu(makeContextMenu(), with: event, for: self)
        }

        private func makeContextMenu() -> NSMenu {
            let menu = NSMenu()
            let sizeItem = NSMenuItem(title: L("Size"), action: nil, keyEquivalent: "")
            let sizeMenu = NSMenu(title: L("Size"))
            let width = currentWidth?() ?? 0
            for preset in SizePreset.allCases {
                let item = NSMenuItem(title: preset.title,
                                      action: #selector(selectSize(_:)), keyEquivalent: "")
                item.target = self
                item.tag = preset.rawValue
                item.state = abs(width - preset.width) < 1 ? .on : .off
                sizeMenu.addItem(item)
            }
            sizeItem.submenu = sizeMenu
            menu.addItem(sizeItem)
            menu.addItem(.separator())

            let closeItem = NSMenuItem(title: L("Close Demo Remote"),
                                       action: #selector(closeDemoRemote), keyEquivalent: "")
            closeItem.target = self
            closeItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
            menu.addItem(closeItem)
            return menu
        }

        @objc private func selectSize(_ sender: NSMenuItem) {
            guard let preset = SizePreset(rawValue: sender.tag) else { return }
            onSelectSize?(preset)
        }

        @objc private func closeDemoRemote() { onClose?() }

        private func corner(at point: NSPoint) -> Corner? {
            let left = point.x <= resizeZone
            let right = point.x >= bounds.maxX - resizeZone
            let bottom = point.y <= resizeZone
            let top = point.y >= bounds.maxY - resizeZone
            if left && bottom { return .bottomLeft }
            if right && bottom { return .bottomRight }
            if left && top { return .topLeft }
            if right && top { return .topRight }
            return nil
        }

        private func resize(window: NSWindow, corner: Corner, mouse: NSPoint) {
            let aspect = startFrame.width / startFrame.height
            let anchor: NSPoint
            switch corner {
            case .bottomLeft:  anchor = NSPoint(x: startFrame.maxX, y: startFrame.maxY)
            case .bottomRight: anchor = NSPoint(x: startFrame.minX, y: startFrame.maxY)
            case .topLeft:     anchor = NSPoint(x: startFrame.maxX, y: startFrame.minY)
            case .topRight:    anchor = NSPoint(x: startFrame.minX, y: startFrame.minY)
            }

            let widthFromX = abs(mouse.x - anchor.x)
            let widthFromY = abs(mouse.y - anchor.y) * aspect
            let requestedWidth = abs(widthFromX - startFrame.width)
                >= abs(widthFromY - startFrame.width) ? widthFromX : widthFromY
            let width = min(max(requestedWidth, minimumSize.width), maximumSize.width)
            let height = width / aspect
            let origin: NSPoint
            switch corner {
            case .bottomLeft:
                origin = NSPoint(x: anchor.x - width, y: anchor.y - height)
            case .bottomRight:
                origin = NSPoint(x: anchor.x, y: anchor.y - height)
            case .topLeft:
                origin = NSPoint(x: anchor.x - width, y: anchor.y)
            case .topRight:
                origin = anchor
            }
            window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)),
                            display: true)
        }
    }

    private enum DefaultsKey {
        static let displayID = "demoRemote.displayID"
        static let normalizedX = "demoRemote.normalizedX"
        static let normalizedY = "demoRemote.normalizedY"
        static let width = "demoRemote.width"
    }

    private let defaultWindowSize = NSSize(width: 156, height: 500)
    private let minimumWindowSize = NSSize(width: 100, height: 320)
    private let maximumWindowSize = NSSize(width: 280, height: 898)
    private let defaults: UserDefaults
    private(set) var model = DemoModeModel()
    private var panel: DemoPanel?
    private var observers: [NSObjectProtocol] = []
    private var moveGeneration = 0
    private var isMovingProgrammatically = false

    /// AppDelegate uses this to attach raw touch frames only while the floating remote is visible.
    var onVisibilityChanged: ((Bool) -> Void)?
    /// Menu/UI/config remain the source of truth when the window's own context menu closes it.
    var onEnabledChangeRequested: ((Bool) -> Void)?

    var isVisible: Bool { panel?.isVisible == true }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.screenParametersChanged() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.activeSpaceChanged() })
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    func toggle() { isVisible ? hide() : show() }

    func setVisible(_ visible: Bool) { visible ? show() : hide() }

    func show() {
        if panel == nil { panel = makePanel() }
        guard let panel = panel else { return }
        let wasVisible = panel.isVisible
        if !wasVisible {
            model.resetTransient()
            restorePosition()
        } else {
            ensureReachable()
        }
        panel.orderFrontRegardless()
        if !wasVisible { onVisibilityChanged?(true) }
    }

    func hide() {
        guard let panel = panel, panel.isVisible else { return }
        panel.orderOut(nil)
        model.resetTransient()
        onVisibilityChanged?(false)
    }

    func setConnected(_ connected: Bool) {
        onMain { [weak self] in self?.model.setConnected(connected) }
    }

    func setPhysicalButton(_ rawName: String, pressed: Bool) {
        onMain { [weak self] in self?.model.setPhysicalButton(rawName, pressed: pressed) }
    }

    func resetPhysicalButtons() {
        onMain { [weak self] in self?.model.resetTransient() }
    }

    func ingest(_ snapshots: [TouchSnapshot]) {
        onMain { [weak self] in self?.model.ingest(snapshots) }
    }

    func windowDidMove(_ notification: Notification) {
        guard isVisible, !isMovingProgrammatically else { return }
        scheduleMoveSettlement()
    }

    func windowDidResize(_ notification: Notification) {
        guard isVisible, !isMovingProgrammatically else { return }
        scheduleMoveSettlement()
    }

    private func makePanel() -> DemoPanel {
        let panel = DemoPanel(contentRect: NSRect(origin: .zero, size: defaultWindowSize),
                              styleMask: [.borderless, .nonactivatingPanel, .resizable],
                              backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = minimumWindowSize
        panel.contentMaxSize = maximumWindowSize
        panel.contentAspectRatio = defaultWindowSize
        panel.delegate = self

        let root = NSView(frame: NSRect(origin: .zero, size: defaultWindowSize))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        root.layer?.isOpaque = false
        root.layer?.masksToBounds = false

        let hosting = NSHostingView(rootView: DemoRemoteView(model: model))
        hosting.frame = root.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        hosting.layer?.masksToBounds = false
        root.addSubview(hosting)

        let dragSurface = DragSurfaceView(frame: root.bounds,
                                          minimumSize: minimumWindowSize,
                                          maximumSize: maximumWindowSize)
        dragSurface.autoresizingMask = [.width, .height]
        dragSurface.currentWidth = { [weak panel] in panel?.frame.width ?? 0 }
        dragSurface.onSelectSize = { [weak self] preset in self?.apply(preset: preset) }
        dragSurface.onClose = { [weak self] in
            self?.onEnabledChangeRequested?(false)
            self?.hide()
        }
        root.addSubview(dragSurface)
        panel.contentView = root
        return panel
    }

    // MARK: Position persistence / display recovery

    private func apply(preset: SizePreset) {
        guard let panel = panel else { return }
        let aspect = defaultWindowSize.width / defaultWindowSize.height
        let size = NSSize(width: preset.width, height: preset.width / aspect)
        let old = panel.frame
        var origin = NSPoint(x: old.midX - size.width / 2, y: old.midY - size.height / 2)
        if let screen = bestScreen(for: old) {
            origin = clampedOrigin(origin, size: size, in: screen.visibleFrame)
        }

        moveGeneration += 1
        isMovingProgrammatically = true
        let target = NSRect(origin: origin, size: size)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.isMovingProgrammatically = false
            if let screen = self.bestScreen(for: panel.frame) { self.savePosition(on: screen) }
        }
    }

    private func scheduleMoveSettlement() {
        moveGeneration += 1
        let generation = moveGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            guard let self = self, self.isVisible, self.moveGeneration == generation else { return }
            if NSEvent.pressedMouseButtons & 1 != 0 {
                self.scheduleMoveSettlement()
                return
            }
            self.settleAndSavePosition()
        }
    }

    private func settleAndSavePosition() {
        guard let panel = panel, let screen = bestScreen(for: panel.frame) else { return }
        let origin = clampedOrigin(panel.frame.origin, size: panel.frame.size,
                                   in: screen.visibleFrame)
        if origin != panel.frame.origin { setFrameOrigin(origin) }
        savePosition(on: screen)
    }

    private func restorePosition() {
        guard panel != nil, !NSScreen.screens.isEmpty else { return }
        let storedID = defaults.object(forKey: DefaultsKey.displayID) == nil
            ? nil : CGDirectDisplayID(defaults.integer(forKey: DefaultsKey.displayID))
        let storedScreen = storedID.flatMap { id in
            NSScreen.screens.first { $0.hudDisplayID == id }
        }
        let pointerScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        let screen = storedScreen ?? pointerScreen ?? NSScreen.main ?? NSScreen.screens[0]
        setFrameSize(restoredSize(on: screen))
        let hasCoordinates = defaults.object(forKey: DefaultsKey.normalizedX) != nil
            && defaults.object(forKey: DefaultsKey.normalizedY) != nil
        let nx = hasCoordinates ? clamp(defaults.double(forKey: DefaultsKey.normalizedX)) : 0.96
        let ny = hasCoordinates ? clamp(defaults.double(forKey: DefaultsKey.normalizedY)) : 0.50
        setFrameOrigin(origin(normalizedX: nx, normalizedY: ny, on: screen))
        // Persist the fallback immediately if a remembered display disappeared.
        savePosition(on: screen)
    }

    private func screenParametersChanged() {
        guard isVisible else { return }
        moveGeneration += 1
        restorePosition()
        panel?.orderFrontRegardless()
    }

    private func activeSpaceChanged() {
        guard isVisible else { return }
        ensureReachable()
        panel?.orderFrontRegardless()
    }

    private func ensureReachable() {
        guard let panel = panel, !NSScreen.screens.isEmpty else { return }
        let visibleArea = NSScreen.screens.reduce(CGFloat(0)) { total, screen in
            let overlap = panel.frame.intersection(screen.visibleFrame)
            return total + max(0, overlap.width) * max(0, overlap.height)
        }
        if visibleArea < 16 { restorePosition() }
    }

    private func savePosition(on screen: NSScreen) {
        guard let panel = panel else { return }
        let visible = screen.visibleFrame
        let availableWidth = max(1, visible.width - panel.frame.width)
        let availableHeight = max(1, visible.height - panel.frame.height)
        let nx = clamp((panel.frame.minX - visible.minX) / availableWidth)
        let ny = clamp((panel.frame.minY - visible.minY) / availableHeight)
        defaults.set(Int(screen.hudDisplayID), forKey: DefaultsKey.displayID)
        defaults.set(Double(nx), forKey: DefaultsKey.normalizedX)
        defaults.set(Double(ny), forKey: DefaultsKey.normalizedY)
        defaults.set(Double(panel.frame.width), forKey: DefaultsKey.width)
    }

    private func origin(normalizedX nx: CGFloat, normalizedY ny: CGFloat,
                        on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        let size = panel?.frame.size ?? defaultWindowSize
        return NSPoint(x: visible.minX + clamp(nx) * max(0, visible.width - size.width),
                       y: visible.minY + clamp(ny) * max(0, visible.height - size.height))
    }

    private func clampedOrigin(_ point: NSPoint, size: NSSize, in visible: NSRect) -> NSPoint {
        let maxX = max(visible.minX, visible.maxX - size.width)
        let maxY = max(visible.minY, visible.maxY - size.height)
        return NSPoint(x: min(max(point.x, visible.minX), maxX),
                       y: min(max(point.y, visible.minY), maxY))
    }

    private func restoredSize(on screen: NSScreen) -> NSSize {
        let aspect = defaultWindowSize.width / defaultWindowSize.height
        let storedWidth = defaults.object(forKey: DefaultsKey.width) == nil
            ? defaultWindowSize.width : CGFloat(defaults.double(forKey: DefaultsKey.width))
        // A previously large demo remote must still fit after moving to a smaller display.
        let screenMaxWidth = min(screen.visibleFrame.width,
                                 screen.visibleFrame.height * aspect)
        let upper = max(minimumWindowSize.width,
                        min(maximumWindowSize.width, screenMaxWidth))
        let width = min(max(storedWidth, minimumWindowSize.width), upper)
        return NSSize(width: width, height: width / aspect)
    }

    private func setFrameSize(_ size: NSSize) {
        guard let panel = panel else { return }
        isMovingProgrammatically = true
        panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: false)
        DispatchQueue.main.async { [weak self] in self?.isMovingProgrammatically = false }
    }

    private func setFrameOrigin(_ point: NSPoint) {
        isMovingProgrammatically = true
        panel?.setFrameOrigin(point)
        DispatchQueue.main.async { [weak self] in self?.isMovingProgrammatically = false }
    }

    private func bestScreen(for frame: NSRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        if let overlapping = screens.max(by: {
            overlapArea(frame, $0.visibleFrame) < overlapArea(frame, $1.visibleFrame)
        }), overlapArea(frame, overlapping.visibleFrame) > 0 {
            return overlapping
        }
        let centre = NSPoint(x: frame.midX, y: frame.midY)
        return screens.min {
            squaredDistance(centre, NSPoint(x: $0.visibleFrame.midX, y: $0.visibleFrame.midY))
                < squaredDistance(centre, NSPoint(x: $1.visibleFrame.midX, y: $1.visibleFrame.midY))
        }
    }

    private func overlapArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let overlap = a.intersection(b)
        return max(0, overlap.width) * max(0, overlap.height)
    }

    private func squaredDistance(_ a: NSPoint, _ b: NSPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx * dx + dy * dy
    }

    private func clamp<T: BinaryFloatingPoint>(_ value: T) -> T { min(1, max(0, value)) }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.async(execute: work) }
    }
}

//
//  AppWheel.swift
//  HyperVibe
//
//  A radial app launcher, summoned by holding the layer key.
//
//  It appears CENTRED ON THE CURSOR rather than at a fixed spot on screen: the pointer is then
//  already at the middle, so picking is a short flick outward in the app's direction instead of a
//  journey across the display. That matters on a remote whose pad is 27 mm across.
//
//  Selection is by where the CURSOR is, not by where the finger is on the pad — so the trackpad
//  keeps behaving exactly as it always does while the wheel is up, and nothing has to be learned.
//  Select launches what is highlighted; any other button cancels; nothing is highlighted until the
//  pointer leaves a dead zone in the middle, so summoning it and pressing Select does nothing by
//  accident.
//

import AppKit
import SwiftUI

// MARK: - Model

final class AppWheelModel: ObservableObject {
    @Published var apps: [String] = []
    @Published var icons: [String: NSImage] = [:]
    /// Index of the sector the pointer is over, or nil while it is in the dead zone.
    @Published private(set) var highlighted: Int?
    /// The angle the highlight is travelling toward, UNWRAPPED — it keeps accumulating past ±π so
    /// that moving from the last sector to the first sweeps the short way round instead of unwinding
    /// the long way. Kept when the highlight clears, so the wedge fades out where it was rather than
    /// snapping back to the top first.
    @Published private(set) var wedgeAngle: Double = .pi / 2
    /// Drives the summon animation; set once the window is on screen so the wheel grows into place.
    @Published var presented = false

    func setHighlight(_ index: Int?) {
        highlighted = index
        guard let index = index, !apps.isEmpty else { return }
        let step = 2 * Double.pi / Double(apps.count)
        var target = Double.pi / 2 - Double(index) * step
        while target - wedgeAngle > .pi { target -= 2 * .pi }
        while wedgeAngle - target > .pi { target += 2 * .pi }
        wedgeAngle = target
    }

    /// Reset for a fresh summon: start the wedge under wherever the first highlight will be.
    func resetHighlight() {
        highlighted = nil
        wedgeAngle = .pi / 2
    }

    /// Wheel geometry, in points. `deadZone` is the radius inside which nothing is selected.
    let outerRadius: CGFloat = 152
    let innerRadius: CGFloat = 78
    let deadZone: CGFloat = 60
    /// The highlighted wedge swells past the ring's edge — the selection reads at a glance from the
    /// silhouette alone, without having to compare shades of fill.
    let highlightBulge: CGFloat = 7
    var side: CGFloat { (outerRadius + highlightBulge) * 2 + 8 }

    func load(_ names: [String]) {
        apps = names
        icons = Dictionary(uniqueKeysWithValues: names.compactMap { name in
            ActionVisual.appIcon(named: name).map { (name, $0) }
        })
    }

    /// Sector under a point given as an offset from the wheel's centre, in view coordinates
    /// (y upwards). Sector 0 sits at the top and they run clockwise, matching how the icons read.
    func sector(atOffset offset: CGPoint) -> Int? {
        guard !apps.isEmpty else { return nil }
        let r = hypot(offset.x, offset.y)
        guard r >= deadZone else { return nil }
        let step = 2 * Double.pi / Double(apps.count)
        // atan2 measures anticlockwise from east; we want clockwise from north.
        var a = Double.pi / 2 - atan2(Double(offset.y), Double(offset.x))
        if a < 0 { a += 2 * .pi }
        return Int((a + step / 2) / step) % apps.count
    }
}

// MARK: - View

struct AppWheelView: View {
    @ObservedObject var model: AppWheelModel

    var body: some View {
        ZStack {
            // The ring is a real BLUR of what is behind it, not a flat wash of black. Liquid glass
            // is mostly this plus two edges: a bright inner rim where light catches, and a soft
            // outer shadow that lifts it off the desktop. A single translucent fill can only ever
            // look like a grey disc, which is what it looked like.
            RingShape(inner: model.innerRadius, outer: model.outerRadius)
                .fill(.ultraThinMaterial)
                .overlay {
                    RingShape(inner: model.innerRadius, outer: model.outerRadius)
                        .fill(
                            LinearGradient(colors: [.white.opacity(0.22), .clear, .black.opacity(0.10)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                }
                .overlay {
                    // Rim light: brightest at the top, the way a glass torus catches a light above it.
                    RingShape(inner: model.innerRadius, outer: model.outerRadius)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1
                        )
                }
                // No drop shadow: a shadow on an annulus falls on the INNER edge as much as the
                // outer one, ringing the hole in grey. The rim light is what lifts it off the
                // desktop; that is enough.
                .frame(width: model.side, height: model.side)

            // The highlight is its own animatable Shape rather than something drawn into the
            // Canvas above, so it can GLIDE between sectors. Popping from one to the next was the
            // thing that read as abrupt; sweeping round the ring is what a radial menu should do.
            WedgeShape(mid: model.wedgeAngle,
                       sweep: 2 * Double.pi / Double(max(model.apps.count, 1)),
                       inner: model.innerRadius,
                       outer: model.outerRadius + model.highlightBulge)
                // FULLY opaque, deliberately. At 0.92 the dark ring beneath showed through and
                // muddied it — a translucent highlight stacked on a translucent ring reads as cheap.
                // Solid selection against a glassy ring is the contrast that makes it look intended.
                .fill(
                    LinearGradient(colors: [Color.accentColor.opacity(1.0),
                                            Color.accentColor.opacity(0.82)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .shadow(color: Color.accentColor.opacity(0.45), radius: 12, y: 2)
                .opacity(model.highlighted == nil ? 0 : 1)
                .animation(.spring(response: 0.30, dampingFraction: 0.78), value: model.wedgeAngle)
                .animation(.easeOut(duration: 0.16), value: model.highlighted == nil)

            // Icons, laid out on the ring. Drawn as views rather than into the Canvas so each one
            // can animate its own scale when highlighted.
            ForEach(Array(model.apps.enumerated()), id: \.offset) { i, name in
                let step = 2 * Double.pi / Double(max(model.apps.count, 1))
                let mid = Double.pi / 2 - Double(i) * step
                let r = (model.innerRadius + model.outerRadius) / 2
                let on = model.highlighted == i
                Group {
                    if let icon = model.icons[name] {
                        Image(nsImage: icon).resizable().frame(width: 54, height: 54)
                    } else {
                        Image(systemName: "app.dashed").font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .scaleEffect((on ? 1.18 : 1.0) * (model.presented ? 1 : 0.4))
                .shadow(color: .black.opacity(on ? 0.45 : 0.25), radius: on ? 8 : 3, y: 2)
                // Radius interpolates from the middle outward, so summoning reads as the icons
                // BLOOMING out of the centre rather than a ring appearing from nowhere. Staggered
                // by index, which is what makes it feel like one motion instead of four.
                .offset(x: CGFloat(cos(mid)) * (model.presented ? r : 0),
                        y: -CGFloat(sin(mid)) * (model.presented ? r : 0))
                .opacity(model.presented ? 1 : 0)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: on)
                .animation(.spring(response: 0.34, dampingFraction: 0.72)
                            .delay(Double(i) * 0.035), value: model.presented)
            }

            // The middle names what is about to happen, so the wheel never launches something the
            // user did not read. On its own pill so it stays legible over the icons behind it.
            Group {
                if let i = model.highlighted, i < model.apps.count {
                    Text(model.apps[i])
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Text("移到某个方向")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            )
        }
        .frame(width: model.side, height: model.side)
        .scaleEffect(model.presented ? 1 : 0.72)
        .opacity(model.presented ? 1 : 0)
        .animation(.spring(response: 0.30, dampingFraction: 0.78), value: model.presented)
    }

    private func point(_ c: CGPoint, _ r: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(x: c.x + r * CGFloat(cos(angle)), y: c.y - r * CGFloat(sin(angle)))
    }
}

/// The ring itself. `InsettableShape` so it can be stroked along its own border rather than having
/// a second shape drawn on top and hoping the two line up.
struct RingShape: InsettableShape {
    var inner: CGFloat
    var outer: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addArc(center: c, radius: outer - insetAmount, startAngle: .zero,
                 endAngle: .degrees(360), clockwise: false)
        p.addArc(center: c, radius: inner + insetAmount, startAngle: .degrees(360),
                 endAngle: .zero, clockwise: true)
        return p
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// One annular sector, animatable by its mid-angle.
///
/// Traced as a polyline rather than with `addArc`: `Path` boolean ops need macOS 14 and this must
/// run on 13, and `addArc` measures angles in the view's own y-down space while everything here uses
/// the y-up convention — mixing the two produced a bow tie. One convention, one source of vertices.
struct WedgeShape: Shape {
    var mid: Double
    var sweep: Double
    var inner: CGFloat
    var outer: CGFloat

    var animatableData: Double {
        get { mid }
        set { mid = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let from = mid - sweep / 2, to = mid + sweep / 2
        let steps = 28
        func point(_ r: CGFloat, _ a: Double) -> CGPoint {
            CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y - r * CGFloat(sin(a)))
        }
        var p = Path()
        p.move(to: point(inner, from))
        for k in 0...steps { p.addLine(to: point(outer, from + (to - from) * Double(k) / Double(steps))) }
        for k in 0...steps { p.addLine(to: point(inner, to - (to - from) * Double(k) / Double(steps))) }
        p.closeSubpath()
        return p
    }
}

// MARK: - Controller

final class AppWheelController {
    let model = AppWheelModel()
    private(set) var isOpen = false

    private var window: NSWindow?
    private var followTimer: Timer?
    /// Wheel centre in Quartz coordinates (top-left origin), fixed for the life of one summon.
    private var centre: CGPoint = .zero

    deinit { followTimer?.invalidate() }

    func configure(apps: [String]) { model.load(apps) }

    /// Summon, centred on the pointer and clamped so the whole wheel stays on its display.
    func open() {
        guard !isOpen, !model.apps.isEmpty else { return }
        isOpen = true
        ensureWindow()
        guard let window = window, let screen = NSScreen.screens.first else { return }

        let cursor = CGEvent(source: nil)?.location ?? .zero
        centre = clampToDisplay(cursor)
        // Quartz (top-left) → AppKit (bottom-left of the primary screen).
        let originY = screen.frame.maxY - centre.y - model.side / 2
        window.setFrameOrigin(NSPoint(x: centre.x - model.side / 2, y: originY))

        model.resetHighlight()
        model.presented = false
        // The window itself appears instantly and fully opaque: every bit of the entrance is done
        // in SwiftUI, so a window-level fade on top would only wash it out.
        window.alphaValue = 1
        window.orderFrontRegardless()
        DispatchQueue.main.async { self.model.presented = true }
        startFollowing()
    }

    /// Close without acting. Returns whether it was open.
    @discardableResult
    func cancel() -> Bool {
        guard isOpen else { return false }
        close()
        return true
    }

    /// Launch whatever is highlighted, if anything, then close.
    func commit() {
        guard isOpen else { return }
        let choice = model.highlighted.flatMap { $0 < model.apps.count ? model.apps[$0] : nil }
        close()
        guard let app = choice else {
            rmDebug("🎡 app wheel: nothing highlighted, cancelled")
            return
        }
        rmDebug("🎡 app wheel: launching \(app)")
        guard let url = ActionVisual.applicationURL(named: app) else {
            rmDebug("🎡 app wheel: cannot locate \(app)")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func close() {
        isOpen = false
        model.presented = false
        followTimer?.invalidate()
        followTimer = nil
        guard let window = window else { return }
        // Let the collapse play, then take the window away — ordering out immediately would cut it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { window.orderOut(nil) }
    }

    // MARK: - Pointer tracking

    private func startFollowing() {
        followTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.track() }
        RunLoop.main.add(t, forMode: .common)
        followTimer = t
    }

    private func track() {
        let p = CGEvent(source: nil)?.location ?? .zero
        // Quartz y grows downward; the wheel's maths expects y upward.
        let offset = CGPoint(x: p.x - centre.x, y: centre.y - p.y)
        let sector = model.sector(atOffset: offset)
        if sector != model.highlighted { model.setHighlight(sector) }
    }

    /// Keep the whole wheel on one display, so a summon near an edge is not half off-screen.
    private func clampToDisplay(_ p: CGPoint) -> CGPoint {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success,
              let display = ids.prefix(Int(count)).map({ CGDisplayBounds($0) })
                  .first(where: { $0.contains(p) })
        else { return p }
        let m = model.side / 2 + 8
        return CGPoint(x: min(max(p.x, display.minX + m), display.maxX - m),
                       y: min(max(p.y, display.minY + m), display.maxY - m))
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let rect = NSRect(x: 0, y: 0, width: model.side, height: model.side)
        let win = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true        // the pointer must pass through; we only read it
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        win.contentView = NSHostingView(rootView: AppWheelView(model: model))
        window = win
    }
}

//
//  HoldAnimationGallery.swift
//  HyperVibe
//
//  A no-input visual design lab for comparing nine complete long-press motion languages. Launch
//  with `--preview-hold-animations`; it never starts HID discovery, suspends rcd, or changes the
//  production status widget. Every card runs the real Back tap-hold ladder from the live author
//  config: 0.18 s visual lead-in → Close Window at 0.50 s → Quit App at 1.20 s → the
//  cancel escape hatch at 2.20 s. The lab therefore compares stage hand-off, not a one-shot fill.
//

import AppKit
import QuartzCore

private final class HoldGalleryPanel: NSPanel {
    // The lab is an intentional, interactive foreground surface. Making it key is what keeps
    // macOS Spaces from silently attaching a command-line-launched panel to a hidden Space.
    // Production HUD/status panels do not use this class and remain non-activating.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class HoldAnimationGalleryController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var timer: Timer?
    private var content: HoldGalleryContentView?

    func show() {
        let size = NSSize(width: 1240, height: 900)
        let window = HoldGalleryPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "HyperVibe · Hold Interaction Lab"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        // This is deliberately opaque. A large transparent NSPanel launched from a menu-bar app
        // can be registered by WindowServer without ever receiving an IOSurface (a visible but
        // uncapturable empty shell). The lab owns its entire dark canvas, so opacity is both
        // visually correct and guarantees a real render surface.
        window.backgroundColor = NSColor(srgbRed: 0.030, green: 0.034, blue: 0.046, alpha: 1)
        window.isOpaque = true
        window.hasShadow = false
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: .darkAqua)
        // Move this one-off lab to the user's current Space. Production HUD/status windows use
        // their own all-Space policy and are completely untouched by this preview controller.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary]
        window.isFloatingPanel = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = HoldGalleryContentView()
        content.frame = NSRect(origin: .zero, size: size)
        content.autoresizingMask = [.width, .height]
        content.speedControl.target = self
        content.speedControl.action = #selector(speedChanged(_:))
        content.replayButton.target = self
        content.replayButton.action = #selector(replayAll)
        content.closeButton.target = self
        content.closeButton.action = #selector(closeLab)
        window.contentView = content
        self.content = content
        self.window = window

        let mouse = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        let targetFrame: NSRect
        if let visible = targetScreen?.visibleFrame {
            let origin = NSPoint(x: visible.midX - size.width / 2,
                                 y: visible.midY - size.height / 2)
            // Borderless NSPanel may adopt a zero frame while its content view is attached. Set
            // both size and origin atomically after attachment; moving only the origin would
            // preserve that zero-sized frame and leave an invisible WindowServer entry.
            targetFrame = NSRect(origin: origin, size: size)
        } else {
            targetFrame = NSRect(origin: .zero, size: size)
        }
        window.setContentSize(size)
        window.setFrame(targetFrame, display: true)
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        content.needsDisplay = true
        window.contentView?.needsDisplay = true
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()

        // Reassert foreground ownership after applicationDidFinishLaunching returns. This is what
        // brings a command-line-launched design lab onto the active Space without changing the
        // normal menu-bar app's activation behaviour.
        DispatchQueue.main.async {
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            NSApp.activate(ignoringOtherApps: true)
            print("🎨 hold animation lab shown — frame \(NSStringFromRect(window.frame)), "
                  + "window \(window.windowNumber), visible \(window.isVisible)")
        }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.content?.update(now: CACurrentMediaTime())
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        content.restartAll(at: CACurrentMediaTime())
    }

    @objc private func speedChanged(_ sender: NSSegmentedControl) {
        content?.setSpeed(sender.selectedSegment == 0 ? .actual : .study)
    }

    @objc private func replayAll() {
        content?.restartAll(at: CACurrentMediaTime())
    }

    @objc private func closeLab() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        // This controller is only reachable through the isolated preview command. Closing the lab
        // must not leave an invisible accessory process behind.
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

private enum HoldGallerySpeed {
    case actual
    case study
}

/// Read-only progress exported by a preview to its stage rail. Values are tied to the real Back
/// tap-hold thresholds even when Study mode stretches wall-clock playback.
private struct HoldDemoSnapshot {
    let loopFraction: CGFloat
    let segmentProgress: [CGFloat]
    let activeSegment: Int?
    let isResult: Bool
}

private enum HoldPreviewStyle: Int, CaseIterable {
    case liquidContinuum
    case magneticBloom
    case glassRefraction
    case auroraCircuit
    case orbitalCharge
    case pressureField
    case kineticShutter
    case chronoInstrument
    case spatialDeck

    var index: String { String(format: "%02d", rawValue + 1) }

    var title: String {
        switch self {
        case .liquidContinuum: return "Liquid Continuum"
        case .magneticBloom: return "Magnetic Bloom"
        case .glassRefraction: return "Glass Refraction"
        case .auroraCircuit: return "Aurora Circuit"
        case .orbitalCharge: return "Orbital Charge"
        case .pressureField: return "Pressure Field"
        case .kineticShutter: return "Kinetic Shutter"
        case .chronoInstrument: return "Chrono Instrument"
        case .spatialDeck: return "Spatial Deck"
        }
    }

    var chineseName: String {
        switch self {
        case .liquidContinuum: return "连续液态蓄能"
        case .magneticBloom: return "磁性聚变"
        case .glassRefraction: return "玻璃折射"
        case .auroraCircuit: return "极光回路"
        case .orbitalCharge: return "轨道蓄能"
        case .pressureField: return "压力场"
        case .kineticShutter: return "机械光栅"
        case .chronoInstrument: return "精密计时"
        case .spatialDeck: return "空间翻页"
        }
    }

    var summary: String {
        switch self {
        case .liquidContinuum: return "每段注满、收束为光线，再从空卡启动下一段"
        case .magneticBloom: return "粒子聚合确认动作，阈值时外爆并重组下一场"
        case .glassRefraction: return "折射面横穿整卡，交接时用透镜闪切开启下一段"
        case .auroraCircuit: return "双层极光与边缘回路同步完成，随后回落重启"
        case .orbitalCharge: return "每一段都是一圈完整轨道，到点确认后立即换轨"
        case .pressureField: return "多道场线向中心压缩，冲击波过后展开下一段"
        case .kineticShutter: return "九片金属光栅交错闭合，到点翻转后开启下一组"
        case .chronoInstrument: return "刻度、游标与目标时间共同推进，阈值时数字换挡"
        case .spatialDeck: return "整张界面像一叠空间卡片，被逐页揭开并翻向下一层"
        }
    }

    var footer: String {
        switch self {
        case .liquidContinuum: return "MONOTONIC · FLUID · EDGE COLLAPSE"
        case .magneticBloom: return "MAGNETIC · PARTICLES · FUSION"
        case .glassRefraction: return "LENS · CAUSTICS · REFRACTION"
        case .auroraCircuit: return "AURORA · CIRCUIT · SPECTRUM"
        case .orbitalCharge: return "ORBIT · COMET · COMPLETION"
        case .pressureField: return "PRESSURE · RESONANCE · IMPACT"
        case .kineticShutter: return "MECHANICAL · LOUVERS · APERTURE"
        case .chronoInstrument: return "CHRONO · TICKS · CALIBRATION"
        case .spatialDeck: return "DEPTH · SHEETS · PAGE TURN"
        }
    }

    var accent: NSColor {
        switch self {
        case .liquidContinuum: return NSColor(srgbRed: 0.08, green: 0.82, blue: 0.93, alpha: 1)
        case .magneticBloom: return NSColor(srgbRed: 1.00, green: 0.31, blue: 0.63, alpha: 1)
        case .glassRefraction: return NSColor(srgbRed: 0.42, green: 0.80, blue: 1.00, alpha: 1)
        case .auroraCircuit: return NSColor(srgbRed: 0.52, green: 0.35, blue: 1.00, alpha: 1)
        case .orbitalCharge: return NSColor(srgbRed: 1.00, green: 0.67, blue: 0.18, alpha: 1)
        case .pressureField: return NSColor(srgbRed: 0.19, green: 0.95, blue: 0.62, alpha: 1)
        case .kineticShutter: return NSColor(srgbRed: 0.88, green: 0.93, blue: 0.98, alpha: 1)
        case .chronoInstrument: return NSColor(srgbRed: 0.79, green: 1.00, blue: 0.30, alpha: 1)
        case .spatialDeck: return NSColor(srgbRed: 1.00, green: 0.42, blue: 0.24, alpha: 1)
        }
    }

    var secondary: NSColor {
        switch self {
        case .liquidContinuum: return NSColor(srgbRed: 0.18, green: 0.48, blue: 1.00, alpha: 1)
        case .magneticBloom: return NSColor(srgbRed: 0.56, green: 0.25, blue: 1.00, alpha: 1)
        case .glassRefraction: return NSColor(srgbRed: 0.58, green: 0.48, blue: 1.00, alpha: 1)
        case .auroraCircuit: return NSColor(srgbRed: 0.00, green: 0.92, blue: 0.82, alpha: 1)
        case .orbitalCharge: return NSColor(srgbRed: 1.00, green: 0.27, blue: 0.38, alpha: 1)
        case .pressureField: return NSColor(srgbRed: 0.12, green: 0.61, blue: 1.00, alpha: 1)
        case .kineticShutter: return NSColor(srgbRed: 0.25, green: 0.67, blue: 0.86, alpha: 1)
        case .chronoInstrument: return NSColor(srgbRed: 1.00, green: 0.65, blue: 0.14, alpha: 1)
        case .spatialDeck: return NSColor(srgbRed: 0.48, green: 0.30, blue: 1.00, alpha: 1)
        }
    }
}

private final class HoldGalleryContentView: NSView {
    let speedControl = NSSegmentedControl(
        labels: ["Actual timing", "Study · ×2.5"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    let replayButton = NSButton(title: "Replay all", target: nil, action: nil)
    let closeButton = NSButton(
        image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close") ?? NSImage(),
        target: nil,
        action: nil
    )

    private let titleLabel = NSTextField(labelWithString: "Back · Tap-Hold Motion Lab")
    private let subtitleLabel = NSTextField(
        labelWithString: "真实返回键阶梯 · 每一段都完整清场、交接，再重新计时"
    )
    private let liveBadge = NSTextField(labelWithString: "LIVE  ·  NO INPUT")
    private let gestureBadge = HoldGalleryContentView.badge("BACK  ·  TAP → HOLD", tint: .white)
    private let closeBadge = HoldGalleryContentView.badge("0.50 s  CLOSE", tint: .systemCyan)
    private let quitBadge = HoldGalleryContentView.badge("1.20 s  QUIT", tint: .systemOrange)
    private let cancelBadge = HoldGalleryContentView.badge("2.20 s  CANCEL", tint: .systemGray)
    private let divider = CALayer()
    private let tiles = HoldPreviewStyle.allCases.map(HoldGalleryTileView.init)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 26
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(srgbRed: 0.030, green: 0.034, blue: 0.046,
                                         alpha: 0.985).cgColor
        layer?.borderWidth = 0.8
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textColor = .white
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.58)

        liveBadge.font = .monospacedSystemFont(ofSize: 10.5, weight: .semibold)
        liveBadge.textColor = NSColor.systemGreen.withAlphaComponent(0.92)
        liveBadge.alignment = .center
        liveBadge.wantsLayer = true
        liveBadge.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.09).cgColor
        liveBadge.layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.24).cgColor
        liveBadge.layer?.borderWidth = 0.7
        liveBadge.layer?.cornerRadius = 9

        speedControl.selectedSegment = 1
        speedControl.segmentStyle = .rounded
        speedControl.setWidth(125, forSegment: 0)
        speedControl.setWidth(125, forSegment: 1)
        replayButton.bezelStyle = .rounded
        replayButton.controlSize = .large
        closeButton.isBordered = false
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.58)
        closeButton.imageScaling = .scaleProportionallyDown

        addSubview(closeButton)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(gestureBadge)
        addSubview(closeBadge)
        addSubview(quitBadge)
        addSubview(cancelBadge)
        addSubview(liveBadge)
        addSubview(speedControl)
        addSubview(replayButton)
        tiles.forEach(addSubview)

        divider.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        layer?.addSublayer(divider)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func badge(_ text: String, tint: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = tint.withAlphaComponent(0.86)
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = tint.withAlphaComponent(0.065).cgColor
        label.layer?.borderColor = tint.withAlphaComponent(0.17).cgColor
        label.layer?.borderWidth = 0.65
        label.layer?.cornerRadius = 8
        return label
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        closeButton.frame = NSRect(x: 18, y: 18, width: 28, height: 28)
        titleLabel.frame = NSRect(x: 57, y: 20, width: min(600, width * 0.50), height: 37)
        subtitleLabel.frame = NSRect(x: 59, y: 58, width: min(700, width * 0.58), height: 19)
        gestureBadge.frame = NSRect(x: 59, y: 88, width: 150, height: 22)
        closeBadge.frame = NSRect(x: 218, y: 88, width: 116, height: 22)
        quitBadge.frame = NSRect(x: 343, y: 88, width: 112, height: 22)
        cancelBadge.frame = NSRect(x: 464, y: 88, width: 132, height: 22)
        liveBadge.frame = NSRect(x: width - 448, y: 24, width: 126, height: 24)
        speedControl.frame = NSRect(x: width - 308, y: 20, width: 252, height: 32)
        replayButton.frame = NSRect(x: width - 164, y: 70, width: 108, height: 30)
        divider.frame = CGRect(x: 34, y: 130, width: width - 68, height: 1)

        let margin: CGFloat = 28
        let gap: CGFloat = 14
        let top: CGFloat = 146
        let bottom: CGFloat = 24
        let tileWidth = (width - margin * 2 - gap * 2) / 3
        let tileHeight = (bounds.height - top - bottom - gap * 2) / 3
        for (index, tile) in tiles.enumerated() {
            let row = index / 3
            let column = index % 3
            tile.frame = NSRect(x: margin + CGFloat(column) * (tileWidth + gap),
                                y: top + CGFloat(row) * (tileHeight + gap),
                                width: tileWidth, height: tileHeight)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        divider.frame = CGRect(x: 34, y: 130, width: width - 68, height: 1)
        CATransaction.commit()
    }

    func update(now: CFTimeInterval) {
        tiles.forEach { $0.update(now: now) }
    }

    func setSpeed(_ speed: HoldGallerySpeed) {
        let now = CACurrentMediaTime()
        tiles.forEach { $0.setSpeed(speed, at: now) }
    }

    func restartAll(at now: CFTimeInterval) {
        for (index, tile) in tiles.enumerated() {
            // A tiny offset lets the eye follow nine threshold impacts instead of receiving one
            // undifferentiated flash, while keeping the comparison effectively synchronized.
            tile.restart(at: now + Double(index) * 0.035)
        }
    }
}

private final class HoldGalleryTileView: NSVisualEffectView {
    private let style: HoldPreviewStyle
    private let numberLabel: NSTextField
    private let titleLabel: NSTextField
    private let nameLabel: NSTextField
    private let summaryLabel: NSTextField
    private let footerLabel: NSTextField
    private let replayHint = NSTextField(labelWithString: "CLICK TO REPLAY")
    private let preview: HoldAnimationPreviewView
    private let stageRail: HoldStageRailView
    private var tracking: NSTrackingArea?
    private var hovering = false

    override var isFlipped: Bool { true }

    init(style: HoldPreviewStyle) {
        self.style = style
        self.numberLabel = NSTextField(labelWithString: style.index)
        self.titleLabel = NSTextField(labelWithString: style.title)
        self.nameLabel = NSTextField(labelWithString: style.chineseName)
        self.summaryLabel = NSTextField(wrappingLabelWithString: style.summary)
        self.footerLabel = NSTextField(labelWithString: style.footer)
        self.preview = HoldAnimationPreviewView(style: style)
        self.stageRail = HoldStageRailView(accent: style.accent, secondary: style.secondary)
        super.init(frame: .zero)

        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.65
        layer?.borderColor = NSColor.white.withAlphaComponent(0.085).cgColor

        numberLabel.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        numberLabel.textColor = style.accent
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = style.accent.withAlphaComponent(0.88)
        summaryLabel.font = .systemFont(ofSize: 11, weight: .medium)
        summaryLabel.textColor = NSColor.white.withAlphaComponent(0.50)
        summaryLabel.maximumNumberOfLines = 1
        footerLabel.font = .monospacedSystemFont(ofSize: 8.2, weight: .medium)
        footerLabel.textColor = NSColor.white.withAlphaComponent(0.30)
        replayHint.font = .monospacedSystemFont(ofSize: 8, weight: .semibold)
        replayHint.textColor = NSColor.white.withAlphaComponent(0.25)
        replayHint.alignment = .right

        [numberLabel, titleLabel, nameLabel, summaryLabel, footerLabel, replayHint, preview, stageRail]
            .forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        numberLabel.frame = NSRect(x: 18, y: 16, width: 30, height: 20)
        titleLabel.frame = NSRect(x: 51, y: 14, width: bounds.width - 160, height: 22)
        nameLabel.frame = NSRect(x: bounds.width - 110, y: 17, width: 92, height: 18)
        nameLabel.alignment = .right
        summaryLabel.frame = NSRect(x: 18, y: 43, width: bounds.width - 36, height: 18)

        let previewWidth = bounds.width - 36
        let previewHeight = min(104, previewWidth / 3.18)
        preview.frame = NSRect(x: 18, y: 57, width: previewWidth, height: previewHeight)
        stageRail.frame = NSRect(x: 18, y: 57 + previewHeight + 7,
                                 width: previewWidth, height: 38)
        let footerY = 57 + previewHeight + 49
        footerLabel.frame = NSRect(x: 18, y: footerY, width: bounds.width - 145, height: 16)
        replayHint.frame = NSRect(x: bounds.width - 126, y: footerY, width: 108, height: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: bounds,
                                      options: [.activeInKeyWindow, .mouseEnteredAndExited],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        self.tracking = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        animateBorder(to: style.accent.withAlphaComponent(0.52))
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        animateBorder(to: NSColor.white.withAlphaComponent(0.10))
    }

    override func mouseDown(with event: NSEvent) {
        restart(at: CACurrentMediaTime())
        let response = CAKeyframeAnimation(keyPath: "transform.scale")
        response.values = [1.0, 0.988, 1.004, 1.0]
        response.keyTimes = [0.0, 0.28, 0.68, 1.0]
        response.duration = 0.24
        response.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(response, forKey: "tileReplayResponse")
    }

    private func animateBorder(to color: NSColor) {
        let from = layer?.presentation()?.borderColor ?? layer?.borderColor
        layer?.borderColor = color.cgColor
        let animation = CABasicAnimation(keyPath: "borderColor")
        animation.fromValue = from
        animation.toValue = color.cgColor
        animation.duration = 0.18
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(animation, forKey: "tileHoverBorder")
    }

    func update(now: CFTimeInterval) {
        stageRail.update(preview.update(now: now))
    }

    func setSpeed(_ speed: HoldGallerySpeed, at now: CFTimeInterval) {
        preview.speed = speed
        restart(at: now)
    }

    func restart(at now: CFTimeInterval) { preview.restart(at: now) }
}

/// A persistent record of the real hold ladder. Unlike the card's stage-specific energy, completed
/// segments remain lit here, so the next action and its absolute threshold never disappear during
/// the hand-off animation.
private final class HoldStageRailView: NSView {
    private let accent: NSColor
    private let secondary: NSColor
    private let captions = [
        NSTextField(labelWithString: "CLOSE  0.50"),
        NSTextField(labelWithString: "QUIT  1.20"),
        NSTextField(labelWithString: "CANCEL  2.20"),
    ]
    private let tracks = (0..<3).map { _ in CALayer() }
    private let fills = (0..<3).map { _ in CAGradientLayer() }
    private let nodes = (0..<3).map { _ in CALayer() }

    override var isFlipped: Bool { true }

    init(accent: NSColor, secondary: NSColor) {
        self.accent = accent
        self.secondary = secondary
        super.init(frame: .zero)
        wantsLayer = true
        for caption in captions {
            caption.font = .monospacedSystemFont(ofSize: 8.3, weight: .semibold)
            caption.textColor = NSColor.white.withAlphaComponent(0.34)
            addSubview(caption)
        }
        for index in tracks.indices {
            tracks[index].backgroundColor = NSColor.white.withAlphaComponent(0.065).cgColor
            tracks[index].cornerRadius = 1.5
            fills[index].colors = [secondary.withAlphaComponent(0.88).cgColor,
                                   accent.withAlphaComponent(0.96).cgColor]
            fills[index].startPoint = CGPoint(x: 0, y: 0.5)
            fills[index].endPoint = CGPoint(x: 1, y: 0.5)
            fills[index].cornerRadius = 1.5
            nodes[index].backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
            nodes[index].cornerRadius = 3
            layer?.addSublayer(tracks[index])
            layer?.addSublayer(fills[index])
            layer?.addSublayer(nodes[index])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let gap: CGFloat = 8
        let width = (bounds.width - gap * 2) / 3
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0..<3 {
            let x = CGFloat(index) * (width + gap)
            captions[index].frame = NSRect(x: x, y: 1, width: width, height: 14)
            captions[index].alignment = index == 0 ? .left : (index == 2 ? .right : .center)
            tracks[index].frame = CGRect(x: x, y: 27, width: width, height: 3)
            fills[index].frame = CGRect(x: x, y: 27, width: 0, height: 3)
            nodes[index].frame = CGRect(x: x + width - 5.5, y: 25.5, width: 6, height: 6)
        }
        CATransaction.commit()
    }

    func update(_ snapshot: HoldDemoSnapshot) {
        guard snapshot.segmentProgress.count == 3 else { return }
        let gap: CGFloat = 8
        let width = (bounds.width - gap * 2) / 3
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0..<3 {
            let x = CGFloat(index) * (width + gap)
            let progress = min(1, max(0, snapshot.segmentProgress[index]))
            fills[index].frame = CGRect(x: x, y: 27, width: width * progress, height: 3)
            let completed = progress >= 0.999
            let active = snapshot.activeSegment == index
            nodes[index].backgroundColor = (completed ? accent : NSColor.white)
                .withAlphaComponent(completed ? 0.92 : (active ? 0.48 : 0.12)).cgColor
            nodes[index].shadowColor = accent.cgColor
            nodes[index].shadowRadius = active || completed ? 4 : 0
            nodes[index].shadowOpacity = active || completed ? 0.55 : 0
            captions[index].textColor = (active || completed ? accent : NSColor.white)
                .withAlphaComponent(active ? 0.88 : (completed ? 0.60 : 0.30))
        }
        CATransaction.commit()
    }
}

private final class HoldAnimationPreviewView: NSVisualEffectView {
    private struct MotionFrame {
        enum Mode: Equatable { case idle, holding, releasing, result }
        let mode: Mode
        let progress: CGFloat
        let rawProgress: CGFloat
        let boundary: CGFloat
        let boundaryActive: Bool
        let release: CGFloat
        let segment: Int
        let isCancel: Bool
        let elapsed: CGFloat
    }

    private enum ContentState: Int {
        case layer
        case delete
        case close
        case quit
        case cancel
        case cancelled
    }

    let style: HoldPreviewStyle
    var speed: HoldGallerySpeed = .study
    private var epoch = CACurrentMediaTime()
    private var lastContentState: ContentState?
    private var lastNow: CFTimeInterval = 0
    private let appearDelay: TimeInterval = 0.18
    private let thresholds: [TimeInterval] = [0.50, 1.20, 2.20]
    private let boundaryDuration: TimeInterval = 0.16

    private let baseGradient = CAGradientLayer()
    private let styleRoot = CALayer()
    private let boundarySheen = CAGradientLayer()
    private let accentBar = CALayer()
    private let borderTrack = CAShapeLayer()
    private let borderProgress = CAShapeLayer()
    private let contentLayerView = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    // 01 · Liquid Continuum
    private let liquidRoot = CALayer()
    private let liquidBack = CAShapeLayer()
    private let liquidFront = CAShapeLayer()
    private let liquidCrest = CAShapeLayer()

    // 02 · Magnetic Bloom
    private let magneticHalo = CAGradientLayer()
    private var magneticParticles: [CALayer] = []
    private var magneticFieldLines: [CAShapeLayer] = []

    // 03 · Glass Refraction
    private let glassBloom = CAGradientLayer()
    private var glassBands: [CAGradientLayer] = []
    private var glassCaustics: [CAShapeLayer] = []

    // 04 · Aurora Circuit
    private var auroraGradients: [CAGradientLayer] = []
    private var auroraMasks: [CAShapeLayer] = []
    private let auroraSpark = CALayer()

    // 05 · Orbital Charge
    private let orbitalGlow = CAGradientLayer()
    private var orbitalParticles: [CALayer] = []

    // 06 · Pressure Field
    private let pressureWash = CAGradientLayer()
    private var pressureLines: [CAShapeLayer] = []
    private let pressureShockwave = CAShapeLayer()

    // 07 · Kinetic Shutter — a physical, segmented mechanism rather than a fluid field.
    private var shutterSlats: [CAGradientLayer] = []
    private var shutterSeams: [CALayer] = []
    private let shutterBeam = CAGradientLayer()
    private let shutterLatch = CAShapeLayer()

    // 08 · Chrono Instrument — progress is expressed as calibrated time and moving ticks.
    private var chronoTicks: [CALayer] = []
    private let chronoRule = CAShapeLayer()
    private let chronoSweep = CAGradientLayer()
    private let chronoCurrentText = CATextLayer()
    private let chronoPreviousText = CATextLayer()
    private let chronoMarker = CALayer()

    // 09 · Spatial Deck — full-card sheets peel across one another in depth.
    private var deckBackSheets: [CAShapeLayer] = []
    private let deckSheet = CAGradientLayer()
    private let deckMask = CAShapeLayer()
    private let deckFold = CAGradientLayer()
    private let deckEdge = CAShapeLayer()

    init(style: HoldPreviewStyle) {
        self.style = style
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.masksToBounds = true

        baseGradient.startPoint = CGPoint(x: 0, y: 0.5)
        baseGradient.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(baseGradient)

        styleRoot.masksToBounds = true
        layer?.addSublayer(styleRoot)

        setupStyleLayers()

        boundarySheen.colors = [NSColor.clear.cgColor,
                                NSColor.white.withAlphaComponent(0.04).cgColor,
                                NSColor.white.withAlphaComponent(0.34).cgColor,
                                style.accent.withAlphaComponent(0.16).cgColor,
                                NSColor.clear.cgColor]
        boundarySheen.locations = [0, 0.28, 0.48, 0.62, 1]
        boundarySheen.startPoint = CGPoint(x: 0, y: 0.5)
        boundarySheen.endPoint = CGPoint(x: 1, y: 0.5)
        boundarySheen.opacity = 0
        boundarySheen.transform = CATransform3DMakeRotation(-0.10, 0, 0, 1)
        styleRoot.addSublayer(boundarySheen)

        borderTrack.fillColor = NSColor.clear.cgColor
        borderTrack.strokeColor = NSColor.white.withAlphaComponent(0.07).cgColor
        borderTrack.lineWidth = 1.0
        borderProgress.fillColor = NSColor.clear.cgColor
        borderProgress.strokeColor = style.accent.cgColor
        borderProgress.lineWidth = 1.55
        borderProgress.lineCap = .round
        borderProgress.shadowColor = style.accent.cgColor
        borderProgress.shadowRadius = 4
        borderProgress.shadowOpacity = 0.55
        borderProgress.shadowOffset = .zero
        styleRoot.addSublayer(borderTrack)
        styleRoot.addSublayer(borderProgress)

        accentBar.backgroundColor = style.accent.cgColor
        accentBar.cornerRadius = 2
        layer?.addSublayer(accentBar)

        contentLayerView.wantsLayer = true
        iconView.wantsLayer = true
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.imageAlignment = .alignCenter
        iconView.contentTintColor = .white
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .white
        subtitleLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.68)
        contentLayerView.addSubview(iconView)
        contentLayerView.addSubview(titleLabel)
        contentLayerView.addSubview(subtitleLabel)
        addSubview(contentLayerView)

        configureContent(.layer, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let radius = min(27, bounds.height * 0.26)
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.8

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        baseGradient.frame = bounds
        baseGradient.cornerRadius = radius
        styleRoot.frame = bounds
        styleRoot.cornerRadius = radius
        liquidRoot.frame = styleRoot.bounds
        liquidRoot.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        liquidRoot.position = CGPoint(x: styleRoot.bounds.midX, y: styleRoot.bounds.midY)
        [liquidBack, liquidFront, liquidCrest].forEach { $0.frame = liquidRoot.bounds }
        magneticHalo.frame = styleRoot.bounds
        glassBloom.frame = styleRoot.bounds
        auroraGradients.forEach { $0.frame = styleRoot.bounds }
        auroraMasks.forEach { $0.frame = styleRoot.bounds }
        orbitalGlow.frame = styleRoot.bounds
        pressureWash.frame = styleRoot.bounds
        let slatGap: CGFloat = 0.9
        let slatWidth = (styleRoot.bounds.width
            - slatGap * CGFloat(max(0, shutterSlats.count - 1)))
            / CGFloat(max(1, shutterSlats.count))
        for index in shutterSlats.indices {
            let slat = shutterSlats[index]
            let fromBottom = index.isMultiple(of: 2)
            slat.bounds = CGRect(x: 0, y: 0, width: slatWidth, height: styleRoot.bounds.height)
            slat.anchorPoint = CGPoint(x: 0.5, y: fromBottom ? 0 : 1)
            slat.position = CGPoint(x: CGFloat(index) * (slatWidth + slatGap) + slatWidth / 2,
                                    y: fromBottom ? 0 : styleRoot.bounds.height)
            shutterSeams[index].frame = CGRect(
                x: CGFloat(index + 1) * (slatWidth + slatGap) - slatGap,
                y: 8, width: 0.55, height: max(0, styleRoot.bounds.height - 16))
        }
        shutterBeam.frame = styleRoot.bounds
        shutterLatch.frame = styleRoot.bounds

        chronoRule.frame = styleRoot.bounds
        let tickInset: CGFloat = 13
        let tickSpan = max(1, styleRoot.bounds.width - tickInset * 2)
        for index in chronoTicks.indices {
            let fraction = CGFloat(index) / CGFloat(max(1, chronoTicks.count - 1))
            let major = index.isMultiple(of: 5)
            chronoTicks[index].bounds = CGRect(x: 0, y: 0, width: major ? 1.25 : 0.7,
                                                height: major ? 15 : 8)
            chronoTicks[index].position = CGPoint(x: tickInset + tickSpan * fraction,
                                                   y: styleRoot.bounds.height - 12)
        }
        chronoSweep.bounds = CGRect(x: 0, y: 0, width: 42,
                                    height: styleRoot.bounds.height * 1.18)
        chronoCurrentText.frame = CGRect(x: styleRoot.bounds.width * 0.54, y: 9,
                                         width: styleRoot.bounds.width * 0.41, height: 48)
        chronoPreviousText.frame = chronoCurrentText.frame
        chronoMarker.bounds = CGRect(x: 0, y: 0, width: 7, height: 7)

        deckSheet.frame = styleRoot.bounds
        deckMask.frame = styleRoot.bounds
        deckFold.bounds = CGRect(x: 0, y: 0, width: 44,
                                 height: styleRoot.bounds.height * 1.45)
        deckEdge.frame = styleRoot.bounds
        deckBackSheets.forEach { $0.frame = styleRoot.bounds }
        boundarySheen.bounds = CGRect(x: 0, y: 0, width: max(52, bounds.width * 0.23),
                                      height: bounds.height * 1.35)
        boundarySheen.position = CGPoint(x: -boundarySheen.bounds.width, y: bounds.midY)

        let edgePath = CGPath(roundedRect: styleRoot.bounds.insetBy(dx: 1.0, dy: 1.0),
                              cornerWidth: max(2, radius - 1),
                              cornerHeight: max(2, radius - 1), transform: nil)
        borderTrack.frame = styleRoot.bounds
        borderTrack.path = edgePath
        borderProgress.frame = styleRoot.bounds
        borderProgress.path = edgePath

        accentBar.frame = CGRect(x: 0, y: (bounds.height - 46) / 2, width: 4, height: 46)
        contentLayerView.frame = bounds
        let iconSize = min(53, bounds.height * 0.52)
        iconView.frame = NSRect(x: 21, y: (bounds.height - iconSize) / 2,
                                width: iconSize, height: iconSize)
        let textX = 90.0
        titleLabel.frame = NSRect(x: textX, y: bounds.midY + 1,
                                  width: bounds.width - textX - 18, height: 24)
        subtitleLabel.frame = NSRect(x: textX, y: bounds.midY - 22,
                                     width: bounds.width - textX - 18, height: 19)
        CATransaction.commit()

        if lastNow > 0 { _ = update(now: lastNow) }
    }

    func restart(at now: CFTimeInterval) {
        epoch = now
        lastContentState = nil
        _ = update(now: now)
    }

    @discardableResult
    func update(now: CFTimeInterval) -> HoldDemoSnapshot {
        lastNow = now
        let scale: TimeInterval = speed == .actual ? 1.0 : 2.5
        let rest: TimeInterval = speed == .actual ? 0.66 : 0.82
        let heldAfterCancel: TimeInterval = 0.42
        let gestureDuration = (thresholds[2] + heldAfterCancel) * scale
        let releaseDuration = (speed == .actual ? 0.30 : 0.38) * scale
        let resultDuration = (speed == .actual ? 0.48 : 0.42) * scale
        let tail: TimeInterval = speed == .actual ? 0.42 : 0.56
        let total = rest + gestureDuration + releaseDuration + resultDuration + tail
        var local = (now - epoch).truncatingRemainder(dividingBy: total)
        if local < 0 { local += total }

        var state: ContentState = .layer
        var frame = MotionFrame(mode: .idle, progress: 0, rawProgress: 0,
                                boundary: 0, boundaryActive: false, release: 0,
                                segment: 0, isCancel: false, elapsed: 0)
        var railProgress = [CGFloat](repeating: 0, count: 3)
        var activeSegment: Int?
        var isResult = false

        if local >= rest, local < rest + gestureDuration {
            let elapsed = (local - rest) / scale
            railProgress[0] = unit((elapsed - appearDelay) / (thresholds[0] - appearDelay))
            railProgress[1] = unit((elapsed - thresholds[0]) / (thresholds[1] - thresholds[0]))
            railProgress[2] = unit((elapsed - thresholds[1]) / (thresholds[2] - thresholds[1]))

            if elapsed >= appearDelay {
                let segment = thresholds.filter { elapsed >= $0 }.count
                let rawProgress: CGFloat
                if segment == 0 {
                    rawProgress = railProgress[0]
                } else if segment < thresholds.count {
                    rawProgress = railProgress[segment]
                } else {
                    rawProgress = 1
                }

                var boundaryActive = false
                var boundary: CGFloat = 0
                if segment > 0 {
                    let age = elapsed - thresholds[segment - 1]
                    if age >= 0, age < boundaryDuration {
                        boundaryActive = true
                        boundary = unit(age / boundaryDuration)
                    }
                }

                // At an intermediate threshold, visibly finish the old stage, clear the whole
                // component to zero, then catch up to the already-running next real time window.
                // The stage rail above never clears, so history and the next absolute time remain
                // readable while the card performs this local hand-off.
                var displayProgress = rawProgress
                if boundaryActive, segment < thresholds.count {
                    if boundary < 0.62 {
                        displayProgress = 1 - eased(boundary / 0.62)
                    } else {
                        displayProgress = rawProgress * eased((boundary - 0.62) / 0.38)
                    }
                }

                frame = MotionFrame(mode: .holding, progress: displayProgress,
                                    rawProgress: rawProgress, boundary: boundary,
                                    boundaryActive: boundaryActive, release: 0,
                                    segment: segment, isCancel: segment >= thresholds.count,
                                    elapsed: CGFloat(elapsed))
                state = [.delete, .close, .quit, .cancel][min(segment, 3)]
                activeSegment = segment < 3 ? segment : nil
            }
        } else if local >= rest + gestureDuration,
                  local < rest + gestureDuration + releaseDuration {
            let progress = unit((local - rest - gestureDuration) / releaseDuration)
            railProgress = [1, 1, 1]
            frame = MotionFrame(mode: .releasing, progress: 1, rawProgress: 1,
                                boundary: 0, boundaryActive: false, release: progress,
                                segment: 3, isCancel: true,
                                elapsed: CGFloat(thresholds[2] + heldAfterCancel))
            state = .cancelled
            isResult = true
        } else if local < rest + gestureDuration + releaseDuration + resultDuration,
                  local >= rest + gestureDuration + releaseDuration {
            railProgress = [1, 1, 1]
            frame = MotionFrame(mode: .result, progress: 0, rawProgress: 0,
                                boundary: 0, boundaryActive: false, release: 1,
                                segment: 3, isCancel: true,
                                elapsed: CGFloat(thresholds[2] + heldAfterCancel))
            state = .cancelled
            isResult = true
        }
        configureContent(state, animated: lastContentState != nil && state != lastContentState)
        lastContentState = state

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderBase(frame)
        switch style {
        case .liquidContinuum: renderLiquid(frame, now: now)
        case .magneticBloom: renderMagnetic(frame, now: now)
        case .glassRefraction: renderGlass(frame, now: now)
        case .auroraCircuit: renderAurora(frame, now: now)
        case .orbitalCharge: renderOrbit(frame, now: now)
        case .pressureField: renderPressure(frame, now: now)
        case .kineticShutter: renderShutter(frame, now: now)
        case .chronoInstrument: renderChrono(frame, now: now)
        case .spatialDeck: renderDeck(frame, now: now)
        }
        CATransaction.commit()
        return HoldDemoSnapshot(loopFraction: CGFloat(local / total),
                                segmentProgress: railProgress,
                                activeSegment: activeSegment,
                                isResult: isResult)
    }

    private func setupStyleLayers() {
        switch style {
        case .liquidContinuum:
            liquidRoot.opacity = 0
            styleRoot.addSublayer(liquidRoot)
            liquidBack.fillColor = style.secondary.withAlphaComponent(0.34).cgColor
            liquidFront.fillColor = style.accent.withAlphaComponent(0.68).cgColor
            liquidCrest.fillColor = NSColor.clear.cgColor
            liquidCrest.strokeColor = NSColor.white.withAlphaComponent(0.70).cgColor
            liquidCrest.lineWidth = 1.1
            liquidCrest.lineCap = .round
            liquidBack.shadowColor = style.secondary.cgColor
            liquidBack.shadowRadius = 8
            liquidBack.shadowOpacity = 0.28
            liquidRoot.addSublayer(liquidBack)
            liquidRoot.addSublayer(liquidFront)
            liquidRoot.addSublayer(liquidCrest)

        case .magneticBloom:
            magneticHalo.type = .radial
            magneticHalo.colors = [style.accent.withAlphaComponent(0.46).cgColor,
                                   style.secondary.withAlphaComponent(0.12).cgColor,
                                   NSColor.clear.cgColor]
            magneticHalo.locations = [0, 0.38, 1]
            magneticHalo.startPoint = CGPoint(x: 0.16, y: 0.5)
            magneticHalo.endPoint = CGPoint(x: 0.72, y: 0.5)
            styleRoot.addSublayer(magneticHalo)
            for index in 0..<5 {
                let line = CAShapeLayer()
                line.fillColor = NSColor.clear.cgColor
                line.strokeColor = (index.isMultiple(of: 2) ? style.accent : style.secondary)
                    .withAlphaComponent(0.40).cgColor
                line.lineWidth = index.isMultiple(of: 2) ? 0.9 : 0.65
                line.lineCap = .round
                line.lineDashPattern = [2, 5]
                styleRoot.addSublayer(line)
                magneticFieldLines.append(line)
            }
            for index in 0..<12 {
                let size: CGFloat = index.isMultiple(of: 3) ? 5.5 : 3.5
                let particle = CALayer()
                particle.bounds = CGRect(x: 0, y: 0, width: size, height: size)
                particle.cornerRadius = size / 2
                particle.backgroundColor = (index.isMultiple(of: 2) ? style.accent : style.secondary)
                    .cgColor
                particle.shadowColor = style.accent.cgColor
                particle.shadowRadius = 6
                particle.shadowOpacity = 0.85
                particle.shadowOffset = .zero
                styleRoot.addSublayer(particle)
                magneticParticles.append(particle)
            }

        case .glassRefraction:
            glassBloom.type = .radial
            glassBloom.colors = [NSColor.white.withAlphaComponent(0.26).cgColor,
                                 style.accent.withAlphaComponent(0.10).cgColor,
                                 NSColor.clear.cgColor]
            glassBloom.locations = [0, 0.45, 1]
            glassBloom.startPoint = CGPoint(x: 0.52, y: 0.58)
            glassBloom.endPoint = CGPoint(x: 1.0, y: 1.0)
            styleRoot.addSublayer(glassBloom)
            for index in 0..<3 {
                let band = CAGradientLayer()
                let strength = 0.22 - CGFloat(index) * 0.035
                band.colors = [NSColor.clear.cgColor,
                               NSColor.white.withAlphaComponent(strength * 0.55).cgColor,
                               style.accent.withAlphaComponent(strength).cgColor,
                               NSColor.white.withAlphaComponent(strength * 0.82).cgColor,
                               NSColor.clear.cgColor]
                band.locations = [0, 0.24, 0.50, 0.68, 1]
                band.startPoint = CGPoint(x: 0, y: 0.5)
                band.endPoint = CGPoint(x: 1, y: 0.5)
                styleRoot.addSublayer(band)
                glassBands.append(band)
            }
            for index in 0..<3 {
                let caustic = CAShapeLayer()
                caustic.fillColor = NSColor.clear.cgColor
                caustic.strokeColor = NSColor.white.withAlphaComponent(0.42 - CGFloat(index) * 0.08)
                    .cgColor
                caustic.lineWidth = index == 0 ? 1.15 : 0.7
                caustic.lineCap = .round
                styleRoot.addSublayer(caustic)
                glassCaustics.append(caustic)
            }

        case .auroraCircuit:
            for index in 0..<2 {
                let gradient = CAGradientLayer()
                gradient.colors = index == 0
                    ? [style.secondary.withAlphaComponent(0.05).cgColor,
                       style.accent.withAlphaComponent(0.68).cgColor,
                       NSColor.systemPink.withAlphaComponent(0.38).cgColor,
                       style.secondary.withAlphaComponent(0.10).cgColor]
                    : [NSColor.systemTeal.withAlphaComponent(0.05).cgColor,
                       style.secondary.withAlphaComponent(0.52).cgColor,
                       style.accent.withAlphaComponent(0.36).cgColor,
                       NSColor.clear.cgColor]
                gradient.locations = [0, 0.30, 0.66, 1]
                gradient.startPoint = CGPoint(x: 0, y: 0.5)
                gradient.endPoint = CGPoint(x: 1, y: 0.5)
                let mask = CAShapeLayer()
                mask.fillColor = NSColor.white.cgColor
                gradient.mask = mask
                styleRoot.addSublayer(gradient)
                auroraGradients.append(gradient)
                auroraMasks.append(mask)
            }
            auroraSpark.bounds = CGRect(x: 0, y: 0, width: 7, height: 7)
            auroraSpark.cornerRadius = 3.5
            auroraSpark.backgroundColor = NSColor.white.cgColor
            auroraSpark.shadowColor = style.secondary.cgColor
            auroraSpark.shadowRadius = 8
            auroraSpark.shadowOpacity = 1
            auroraSpark.shadowOffset = .zero
            styleRoot.addSublayer(auroraSpark)

        case .orbitalCharge:
            orbitalGlow.type = .radial
            orbitalGlow.colors = [style.accent.withAlphaComponent(0.26).cgColor,
                                  style.secondary.withAlphaComponent(0.06).cgColor,
                                  NSColor.clear.cgColor]
            orbitalGlow.locations = [0, 0.45, 1]
            orbitalGlow.startPoint = CGPoint(x: 0.5, y: 0.5)
            orbitalGlow.endPoint = CGPoint(x: 1, y: 1)
            styleRoot.addSublayer(orbitalGlow)
            for index in 0..<7 {
                let size: CGFloat = index == 0 ? 6.5 : 3.8
                let particle = CALayer()
                particle.bounds = CGRect(x: 0, y: 0, width: size, height: size)
                particle.cornerRadius = size / 2
                particle.backgroundColor = (index.isMultiple(of: 2) ? style.accent : style.secondary)
                    .cgColor
                particle.shadowColor = style.accent.cgColor
                particle.shadowRadius = index == 0 ? 10 : 5
                particle.shadowOpacity = 0.95
                particle.shadowOffset = .zero
                styleRoot.addSublayer(particle)
                orbitalParticles.append(particle)
            }

        case .pressureField:
            pressureWash.colors = [style.secondary.withAlphaComponent(0.05).cgColor,
                                   style.accent.withAlphaComponent(0.13).cgColor,
                                   NSColor.clear.cgColor]
            pressureWash.startPoint = CGPoint(x: 0, y: 0.5)
            pressureWash.endPoint = CGPoint(x: 1, y: 0.5)
            styleRoot.addSublayer(pressureWash)
            for index in 0..<7 {
                let line = CAShapeLayer()
                line.fillColor = NSColor.clear.cgColor
                line.strokeColor = (index == 3 ? style.accent : style.secondary)
                    .withAlphaComponent(index == 3 ? 0.72 : 0.30).cgColor
                line.lineWidth = index == 3 ? 1.35 : 0.72
                line.lineCap = .round
                styleRoot.addSublayer(line)
                pressureLines.append(line)
            }
            pressureShockwave.fillColor = NSColor.clear.cgColor
            pressureShockwave.strokeColor = NSColor.white.withAlphaComponent(0.72).cgColor
            pressureShockwave.lineWidth = 1.2
            pressureShockwave.shadowColor = style.accent.cgColor
            pressureShockwave.shadowRadius = 8
            pressureShockwave.shadowOpacity = 0.7
            pressureShockwave.shadowOffset = .zero
            styleRoot.addSublayer(pressureShockwave)

        case .kineticShutter:
            for index in 0..<9 {
                let slat = CAGradientLayer()
                slat.colors = [style.secondary.withAlphaComponent(0.04).cgColor,
                               NSColor.white.withAlphaComponent(0.20).cgColor,
                               style.accent.withAlphaComponent(0.12).cgColor,
                               NSColor.black.withAlphaComponent(0.08).cgColor]
                slat.locations = [0, 0.28, 0.58, 1]
                slat.startPoint = CGPoint(x: 0, y: 0.5)
                slat.endPoint = CGPoint(x: 1, y: 0.5)
                slat.opacity = 0
                styleRoot.addSublayer(slat)
                shutterSlats.append(slat)

                let seam = CALayer()
                seam.backgroundColor = (index.isMultiple(of: 2) ? style.accent : style.secondary)
                    .withAlphaComponent(0.22).cgColor
                seam.opacity = 0
                styleRoot.addSublayer(seam)
                shutterSeams.append(seam)
            }
            shutterBeam.colors = [NSColor.clear.cgColor,
                                  style.secondary.withAlphaComponent(0.08).cgColor,
                                  NSColor.white.withAlphaComponent(0.68).cgColor,
                                  style.accent.withAlphaComponent(0.10).cgColor,
                                  NSColor.clear.cgColor]
            shutterBeam.locations = [0, 0.35, 0.50, 0.65, 1]
            shutterBeam.startPoint = CGPoint(x: 0, y: 0.5)
            shutterBeam.endPoint = CGPoint(x: 1, y: 0.5)
            shutterBeam.opacity = 0
            styleRoot.addSublayer(shutterBeam)

            shutterLatch.fillColor = style.accent.withAlphaComponent(0.12).cgColor
            shutterLatch.strokeColor = NSColor.white.withAlphaComponent(0.62).cgColor
            shutterLatch.lineWidth = 0.8
            shutterLatch.shadowColor = style.accent.cgColor
            shutterLatch.shadowRadius = 7
            shutterLatch.shadowOpacity = 0.55
            shutterLatch.shadowOffset = .zero
            shutterLatch.opacity = 0
            styleRoot.addSublayer(shutterLatch)

        case .chronoInstrument:
            chronoRule.fillColor = NSColor.clear.cgColor
            chronoRule.strokeColor = style.accent.withAlphaComponent(0.25).cgColor
            chronoRule.lineWidth = 0.75
            chronoRule.lineDashPattern = [1, 4]
            styleRoot.addSublayer(chronoRule)

            for index in 0..<31 {
                let tick = CALayer()
                tick.backgroundColor = (index.isMultiple(of: 5) ? style.accent : NSColor.white)
                    .withAlphaComponent(index.isMultiple(of: 5) ? 0.62 : 0.24).cgColor
                tick.anchorPoint = CGPoint(x: 0.5, y: 1)
                tick.opacity = 0
                styleRoot.addSublayer(tick)
                chronoTicks.append(tick)
            }

            chronoSweep.colors = [NSColor.clear.cgColor,
                                  style.accent.withAlphaComponent(0.06).cgColor,
                                  NSColor.white.withAlphaComponent(0.72).cgColor,
                                  style.secondary.withAlphaComponent(0.09).cgColor,
                                  NSColor.clear.cgColor]
            chronoSweep.locations = [0, 0.30, 0.49, 0.62, 1]
            chronoSweep.startPoint = CGPoint(x: 0, y: 0.5)
            chronoSweep.endPoint = CGPoint(x: 1, y: 0.5)
            chronoSweep.opacity = 0
            styleRoot.addSublayer(chronoSweep)

            for textLayer in [chronoPreviousText, chronoCurrentText] {
                textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
                textLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 42, weight: .bold)
                textLayer.fontSize = 42
                textLayer.alignmentMode = .right
                textLayer.truncationMode = .none
                textLayer.foregroundColor = style.accent.withAlphaComponent(0.13).cgColor
                textLayer.opacity = 0
                styleRoot.addSublayer(textLayer)
            }

            chronoMarker.backgroundColor = style.accent.cgColor
            chronoMarker.cornerRadius = 1.2
            chronoMarker.shadowColor = style.accent.cgColor
            chronoMarker.shadowRadius = 7
            chronoMarker.shadowOpacity = 0.85
            chronoMarker.shadowOffset = .zero
            chronoMarker.opacity = 0
            styleRoot.addSublayer(chronoMarker)

        case .spatialDeck:
            for index in 0..<3 {
                let sheet = CAShapeLayer()
                sheet.fillColor = (index.isMultiple(of: 2) ? style.secondary : style.accent)
                    .withAlphaComponent(0.035 + CGFloat(index) * 0.018).cgColor
                sheet.strokeColor = NSColor.white.withAlphaComponent(0.07 + CGFloat(index) * 0.025)
                    .cgColor
                sheet.lineWidth = 0.75
                sheet.opacity = 0
                styleRoot.addSublayer(sheet)
                deckBackSheets.append(sheet)
            }

            deckSheet.colors = [style.secondary.withAlphaComponent(0.08).cgColor,
                                style.accent.withAlphaComponent(0.24).cgColor,
                                NSColor.white.withAlphaComponent(0.055).cgColor]
            deckSheet.locations = [0, 0.64, 1]
            deckSheet.startPoint = CGPoint(x: 0, y: 0.5)
            deckSheet.endPoint = CGPoint(x: 1, y: 0.5)
            deckMask.fillColor = NSColor.white.cgColor
            deckSheet.mask = deckMask
            deckSheet.opacity = 0
            styleRoot.addSublayer(deckSheet)

            deckFold.colors = [NSColor.clear.cgColor,
                               NSColor.black.withAlphaComponent(0.18).cgColor,
                               NSColor.white.withAlphaComponent(0.38).cgColor,
                               style.accent.withAlphaComponent(0.11).cgColor,
                               NSColor.clear.cgColor]
            deckFold.locations = [0, 0.31, 0.50, 0.66, 1]
            deckFold.startPoint = CGPoint(x: 0, y: 0.5)
            deckFold.endPoint = CGPoint(x: 1, y: 0.5)
            deckFold.opacity = 0
            styleRoot.addSublayer(deckFold)

            deckEdge.fillColor = NSColor.clear.cgColor
            deckEdge.strokeColor = NSColor.white.withAlphaComponent(0.62).cgColor
            deckEdge.lineWidth = 0.9
            deckEdge.shadowColor = style.accent.cgColor
            deckEdge.shadowRadius = 6
            deckEdge.shadowOpacity = 0.55
            deckEdge.shadowOffset = .zero
            deckEdge.opacity = 0
            styleRoot.addSublayer(deckEdge)
        }
    }

    private func configureContent(_ state: ContentState, animated: Bool) {
        guard !animated || state != lastContentState else { return }
        let symbolName: String
        let title: String
        let subtitle: String
        let tint: NSColor
        switch state {
        case .layer:
            symbolName = "square.stack.3d.up.fill"
            title = "Layer 1"
            subtitle = "Current Layer"
            tint = .systemGreen
        case .delete:
            symbolName = "delete.left.fill"
            title = "Delete"
            subtitle = "Hold  ·  Close Window  ·  0.50 s"
            tint = style.accent
        case .close:
            symbolName = "xmark.circle.fill"
            title = "Close Window"
            subtitle = "Keep holding  ·  Quit App  ·  1.20 s"
            tint = style.accent
        case .quit:
            symbolName = "power"
            title = "Quit App"
            subtitle = "Keep holding  ·  Cancel  ·  2.20 s"
            tint = style.accent
        case .cancel:
            symbolName = "arrow.uturn.backward.circle.fill"
            title = "Cancel"
            subtitle = "Release  ·  no action will be sent"
            tint = NSColor(srgbRed: 0.72, green: 0.75, blue: 0.80, alpha: 1)
        case .cancelled:
            symbolName = "checkmark.circle.fill"
            title = "Cancelled"
            subtitle = "No action sent"
            tint = NSColor(srgbRed: 0.66, green: 0.70, blue: 0.76, alpha: 1)
        }

        if animated {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = state == .cancelled ? 0.16 : 0.19
            transition.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.78, 0.18, 1.0)
            contentLayerView.layer?.add(transition, forKey: "galleryContentChange")
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 27, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        iconView.contentTintColor = state == .layer || state == .cancel || state == .cancelled
            ? tint : .white
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        if state != .layer, state != .delete, animated {
            let impact = CAKeyframeAnimation(keyPath: "transform.scale")
            impact.values = [0.94, 1.045, 0.992, 1.0]
            impact.keyTimes = [0.0, 0.40, 0.76, 1.0]
            impact.duration = 0.28
            impact.timingFunction = CAMediaTimingFunction(name: .easeOut)
            iconView.layer?.add(impact, forKey: "galleryThresholdImpact")
        }
    }

    private func renderBase(_ frame: MotionFrame) {
        let active: CGFloat = frame.mode == .holding ? 1 : (frame.mode == .releasing ? 1 - frame.release : 0)
        let impact = frame.boundaryActive ? sin(frame.boundary * .pi) : 0
        let accent = frame.isCancel
            ? NSColor(srgbRed: 0.66, green: 0.70, blue: 0.76, alpha: 1) : style.accent
        baseGradient.colors = [accent.withAlphaComponent(0.055 + active * 0.075).cgColor,
                               accent.withAlphaComponent(0.018 + active * 0.025).cgColor,
                               NSColor.black.withAlphaComponent(0.035).cgColor]
        baseGradient.locations = [0, 0.52, 1]
        layer?.borderColor = accent.withAlphaComponent(0.14 + active * 0.22 + impact * 0.24).cgColor
        accentBar.backgroundColor = (active > 0 ? accent : NSColor.systemGreen).cgColor
        accentBar.opacity = Float(0.68 + active * 0.26)
        borderTrack.opacity = active > 0 ? 1 : 0
        boundarySheen.opacity = Float(impact * (frame.isCancel ? 0.42 : 0.72))
        boundarySheen.position = CGPoint(
            x: -boundarySheen.bounds.width / 2
                + frame.boundary * (bounds.width + boundarySheen.bounds.width),
            y: bounds.midY
        )
    }

    private func renderLiquid(_ frame: MotionFrame, now: CFTimeInterval) {
        let active = frame.mode == .holding || frame.mode == .releasing
        let progress = eased(frame.progress)
        let release = eased(frame.release)
        let accent = visualAccent(frame)
        let secondary = frame.isCancel ? accent.withAlphaComponent(0.72) : style.secondary
        liquidBack.fillColor = secondary.withAlphaComponent(0.14).cgColor
        liquidFront.fillColor = accent.withAlphaComponent(0.38).cgColor
        liquidBack.shadowColor = accent.cgColor
        liquidRoot.opacity = active ? Float(1 - release) : 0
        liquidRoot.transform = CATransform3DIdentity

        // Release resolves into a fine luminous seam before fading, rather than making a full
        // vessel suddenly fall through the floor. Intermediate boundaries use frame.progress's
        // explicit full → empty → next-stage hand-off.
        let shownLevel = min(0.978, progress * (1 - release * 0.94))
        let calm = min(shownLevel / 0.055, 1)
        let time = CGFloat(now - epoch)
        liquidBack.path = waterPath(level: max(0, shownLevel - 0.022),
                                    amplitude: 1.55 * calm, cycles: 1.18,
                                    phase: time * 1.75 + 1.2, crestOnly: false)
        liquidFront.path = waterPath(level: shownLevel, amplitude: 2.15 * calm,
                                     cycles: 1.48, phase: -time * 2.25, crestOnly: false)
        liquidCrest.path = waterPath(level: shownLevel, amplitude: 2.15 * calm,
                                     cycles: 1.48, phase: -time * 2.25, crestOnly: true)

        borderProgress.strokeColor = accent.cgColor
        borderProgress.opacity = active ? Float((0.12 + progress * 0.36) * (1 - release)) : 0
        borderProgress.strokeStart = release * 0.42
        borderProgress.strokeEnd = max(release * 0.42, progress)
    }

    private func renderMagnetic(_ frame: MotionFrame, now: CFTimeInterval) {
        let active = frame.mode == .holding || frame.mode == .releasing
        let progress = eased(frame.progress)
        let release = eased(frame.release)
        let impact = frame.boundaryActive ? sin(frame.boundary * .pi) : 0
        let accent = visualAccent(frame)
        let focus = CGPoint(x: 48, y: bounds.midY)
        magneticHalo.colors = [accent.withAlphaComponent(0.30).cgColor,
                               style.secondary.withAlphaComponent(0.055).cgColor,
                               NSColor.clear.cgColor]
        magneticHalo.opacity = active
            ? Float((0.05 + progress * 0.31 + impact * 0.18) * (1 - release)) : 0
        // Keep the gradient at the card's full bounds. Scaling a CAGradientLayer exposes its
        // rectangular backing edge, which reads as a cheap tinted panel inside the rounded card.
        magneticHalo.transform = CATransform3DIdentity
        let time = CGFloat(now - epoch)

        for (index, line) in magneticFieldLines.enumerated() {
            let source = perimeterPoint(CGFloat(index) / CGFloat(magneticFieldLines.count) * 0.72
                                        + 0.08, inset: 9)
            let path = CGMutablePath()
            path.move(to: source)
            let bend = CGFloat(index - 2) * 10
            path.addCurve(to: focus,
                          control1: CGPoint(x: bounds.midX + 18, y: source.y + bend),
                          control2: CGPoint(x: focus.x + 54, y: focus.y - bend * 0.42))
            line.path = path
            line.strokeColor = accent.withAlphaComponent(0.32).cgColor
            line.lineDashPhase = -time * (7 + CGFloat(index))
            line.opacity = active ? Float((0.08 + progress * 0.24) * (1 - release)) : 0
        }

        for (index, particle) in magneticParticles.enumerated() {
            let fraction = CGFloat(index) / CGFloat(magneticParticles.count)
            let start = perimeterPoint(fraction + time * 0.012, inset: 8)
            let angle = fraction * 2 * .pi + time * (0.82 + CGFloat(index % 3) * 0.12)
            let orbitRadius = (1 - progress) * (18 + CGFloat(index % 4) * 4) + 3.5
            let gathered = CGPoint(x: focus.x + cos(angle) * orbitRadius,
                                   y: focus.y + sin(angle) * orbitRadius * 0.52)
            var point = lerp(start, gathered, progress)
            var opacity: CGFloat = active ? 0.42 + progress * 0.46 : 0
            var scale: CGFloat = 0.62 + progress * 0.32 + impact * 0.12
            if release > 0 {
                let burstAngle = fraction * 2 * .pi + 0.35
                point = CGPoint(x: focus.x + cos(burstAngle) * (5 + release * bounds.width * 0.56),
                                y: focus.y + sin(burstAngle) * (4 + release * bounds.height * 0.58))
                opacity *= 1 - release
                scale *= 1 - release * 0.30
            }
            particle.backgroundColor = (index.isMultiple(of: 2) ? accent : style.secondary).cgColor
            particle.shadowColor = accent.cgColor
            particle.position = point
            particle.opacity = Float(opacity)
            particle.transform = CATransform3DMakeScale(scale, scale, 1)
        }
        borderProgress.strokeColor = accent.cgColor
        borderProgress.opacity = active ? Float((0.18 + progress * 0.40) * (1 - release)) : 0
        borderProgress.strokeStart = 0
        borderProgress.strokeEnd = progress
    }

    private func renderGlass(_ frame: MotionFrame, now: CFTimeInterval) {
        let active = frame.mode == .holding || frame.mode == .releasing
        let progress = eased(frame.progress)
        let release = eased(frame.release)
        let impact = frame.boundaryActive ? sin(frame.boundary * .pi) : 0
        let accent = visualAccent(frame)
        let time = CGFloat(now - epoch)
        let baseX = -bounds.width * 0.20 + progress * bounds.width * 1.40
            + release * bounds.width * 0.48
        for (index, band) in glassBands.enumerated() {
            let bandWidth = 64 + CGFloat(index) * 34
            band.bounds = CGRect(x: 0, y: 0, width: bandWidth, height: bounds.height * 1.42)
            band.position = CGPoint(x: baseX - CGFloat(index) * 13
                                    + sin(time * 0.65 + CGFloat(index)) * 3,
                                    y: bounds.midY)
            band.transform = CATransform3DMakeRotation(-0.10 + CGFloat(index) * 0.018, 0, 0, 1)
            band.opacity = active ? Float((0.52 - CGFloat(index) * 0.08) * (1 - release)) : 0
        }
        for (index, caustic) in glassCaustics.enumerated() {
            caustic.frame = bounds
            caustic.strokeColor = NSColor.white.withAlphaComponent(0.34 - CGFloat(index) * 0.07).cgColor
            caustic.path = verticalSineLine(x: baseX - CGFloat(index) * 11,
                                            amplitude: 2.0 + CGFloat(index) * 0.75,
                                            cycles: 0.82 + CGFloat(index) * 0.18,
                                            phase: time * (1.1 + CGFloat(index) * 0.22))
            caustic.opacity = active ? Float((0.20 + progress * 0.34) * (1 - release)) : 0
        }
        glassBloom.colors = [NSColor.white.withAlphaComponent(0.20).cgColor,
                             accent.withAlphaComponent(0.065).cgColor,
                             NSColor.clear.cgColor]
        glassBloom.startPoint = CGPoint(x: unit(baseX / max(bounds.width, 1)), y: 0.5)
        glassBloom.endPoint = CGPoint(x: unit(baseX / max(bounds.width, 1)) + 0.42, y: 0.92)
        glassBloom.opacity = active ? Float((0.05 + impact * 0.56) * (1 - release)) : 0
        borderProgress.strokeColor = accent.cgColor
        borderProgress.opacity = active ? Float((0.18 + progress * 0.42) * (1 - release)) : 0
        borderProgress.strokeStart = 0
        borderProgress.strokeEnd = progress
    }

    private func renderAurora(_ frame: MotionFrame, now: CFTimeInterval) {
        let active = frame.mode == .holding || frame.mode == .releasing
        let progress = eased(frame.progress)
        let release = eased(frame.release)
        let impact = frame.boundaryActive ? sin(frame.boundary * .pi) : 0
        let accent = visualAccent(frame)
        let time = CGFloat(now - epoch)
        for index in auroraGradients.indices {
            let lift = release * bounds.height * 0.72
            let center = bounds.height * (0.04 + progress * (index == 0 ? 0.64 : 0.49)) + lift
            let thickness = bounds.height * (index == 0 ? 0.24 : 0.17) * (1 + impact * 0.12)
            auroraMasks[index].path = ribbonPath(centerY: center,
                                                  thickness: thickness,
                                                  amplitude: index == 0 ? 6.0 : 4.0,
                                                  cycles: index == 0 ? 1.28 : 1.70,
                                                  phase: time * (index == 0 ? 1.10 : -1.42))
            auroraGradients[index].opacity = active
                ? Float((index == 0 ? 0.54 : 0.37) * (1 - release)) : 0
            auroraGradients[index].transform = CATransform3DMakeTranslation(
                sin(time * (0.42 + CGFloat(index) * 0.12)) * 5, 0, 0)
        }
        auroraSpark.backgroundColor = NSColor.white.cgColor
        auroraSpark.shadowColor = accent.cgColor
        auroraSpark.position = perimeterPoint(progress, inset: 3)
        auroraSpark.opacity = active ? Float((0.18 + progress * 0.70) * (1 - release)) : 0
        let sparkScale = 0.66 + 0.16 * sin(time * 4.4) + impact * 0.34
        auroraSpark.transform = CATransform3DMakeScale(sparkScale, sparkScale, 1)
        borderProgress.strokeColor = accent.cgColor
        borderProgress.opacity = active ? Float((0.24 + progress * 0.54) * (1 - release)) : 0
        borderProgress.strokeStart = 0
        borderProgress.strokeEnd = progress
    }

    private func renderOrbit(_ frame: MotionFrame, now: CFTimeInterval) {
        let active = frame.mode == .holding || frame.mode == .releasing
        let progress = eased(frame.progress)
        let release = eased(frame.release)
        let impact = frame.boundaryActive ? sin(frame.boundary * .pi) : 0
        let accent = visualAccent(frame)
        let time = CGFloat(now - epoch)
        orbitalGlow.colors = [accent.withAlphaComponent(0.18).cgColor,
                              style.secondary.withAlphaComponent(0.035).cgColor,
                              NSColor.clear.cgColor]
        orbitalGlow.opacity = active ? Float((0.04 + progress * 0.23 + impact * 0.12) * (1 - release)) : 0
        let glowScale = 0.76 + progress * 0.20 + sin(time * 2.7) * 0.012
        orbitalGlow.transform = CATransform3DMakeScale(glowScale, glowScale, 1)

        for (index, particle) in orbitalParticles.enumerated() {
            let delay = CGFloat(index) * 0.060
            let available = unit((progress - delay) / max(0.001, 1 - delay))
            let pathProgress = max(0, progress - delay) + sin(time * 0.50 + CGFloat(index)) * 0.004
            var opacity = available * (index == 0 ? 1 : 0.72)
            var point = perimeterPoint(pathProgress, inset: 3.5)
            if release > 0 {
                let ahead = perimeterPoint(pathProgress + 0.012, inset: 3.5)
                let tangent = normalized(CGPoint(x: ahead.x - point.x, y: ahead.y - point.y))
                point.x += tangent.x * release * bounds.width * 0.34
                point.y += tangent.y * release * bounds.height * 0.48
                opacity *= 1 - release
            }
            particle.backgroundColor = (index.isMultiple(of: 2) ? accent : style.secondary).cgColor
            particle.shadowColor = accent.cgColor
            particle.position = point
            particle.opacity = Float(active ? opacity : 0)
            let scale = (index == 0 ? 0.92 : 0.62) + impact * (index == 0 ? 0.26 : 0.10)
            particle.transform = CATransform3DMakeScale(scale, scale, 1)
        }
        borderProgress.strokeColor = accent.cgColor
        borderProgress.opacity = active ? Float((0.24 + progress * 0.66 + impact * 0.10) * (1 - release)) : 0
        borderProgress.strokeStart = 0
        borderProgress.strokeEnd = progress
    }

    private func renderPressure(_ frame: MotionFrame, now: CFTimeInterval) {
        let active = frame.mode == .holding || frame.mode == .releasing
        let progress = eased(frame.progress)
        let release = eased(frame.release)
        let impact = frame.boundaryActive ? sin(frame.boundary * .pi) : 0
        let accent = visualAccent(frame)
        let time = CGFloat(now - epoch)
        pressureWash.colors = [style.secondary.withAlphaComponent(0.025).cgColor,
                               accent.withAlphaComponent(0.075).cgColor,
                               NSColor.clear.cgColor]
        pressureWash.opacity = active ? Float((0.10 + progress * 0.28) * (1 - release)) : 0
        for (index, line) in pressureLines.enumerated() {
            let signed = CGFloat(index - 3)
            let compression = max(0.10, 1 - progress * 0.88)
            let releaseExpansion = release * 1.25
            let y = bounds.midY + signed * 10.5 * (compression + releaseExpansion)
            let amplitude = (0.9 + progress * 2.7 + impact * 1.2) * (1 - release * 0.58)
            line.frame = bounds
            line.strokeColor = (index == 3 ? accent : style.secondary)
                .withAlphaComponent(index == 3 ? 0.68 : 0.26).cgColor
            line.path = sineLine(y: y, amplitude: amplitude,
                                 cycles: 1.05 + CGFloat(abs(index - 3)) * 0.15,
                                 phase: time * (1.45 + progress * 1.65) + signed * 0.52)
            line.opacity = active ? Float((index == 3 ? 0.72 : 0.31) * (1 - release)) : 0
        }
        pressureShockwave.frame = bounds
        let inset = 12 - impact * 10
        pressureShockwave.strokeColor = accent.withAlphaComponent(0.72).cgColor
        pressureShockwave.path = CGPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset * 0.46),
            cornerWidth: max(3, bounds.height * 0.22 - inset * 0.3),
            cornerHeight: max(3, bounds.height * 0.22 - inset * 0.3), transform: nil)
        pressureShockwave.opacity = Float(impact * (1 - release))
        borderProgress.strokeColor = accent.cgColor
        borderProgress.opacity = active ? Float((0.16 + progress * 0.40) * (1 - release)) : 0
        borderProgress.strokeStart = 0
        borderProgress.strokeEnd = progress
    }

    private func renderShutter(_ frame: MotionFrame, now: CFTimeInterval) {
        let active = frame.mode == .holding || frame.mode == .releasing
        let progress = eased(frame.progress)
        let release = eased(frame.release)
        let impact = frame.boundaryActive ? sin(frame.boundary * .pi) : 0
        let accent = visualAccent(frame)
        let time = CGFloat(now - epoch)
        let slatGap: CGFloat = 0.9
        let slatWidth = (bounds.width - slatGap * CGFloat(max(0, shutterSlats.count - 1)))
            / CGFloat(max(1, shutterSlats.count))
        let middle = CGFloat(max(1, shutterSlats.count - 1)) / 2

        boundarySheen.opacity = 0
        borderTrack.opacity = 0
        borderProgress.opacity = 0

        for index in shutterSlats.indices {
            let distance = abs(CGFloat(index) - middle) / max(1, middle)
            // Outer blades engage first; the centre latch closes last. That stagger makes the
            // mechanism legible even in the short 0.32 s first stage.
            let delay = (1 - distance) * 0.17
            let local = unit((progress - delay) / max(0.001, 1 - delay))
            let reveal = eased(local)
            let fromBottom = index.isMultiple(of: 2)
            let sign: CGFloat = fromBottom ? 1 : -1
            let x = CGFloat(index) * (slatWidth + slatGap) + slatWidth / 2
            let baseY: CGFloat = fromBottom ? 0 : bounds.height
            let kick = sign * (impact * 1.9 + release * 11)

            let slat = shutterSlats[index]
            slat.colors = [style.secondary.withAlphaComponent(0.025).cgColor,
                           NSColor.white.withAlphaComponent(0.17 + reveal * 0.07).cgColor,
                           accent.withAlphaComponent(0.07 + reveal * 0.11).cgColor,
                           NSColor.black.withAlphaComponent(0.08).cgColor]
            slat.position = CGPoint(x: x, y: baseY + kick)
            var transform = CATransform3DIdentity
            transform.m34 = -1 / 620
            transform = CATransform3DRotate(transform,
                                            sign * (1 - reveal) * 0.74 + sign * release * 0.16,
                                            1, 0, 0)
            transform = CATransform3DScale(transform, 1, max(0.001, reveal), 1)
            slat.transform = transform
            slat.opacity = active ? Float((0.18 + reveal * 0.74) * (1 - release)) : 0

            let seam = shutterSeams[index]
            seam.backgroundColor = (index.isMultiple(of: 2) ? accent : style.secondary)
                .withAlphaComponent(0.25).cgColor
            seam.opacity = active
                ? Float(unit((reveal - 0.45) / 0.55) * (0.24 + impact * 0.48) * (1 - release))
                : 0
        }

        shutterBeam.colors = [NSColor.clear.cgColor,
                              style.secondary.withAlphaComponent(0.04).cgColor,
                              NSColor.white.withAlphaComponent(0.50 + impact * 0.20).cgColor,
                              accent.withAlphaComponent(0.08).cgColor,
                              NSColor.clear.cgColor]
        shutterBeam.opacity = active
            ? Float((unit((progress - 0.72) / 0.28) * 0.24 + impact * 0.58) * (1 - release))
            : 0
        shutterBeam.transform = CATransform3DMakeTranslation(
            sin(time * 1.2) * 1.4 + (frame.boundaryActive ? (frame.boundary - 0.5) * 9 : 0),
            0, 0)

        let latchProgress = unit((progress - 0.66) / 0.34)
        let halfWidth: CGFloat = 26 + latchProgress * 11
        let diamond: CGFloat = 4.2 + impact * 1.5
        let latchPath = CGMutablePath()
        latchPath.move(to: CGPoint(x: bounds.midX - halfWidth, y: bounds.midY))
        latchPath.addLine(to: CGPoint(x: bounds.midX - diamond, y: bounds.midY))
        latchPath.addLine(to: CGPoint(x: bounds.midX, y: bounds.midY - diamond))
        latchPath.addLine(to: CGPoint(x: bounds.midX + diamond, y: bounds.midY))
        latchPath.addLine(to: CGPoint(x: bounds.midX, y: bounds.midY + diamond))
        latchPath.closeSubpath()
        latchPath.move(to: CGPoint(x: bounds.midX + diamond, y: bounds.midY))
        latchPath.addLine(to: CGPoint(x: bounds.midX + halfWidth, y: bounds.midY))
        shutterLatch.path = latchPath
        shutterLatch.fillColor = accent.withAlphaComponent(0.11 + impact * 0.12).cgColor
        shutterLatch.strokeColor = NSColor.white.withAlphaComponent(0.58 + impact * 0.24).cgColor
        shutterLatch.opacity = active
            ? Float((latchProgress * 0.52 + impact * 0.42) * (1 - release)) : 0
    }

    private func renderChrono(_ frame: MotionFrame, now: CFTimeInterval) {
        let active = frame.mode == .holding || frame.mode == .releasing
        let progress = eased(frame.progress)
        let release = eased(frame.release)
        let impact = frame.boundaryActive ? sin(frame.boundary * .pi) : 0
        let accent = visualAccent(frame)
        let time = CGFloat(now - epoch)
        let inset: CGFloat = 13
        let span = max(1, bounds.width - inset * 2)
        let cursorX = inset + span * progress
        let alpha = active ? 1 - release : 0

        boundarySheen.opacity = 0
        borderTrack.opacity = 0
        borderProgress.opacity = 0

        let rulePath = CGMutablePath()
        rulePath.move(to: CGPoint(x: inset, y: 12))
        rulePath.addLine(to: CGPoint(x: bounds.width - inset, y: 12))
        rulePath.move(to: CGPoint(x: inset, y: bounds.height - 12))
        rulePath.addLine(to: CGPoint(x: bounds.width - inset, y: bounds.height - 12))
        chronoRule.path = rulePath
        chronoRule.strokeColor = accent.withAlphaComponent(0.26).cgColor
        chronoRule.opacity = Float(alpha * (0.28 + progress * 0.28))

        for index in chronoTicks.indices {
            let fraction = CGFloat(index) / CGFloat(max(1, chronoTicks.count - 1))
            let gate = unit((progress - fraction + 0.032) / 0.064)
            let major = index.isMultiple(of: 5)
            let pulse = max(0, 1 - abs(fraction - progress) * 18)
            let tick = chronoTicks[index]
            tick.backgroundColor = (major ? accent : NSColor.white)
                .withAlphaComponent(major ? 0.76 : 0.42).cgColor
            tick.opacity = Float(alpha * (0.08 + gate * (major ? 0.70 : 0.48)
                + pulse * 0.28))
            tick.transform = CATransform3DMakeScale(1,
                0.48 + gate * 0.52 + pulse * 0.22 + impact * (major ? 0.18 : 0.07), 1)
        }

        chronoSweep.colors = [NSColor.clear.cgColor,
                              accent.withAlphaComponent(0.045).cgColor,
                              NSColor.white.withAlphaComponent(0.58 + impact * 0.18).cgColor,
                              style.secondary.withAlphaComponent(0.08).cgColor,
                              NSColor.clear.cgColor]
        chronoSweep.position = CGPoint(x: cursorX + release * 16, y: bounds.midY)
        chronoSweep.opacity = Float(alpha * (0.26 + progress * 0.28 + impact * 0.34))
        chronoSweep.transform = CATransform3DMakeRotation(-0.055, 0, 0, 1)

        chronoMarker.backgroundColor = accent.cgColor
        chronoMarker.position = CGPoint(x: cursorX, y: bounds.height - 12)
        let markerScale = 0.72 + progress * 0.18 + impact * 0.42
            + sin(time * 5.1) * 0.035
        var markerTransform = CATransform3DMakeRotation(.pi / 4, 0, 0, 1)
        markerTransform = CATransform3DScale(markerTransform, markerScale, markerScale, 1)
        chronoMarker.transform = markerTransform
        chronoMarker.opacity = Float(alpha * (0.52 + progress * 0.40))

        let labels = ["0.50", "1.20", "2.20", "SAFE"]
        let currentIndex = min(max(0, frame.segment), labels.count - 1)
        let basePosition = CGPoint(x: bounds.width * 0.745, y: 33)
        chronoCurrentText.string = labels[currentIndex]
        chronoCurrentText.foregroundColor = accent.withAlphaComponent(0.15).cgColor
        if frame.boundaryActive, frame.segment > 0 {
            let enter = eased(frame.boundary)
            chronoPreviousText.string = labels[min(frame.segment - 1, labels.count - 1)]
            chronoPreviousText.foregroundColor = style.accent.withAlphaComponent(0.15).cgColor
            chronoPreviousText.position = CGPoint(x: basePosition.x,
                                                   y: basePosition.y + enter * 23)
            chronoPreviousText.opacity = Float(alpha * (1 - enter) * 0.96)
            chronoCurrentText.position = CGPoint(x: basePosition.x,
                                                  y: basePosition.y - (1 - enter) * 23)
            chronoCurrentText.opacity = Float(alpha * enter)
        } else {
            chronoPreviousText.opacity = 0
            chronoCurrentText.position = basePosition
            chronoCurrentText.opacity = Float(alpha * 0.92)
        }
    }

    private func renderDeck(_ frame: MotionFrame, now: CFTimeInterval) {
        let active = frame.mode == .holding || frame.mode == .releasing
        let progress = eased(frame.progress)
        let release = eased(frame.release)
        let impact = frame.boundaryActive ? sin(frame.boundary * .pi) : 0
        let time = CGFloat(now - epoch)
        let stageColors = [style.accent, style.secondary,
                           NSColor(srgbRed: 1.00, green: 0.72, blue: 0.24, alpha: 1)]
        let accent = frame.isCancel
            ? NSColor(srgbRed: 0.66, green: 0.70, blue: 0.76, alpha: 1)
            : stageColors[min(frame.segment, 2)]
        let companion = frame.isCancel ? accent : stageColors[(min(frame.segment, 2) + 1) % 3]
        let direction: CGFloat = frame.segment.isMultiple(of: 2) ? 1 : -1
        let alpha = active ? 1 - release : 0
        let tilt: CGFloat = 19

        boundarySheen.opacity = 0
        borderTrack.opacity = 0
        borderProgress.opacity = 0

        for index in deckBackSheets.indices {
            let depth = CGFloat(index + 1)
            let offset = depth * (2.4 + impact * 1.2)
            let rect = bounds.insetBy(dx: 5 + depth * 2.5, dy: 5 + depth * 2.0)
                .offsetBy(dx: -direction * offset, dy: direction * offset * 0.36)
            deckBackSheets[index].path = CGPath(
                roundedRect: rect,
                cornerWidth: max(4, bounds.height * 0.20 - depth),
                cornerHeight: max(4, bounds.height * 0.20 - depth), transform: nil)
            deckBackSheets[index].fillColor = (index.isMultiple(of: 2) ? companion : accent)
                .withAlphaComponent(0.026 + depth * 0.018).cgColor
            deckBackSheets[index].strokeColor = accent
                .withAlphaComponent(0.07 + depth * 0.035).cgColor
            deckBackSheets[index].opacity = Float(alpha * (0.42 + progress * 0.44))
        }

        let path = CGMutablePath()
        let topX: CGFloat
        let bottomX: CGFloat
        if direction > 0 {
            let base = bounds.maxX + tilt - progress * (bounds.width + tilt * 2)
            topX = base + tilt
            bottomX = base - tilt
            path.move(to: CGPoint(x: topX, y: bounds.minY))
            path.addLine(to: CGPoint(x: bounds.maxX + tilt * 2, y: bounds.minY))
            path.addLine(to: CGPoint(x: bounds.maxX + tilt * 2, y: bounds.maxY))
            path.addLine(to: CGPoint(x: bottomX, y: bounds.maxY))
        } else {
            let base = bounds.minX - tilt + progress * (bounds.width + tilt * 2)
            topX = base - tilt
            bottomX = base + tilt
            path.move(to: CGPoint(x: bounds.minX - tilt * 2, y: bounds.minY))
            path.addLine(to: CGPoint(x: topX, y: bounds.minY))
            path.addLine(to: CGPoint(x: bottomX, y: bounds.maxY))
            path.addLine(to: CGPoint(x: bounds.minX - tilt * 2, y: bounds.maxY))
        }
        path.closeSubpath()
        deckMask.path = path
        deckSheet.colors = direction > 0
            ? [companion.withAlphaComponent(0.055).cgColor,
               accent.withAlphaComponent(0.26).cgColor,
               NSColor.white.withAlphaComponent(0.055).cgColor]
            : [NSColor.white.withAlphaComponent(0.055).cgColor,
               accent.withAlphaComponent(0.26).cgColor,
               companion.withAlphaComponent(0.055).cgColor]
        deckSheet.opacity = Float(alpha * (0.52 + progress * 0.32))
        var sheetTransform = CATransform3DIdentity
        sheetTransform.m34 = -1 / 780
        sheetTransform = CATransform3DRotate(sheetTransform,
                                             direction * impact * 0.075,
                                             0, 1, 0)
        sheetTransform = CATransform3DTranslate(sheetTransform, 0,
                                                release * direction * 8, release * 14)
        deckSheet.transform = sheetTransform

        let foldX = (topX + bottomX) / 2
        let foldAngle = atan2(bottomX - topX, max(1, bounds.height))
        deckFold.colors = [NSColor.clear.cgColor,
                           NSColor.black.withAlphaComponent(0.16).cgColor,
                           NSColor.white.withAlphaComponent(0.34 + impact * 0.18).cgColor,
                           accent.withAlphaComponent(0.10).cgColor,
                           NSColor.clear.cgColor]
        deckFold.position = CGPoint(x: foldX + sin(time * 0.7) * 0.7, y: bounds.midY)
        deckFold.transform = CATransform3DMakeRotation(foldAngle, 0, 0, 1)
        let foldVisibility = sin(progress * .pi)
        deckFold.opacity = Float(alpha * (foldVisibility * 0.48 + impact * 0.38))

        let edgePath = CGMutablePath()
        edgePath.move(to: CGPoint(x: topX, y: bounds.minY))
        edgePath.addLine(to: CGPoint(x: bottomX, y: bounds.maxY))
        deckEdge.path = edgePath
        deckEdge.strokeColor = NSColor.white.withAlphaComponent(0.58 + impact * 0.22).cgColor
        deckEdge.shadowColor = accent.cgColor
        deckEdge.opacity = Float(alpha * (foldVisibility * 0.60 + impact * 0.28))
    }

    private func visualAccent(_ frame: MotionFrame) -> NSColor {
        frame.isCancel
            ? NSColor(srgbRed: 0.66, green: 0.70, blue: 0.76, alpha: 1)
            : style.accent
    }

    private func unit(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }
    private func unit(_ value: TimeInterval) -> CGFloat { CGFloat(min(1, max(0, value))) }

    private func waterPath(level: CGFloat, amplitude: CGFloat, cycles: CGFloat,
                           phase: CGFloat, crestOnly: Bool) -> CGPath {
        let path = CGMutablePath()
        let samples = 72
        func point(_ index: Int) -> CGPoint {
            let fraction = CGFloat(index) / CGFloat(samples)
            let y = min(max(bounds.height * level
                            + sin(fraction * cycles * 2 * .pi + phase) * amplitude,
                            0), bounds.height)
            return CGPoint(x: bounds.width * fraction, y: y)
        }
        if crestOnly {
            path.move(to: point(0))
            for index in 1...samples { path.addLine(to: point(index)) }
            return path
        }
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: point(0))
        for index in 1...samples { path.addLine(to: point(index)) }
        path.addLine(to: CGPoint(x: bounds.width, y: 0))
        path.closeSubpath()
        return path
    }

    private func sineLine(y: CGFloat, amplitude: CGFloat, cycles: CGFloat,
                          phase: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let samples = 64
        for index in 0...samples {
            let fraction = CGFloat(index) / CGFloat(samples)
            let point = CGPoint(x: bounds.width * fraction,
                                y: y + sin(fraction * cycles * 2 * .pi + phase) * amplitude)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }

    private func verticalSineLine(x: CGFloat, amplitude: CGFloat, cycles: CGFloat,
                                  phase: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let samples = 48
        for index in 0...samples {
            let fraction = CGFloat(index) / CGFloat(samples)
            let point = CGPoint(x: x + sin(fraction * cycles * 2 * .pi + phase) * amplitude,
                                y: bounds.height * fraction)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }

    private func ribbonPath(centerY: CGFloat, thickness: CGFloat, amplitude: CGFloat,
                            cycles: CGFloat, phase: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let samples = 64
        func centre(_ index: Int) -> CGFloat {
            let fraction = CGFloat(index) / CGFloat(samples)
            return centerY + sin(fraction * cycles * 2 * .pi + phase) * amplitude
        }
        path.move(to: CGPoint(x: 0, y: centre(0) - thickness / 2))
        for index in 1...samples {
            path.addLine(to: CGPoint(x: bounds.width * CGFloat(index) / CGFloat(samples),
                                     y: centre(index) - thickness / 2))
        }
        for index in stride(from: samples, through: 0, by: -1) {
            path.addLine(to: CGPoint(x: bounds.width * CGFloat(index) / CGFloat(samples),
                                     y: centre(index) + thickness / 2))
        }
        path.closeSubpath()
        return path
    }

    /// Starts at the lower-left straight and moves clockwise around a rounded rectangle.
    private func perimeterPoint(_ rawProgress: CGFloat, inset: CGFloat) -> CGPoint {
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let radius = min(rect.height * 0.24, 24)
        let horizontal = max(0, rect.width - radius * 2)
        let vertical = max(0, rect.height - radius * 2)
        let arc = .pi * radius / 2
        let perimeter = 2 * horizontal + 2 * vertical + 4 * arc
        var distance = ((rawProgress.truncatingRemainder(dividingBy: 1) + 1)
            .truncatingRemainder(dividingBy: 1)) * perimeter

        func consume(_ length: CGFloat) -> Bool {
            if distance <= length { return true }
            distance -= length
            return false
        }
        if consume(horizontal) {
            return CGPoint(x: rect.minX + radius + distance, y: rect.minY)
        }
        if consume(arc) {
            let angle = -.pi / 2 + distance / radius
            return CGPoint(x: rect.maxX - radius + cos(angle) * radius,
                           y: rect.minY + radius + sin(angle) * radius)
        }
        if consume(vertical) {
            return CGPoint(x: rect.maxX, y: rect.minY + radius + distance)
        }
        if consume(arc) {
            let angle = distance / radius
            return CGPoint(x: rect.maxX - radius + cos(angle) * radius,
                           y: rect.maxY - radius + sin(angle) * radius)
        }
        if consume(horizontal) {
            return CGPoint(x: rect.maxX - radius - distance, y: rect.maxY)
        }
        if consume(arc) {
            let angle = .pi / 2 + distance / radius
            return CGPoint(x: rect.minX + radius + cos(angle) * radius,
                           y: rect.maxY - radius + sin(angle) * radius)
        }
        if consume(vertical) {
            return CGPoint(x: rect.minX, y: rect.maxY - radius - distance)
        }
        let angle = .pi + distance / radius
        return CGPoint(x: rect.minX + radius + cos(angle) * radius,
                       y: rect.minY + radius + sin(angle) * radius)
    }

    private func eased(_ value: CGFloat) -> CGFloat {
        let x = min(1, max(0, value))
        return x * x * (3 - 2 * x)
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ amount: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * amount, y: a.y + (b.y - a.y) * amount)
    }

    private func normalized(_ point: CGPoint) -> CGPoint {
        let length = max(0.0001, hypot(point.x, point.y))
        return CGPoint(x: point.x / length, y: point.y / length)
    }
}

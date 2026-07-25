//
//  TuneSettings.swift
//  HyperVibe (settings UI)
//
//  UI-managed tuning values (cursor + circular scroll). Persisted in UserDefaults so the
//  Settings window is the source of truth; seeded once from the config file's settings.
//

import Foundation

struct TuneSettings: Codable, Equatable {
    var cursorSpeed: Double
    var cursorDeadzone: Double
    var touchMovesScroll: Bool
    var touchScrollSpeed: Double
    var touchScrollAcceleration: Bool
    var touchModeSwitchEnabled: Bool
    var touchModeSwitchButton: String?
    var touchModeSwitchTrigger: String
    var accelMin: Double
    var accelMax: Double
    var accelLowSpeed: Double
    var accelHighSpeed: Double
    var clickRiseThreshold: Double
    var pressMoveMax: Double
    var holdThreshold: Double
    var holdThreshold2: Double
    var holdThreshold3: Double
    var holdCancelGrace: Double
    var doubleTapWindow: Double
    var spacesModeWindow: Double
    var findCursorEnabled: Bool
    var findCursorSensitivity: Double
    var focusFollowsCursor: Bool
    var circularEnabled: Bool
    var circularMinRadius: Double
    var circularStartThreshold: Double
    var circularPixelsPerRadian: Double
    var circularScrollEase: Double
    var circularInvert: Bool
    // Velocity gain for the wheel — see CircularScrollConfig for units (radians per frame).
    var circularAccelMin: Double
    var circularAccelMax: Double
    var circularAccelLowSpeed: Double
    var circularAccelHighSpeed: Double
    var circularAccelCurve: Double

    static let `default` = TuneSettings(
        cursorSpeed: 0.6, cursorDeadzone: 0.006,
        touchMovesScroll: false, touchScrollSpeed: 300, touchScrollAcceleration: false,
        touchModeSwitchEnabled: false, touchModeSwitchButton: nil, touchModeSwitchTrigger: "tap",
        accelMin: 0.4, accelMax: 2.6,
        accelLowSpeed: 0.008, accelHighSpeed: 0.06, clickRiseThreshold: 0.1, pressMoveMax: 0.025,
        holdThreshold: 0.5, holdThreshold2: 1.0, holdThreshold3: 1.6, holdCancelGrace: 1.0,
        doubleTapWindow: 0.3, spacesModeWindow: 5.0, findCursorEnabled: true,
        findCursorSensitivity: 0.5,
        focusFollowsCursor: false,
        circularEnabled: true,
        circularMinRadius: 0.35, circularStartThreshold: 0.35, circularPixelsPerRadian: 75,
        circularScrollEase: 0.3, circularInvert: false,
        circularAccelMin: 1.0, circularAccelMax: 2.5,
        circularAccelLowSpeed: 0.010, circularAccelHighSpeed: 0.070,
        circularAccelCurve: 1.0)

    /// Seed from the config file's settings block (used on first run only).
    init(seed s: Config.Settings) {
        cursorSpeed = s.cursorSpeed
        cursorDeadzone = s.cursorDeadzone
        touchMovesScroll = s.touchMovesScroll
        touchScrollSpeed = s.touchScrollSpeed
        touchScrollAcceleration = s.touchScrollAcceleration
        touchModeSwitchEnabled = s.touchModeSwitchEnabled
        touchModeSwitchButton = s.touchModeSwitchButton
        touchModeSwitchTrigger = s.touchModeSwitchTrigger
        accelMin = s.accelMin
        accelMax = s.accelMax
        accelLowSpeed = s.accelLowSpeed
        accelHighSpeed = s.accelHighSpeed
        clickRiseThreshold = s.clickRiseThreshold
        pressMoveMax = s.pressMoveMax
        holdThreshold = s.holdThreshold
        holdThreshold2 = s.holdThreshold2
        holdThreshold3 = s.holdThreshold3
        holdCancelGrace = s.holdCancelGrace
        doubleTapWindow = s.doubleTapWindow
        spacesModeWindow = s.spacesModeWindow
        findCursorEnabled = s.findCursorEnabled
        findCursorSensitivity = s.findCursorSensitivity
        focusFollowsCursor = s.focusFollowsCursor
        circularEnabled = s.circularScroll.enabled
        circularMinRadius = s.circularScroll.minRadius
        circularStartThreshold = min(max(s.circularScroll.startThreshold, 0), .pi / 4)
        circularPixelsPerRadian = s.circularScroll.pixelsPerRadian
        circularScrollEase = s.circularScroll.scrollEase
        circularInvert = s.circularScroll.invert
        circularAccelMin = s.circularScroll.accelMin
        circularAccelMax = s.circularScroll.accelMax
        circularAccelLowSpeed = s.circularScroll.accelLowSpeed
        circularAccelHighSpeed = s.circularScroll.accelHighSpeed
        circularAccelCurve = s.circularScroll.accelCurve
    }

    init(cursorSpeed: Double, cursorDeadzone: Double,
         touchMovesScroll: Bool, touchScrollSpeed: Double, touchScrollAcceleration: Bool,
         touchModeSwitchEnabled: Bool, touchModeSwitchButton: String?,
         touchModeSwitchTrigger: String,
         accelMin: Double, accelMax: Double,
         accelLowSpeed: Double, accelHighSpeed: Double, clickRiseThreshold: Double,
         pressMoveMax: Double, holdThreshold: Double, holdThreshold2: Double, holdThreshold3: Double,
         holdCancelGrace: Double,
         doubleTapWindow: Double,
         spacesModeWindow: Double, findCursorEnabled: Bool, findCursorSensitivity: Double,
         focusFollowsCursor: Bool,
         circularEnabled: Bool,
         circularMinRadius: Double, circularStartThreshold: Double, circularPixelsPerRadian: Double,
         circularScrollEase: Double, circularInvert: Bool,
         circularAccelMin: Double, circularAccelMax: Double,
         circularAccelLowSpeed: Double, circularAccelHighSpeed: Double,
         circularAccelCurve: Double) {
        self.cursorSpeed = cursorSpeed
        self.cursorDeadzone = cursorDeadzone
        self.touchMovesScroll = touchMovesScroll
        self.touchScrollSpeed = touchScrollSpeed
        self.touchScrollAcceleration = touchScrollAcceleration
        self.touchModeSwitchEnabled = touchModeSwitchEnabled
        self.touchModeSwitchButton = touchModeSwitchButton
        self.touchModeSwitchTrigger = touchModeSwitchTrigger
        self.accelMin = accelMin
        self.accelMax = accelMax
        self.accelLowSpeed = accelLowSpeed
        self.accelHighSpeed = accelHighSpeed
        self.clickRiseThreshold = clickRiseThreshold
        self.pressMoveMax = pressMoveMax
        self.holdThreshold = holdThreshold
        self.holdThreshold2 = holdThreshold2
        self.holdThreshold3 = holdThreshold3
        self.holdCancelGrace = holdCancelGrace
        self.doubleTapWindow = doubleTapWindow
        self.spacesModeWindow = spacesModeWindow
        self.findCursorEnabled = findCursorEnabled
        self.findCursorSensitivity = findCursorSensitivity
        self.focusFollowsCursor = focusFollowsCursor
        self.circularEnabled = circularEnabled
        self.circularMinRadius = circularMinRadius
        self.circularStartThreshold = circularStartThreshold
        self.circularPixelsPerRadian = circularPixelsPerRadian
        self.circularScrollEase = circularScrollEase
        self.circularInvert = circularInvert
        self.circularAccelMin = circularAccelMin
        self.circularAccelMax = circularAccelMax
        self.circularAccelLowSpeed = circularAccelLowSpeed
        self.circularAccelHighSpeed = circularAccelHighSpeed
        self.circularAccelCurve = circularAccelCurve
    }

    /// The SiriRemoteCore circular-scroll config this maps to.
    var circularConfig: CircularScrollConfig {
        CircularScrollConfig(
            enabled: circularEnabled,
            minRadius: circularMinRadius,
            startThreshold: circularStartThreshold,
            pixelsPerRadian: circularPixelsPerRadian,
            scrollEase: circularScrollEase,
            invert: circularInvert,
            accelMin: circularAccelMin,
            accelMax: circularAccelMax,
            accelLowSpeed: circularAccelLowSpeed,
            accelHighSpeed: circularAccelHighSpeed,
            accelCurve: circularAccelCurve)
    }

    /// Exact config event reserved by the Touch Surface switch, or nil while disabled/unassigned.
    var touchModeSwitchEventKey: String? {
        guard touchModeSwitchEnabled, let button = touchModeSwitchButton else { return nil }
        let suffix: String
        switch touchModeSwitchTrigger {
        case "double": suffix = ".double"
        case "triple": suffix = ".triple"
        case "hold":   suffix = ".hold"
        case "hold2":  suffix = ".hold2"
        case "hold3":  suffix = ".hold3"
        default:       suffix = ""
        }
        return button + suffix
    }
}

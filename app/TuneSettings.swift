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
    var accelMin: Double
    var accelMax: Double
    var accelLowSpeed: Double
    var accelHighSpeed: Double
    var clickRiseThreshold: Double
    var pressMoveMax: Double
    var holdThreshold: Double
    var holdThreshold2: Double
    var holdThreshold3: Double
    var doubleTapWindow: Double
    var spacesModeWindow: Double
    var findCursorEnabled: Bool
    var circularEnabled: Bool
    var circularMinRadius: Double
    var circularStartThreshold: Double
    var circularPixelsPerRadian: Double
    var circularScrollEase: Double
    var circularInvert: Bool

    static let `default` = TuneSettings(
        cursorSpeed: 0.6, cursorDeadzone: 0.006, accelMin: 0.4, accelMax: 2.6,
        accelLowSpeed: 0.008, accelHighSpeed: 0.06, clickRiseThreshold: 0.1, pressMoveMax: 0.025,
        holdThreshold: 0.5, holdThreshold2: 1.0, holdThreshold3: 1.6,
        doubleTapWindow: 0.3, spacesModeWindow: 5.0, findCursorEnabled: true,
        circularEnabled: true,
        circularMinRadius: 0.35, circularStartThreshold: 0.35, circularPixelsPerRadian: 107,
        circularScrollEase: 0.3, circularInvert: false)

    /// Seed from the config file's settings block (used on first run only).
    init(seed s: Config.Settings) {
        cursorSpeed = s.cursorSpeed
        cursorDeadzone = s.cursorDeadzone
        accelMin = s.accelMin
        accelMax = s.accelMax
        accelLowSpeed = s.accelLowSpeed
        accelHighSpeed = s.accelHighSpeed
        clickRiseThreshold = s.clickRiseThreshold
        pressMoveMax = s.pressMoveMax
        holdThreshold = s.holdThreshold
        holdThreshold2 = s.holdThreshold2
        holdThreshold3 = s.holdThreshold3
        doubleTapWindow = s.doubleTapWindow
        spacesModeWindow = s.spacesModeWindow
        findCursorEnabled = s.findCursorEnabled
        circularEnabled = s.circularScroll.enabled
        circularMinRadius = s.circularScroll.minRadius
        circularStartThreshold = s.circularScroll.startThreshold
        circularPixelsPerRadian = s.circularScroll.pixelsPerRadian
        circularScrollEase = s.circularScroll.scrollEase
        circularInvert = s.circularScroll.invert
    }

    init(cursorSpeed: Double, cursorDeadzone: Double, accelMin: Double, accelMax: Double,
         accelLowSpeed: Double, accelHighSpeed: Double, clickRiseThreshold: Double,
         pressMoveMax: Double, holdThreshold: Double, holdThreshold2: Double, holdThreshold3: Double,
         doubleTapWindow: Double,
         spacesModeWindow: Double, findCursorEnabled: Bool, circularEnabled: Bool,
         circularMinRadius: Double, circularStartThreshold: Double, circularPixelsPerRadian: Double,
         circularScrollEase: Double, circularInvert: Bool) {
        self.cursorSpeed = cursorSpeed
        self.cursorDeadzone = cursorDeadzone
        self.accelMin = accelMin
        self.accelMax = accelMax
        self.accelLowSpeed = accelLowSpeed
        self.accelHighSpeed = accelHighSpeed
        self.clickRiseThreshold = clickRiseThreshold
        self.pressMoveMax = pressMoveMax
        self.holdThreshold = holdThreshold
        self.holdThreshold2 = holdThreshold2
        self.holdThreshold3 = holdThreshold3
        self.doubleTapWindow = doubleTapWindow
        self.spacesModeWindow = spacesModeWindow
        self.findCursorEnabled = findCursorEnabled
        self.circularEnabled = circularEnabled
        self.circularMinRadius = circularMinRadius
        self.circularStartThreshold = circularStartThreshold
        self.circularPixelsPerRadian = circularPixelsPerRadian
        self.circularScrollEase = circularScrollEase
        self.circularInvert = circularInvert
    }

    /// The SiriRemoteCore circular-scroll config this maps to.
    var circularConfig: CircularScrollConfig {
        CircularScrollConfig(
            enabled: circularEnabled,
            minRadius: circularMinRadius,
            startThreshold: circularStartThreshold,
            pixelsPerRadian: circularPixelsPerRadian,
            scrollEase: circularScrollEase,
            invert: circularInvert)
    }
}

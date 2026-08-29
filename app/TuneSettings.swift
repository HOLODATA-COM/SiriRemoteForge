//
//  TuneSettings.swift
//  HyperVibe (settings UI)
//
//  UI-managed tuning and interface preferences. Every value is seeded from and written back to
//  config.jsonc; machine-local state such as window placement is intentionally not represented here.
//

import Foundation

struct TuneSettings: Codable, Equatable {
    var cursorSpeed: Double
    var cursorDeadzone: Double
    var accelMin: Double
    var accelMax: Double
    var accelLowSpeed: Double
    var accelHighSpeed: Double
    var accelCurve: Double
    /// Links only the dimensionless curve bend. Each input keeps its own gain/speed scales.
    var accelerationCurvesLinked: Bool
    var clickRiseThreshold: Double
    var pressMoveMax: Double
    var holdThreshold: Double
    var holdThreshold2: Double
    var holdThreshold3: Double
    var holdCancelGrace: Double
    var doubleTapWindow: Double
    var spacesModeWindow: Double
    var findCursorEnabled: Bool
    var interfaceLanguage: String
    var launchAtLoginEnabled: Bool
    var automaticUpdateChecksEnabled: Bool
    var automaticallyDownloadUpdatesEnabled: Bool
    var menuBarIconEnabled: Bool
    var statusWidgetEnabled: Bool
    var demoRemoteEnabled: Bool
    var layerHUDEnabled: Bool
    var holdHUDEnabled: Bool
    var dragIndicatorEnabled: Bool
    var showSetupWizardOnFirstLaunch: Bool
    var focusFollowsCursor: Bool
    var dictation: Config.DictationSettings
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
        cursorSpeed: 0.6, cursorDeadzone: 0.006, accelMin: 0.4, accelMax: 2.6,
        accelLowSpeed: 0.008, accelHighSpeed: 0.06, accelCurve: 1.0,
        accelerationCurvesLinked: false,
        clickRiseThreshold: 0.1, pressMoveMax: 0.025,
        holdThreshold: 0.5, holdThreshold2: 1.0, holdThreshold3: 1.6, holdCancelGrace: 1.0,
        doubleTapWindow: 0.3, spacesModeWindow: 5.0, findCursorEnabled: true,
        interfaceLanguage: "en", launchAtLoginEnabled: false,
        automaticUpdateChecksEnabled: true, automaticallyDownloadUpdatesEnabled: true,
        menuBarIconEnabled: true,
        statusWidgetEnabled: true, demoRemoteEnabled: false,
        layerHUDEnabled: true, holdHUDEnabled: true,
        dragIndicatorEnabled: true, showSetupWizardOnFirstLaunch: true,
        focusFollowsCursor: false,
        dictation: Config.DictationSettings(),
        circularEnabled: true,
        circularMinRadius: 0.35, circularStartThreshold: 0.35, circularPixelsPerRadian: 75,
        circularScrollEase: 0.3, circularInvert: false,
        circularAccelMin: 1.0, circularAccelMax: 2.5,
        circularAccelLowSpeed: 0.010, circularAccelHighSpeed: 0.070,
        circularAccelCurve: 1.0)

    /// Seed from the config file's settings block at launch and on every hot reload.
    init(seed s: Config.Settings) {
        cursorSpeed = s.cursorSpeed
        cursorDeadzone = s.cursorDeadzone
        accelMin = s.accelMin
        accelMax = s.accelMax
        accelLowSpeed = s.accelLowSpeed
        accelHighSpeed = s.accelHighSpeed
        accelCurve = s.accelCurve
        accelerationCurvesLinked = s.accelerationCurvesLinked
        clickRiseThreshold = s.clickRiseThreshold
        pressMoveMax = s.pressMoveMax
        holdThreshold = s.holdThreshold
        holdThreshold2 = s.holdThreshold2
        holdThreshold3 = s.holdThreshold3
        holdCancelGrace = s.holdCancelGrace
        doubleTapWindow = s.doubleTapWindow
        spacesModeWindow = s.spacesModeWindow
        findCursorEnabled = s.findCursorEnabled
        // Optional core fields are migration shims. Old installs keep their locally selected
        // language and existing SMAppService registration; the next GUI save writes both choices
        // explicitly, after which JSON is the only source of truth.
        interfaceLanguage = s.interfaceLanguage ?? Loc.shared.language.rawValue
        launchAtLoginEnabled = s.launchAtLoginEnabled ?? LaunchAtLogin.state.isOn
        automaticUpdateChecksEnabled = s.automaticUpdateChecksEnabled
        automaticallyDownloadUpdatesEnabled = s.automaticallyDownloadUpdatesEnabled
        menuBarIconEnabled = s.menuBarIconEnabled
        statusWidgetEnabled = s.statusWidgetEnabled
        demoRemoteEnabled = s.demoRemoteEnabled
        layerHUDEnabled = s.layerHUDEnabled
        holdHUDEnabled = s.holdHUDEnabled
        dragIndicatorEnabled = s.dragIndicatorEnabled
        showSetupWizardOnFirstLaunch = s.showSetupWizardOnFirstLaunch
        focusFollowsCursor = s.focusFollowsCursor
        dictation = s.dictation
        circularEnabled = s.circularScroll.enabled
        circularMinRadius = s.circularScroll.minRadius
        circularStartThreshold = s.circularScroll.startThreshold
        circularPixelsPerRadian = s.circularScroll.pixelsPerRadian
        circularScrollEase = s.circularScroll.scrollEase
        circularInvert = s.circularScroll.invert
        circularAccelMin = s.circularScroll.accelMin
        circularAccelMax = s.circularScroll.accelMax
        circularAccelLowSpeed = s.circularScroll.accelLowSpeed
        circularAccelHighSpeed = s.circularScroll.accelHighSpeed
        circularAccelCurve = s.circularScroll.accelCurve
    }

    init(cursorSpeed: Double, cursorDeadzone: Double, accelMin: Double, accelMax: Double,
         accelLowSpeed: Double, accelHighSpeed: Double, accelCurve: Double,
         accelerationCurvesLinked: Bool, clickRiseThreshold: Double,
         pressMoveMax: Double, holdThreshold: Double, holdThreshold2: Double, holdThreshold3: Double,
         holdCancelGrace: Double,
         doubleTapWindow: Double,
         spacesModeWindow: Double, findCursorEnabled: Bool,
         interfaceLanguage: String, launchAtLoginEnabled: Bool,
         automaticUpdateChecksEnabled: Bool, automaticallyDownloadUpdatesEnabled: Bool,
         menuBarIconEnabled: Bool,
         statusWidgetEnabled: Bool, demoRemoteEnabled: Bool,
         layerHUDEnabled: Bool, holdHUDEnabled: Bool,
         dragIndicatorEnabled: Bool, showSetupWizardOnFirstLaunch: Bool,
         focusFollowsCursor: Bool,
         dictation: Config.DictationSettings,
         circularEnabled: Bool,
         circularMinRadius: Double, circularStartThreshold: Double, circularPixelsPerRadian: Double,
         circularScrollEase: Double, circularInvert: Bool,
         circularAccelMin: Double, circularAccelMax: Double,
         circularAccelLowSpeed: Double, circularAccelHighSpeed: Double,
         circularAccelCurve: Double) {
        self.cursorSpeed = cursorSpeed
        self.cursorDeadzone = cursorDeadzone
        self.accelMin = accelMin
        self.accelMax = accelMax
        self.accelLowSpeed = accelLowSpeed
        self.accelHighSpeed = accelHighSpeed
        self.accelCurve = accelCurve
        self.accelerationCurvesLinked = accelerationCurvesLinked
        self.clickRiseThreshold = clickRiseThreshold
        self.pressMoveMax = pressMoveMax
        self.holdThreshold = holdThreshold
        self.holdThreshold2 = holdThreshold2
        self.holdThreshold3 = holdThreshold3
        self.holdCancelGrace = holdCancelGrace
        self.doubleTapWindow = doubleTapWindow
        self.spacesModeWindow = spacesModeWindow
        self.findCursorEnabled = findCursorEnabled
        self.interfaceLanguage = interfaceLanguage
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.automaticUpdateChecksEnabled = automaticUpdateChecksEnabled
        self.automaticallyDownloadUpdatesEnabled = automaticallyDownloadUpdatesEnabled
        self.menuBarIconEnabled = menuBarIconEnabled
        self.statusWidgetEnabled = statusWidgetEnabled
        self.demoRemoteEnabled = demoRemoteEnabled
        self.layerHUDEnabled = layerHUDEnabled
        self.holdHUDEnabled = holdHUDEnabled
        self.dragIndicatorEnabled = dragIndicatorEnabled
        self.showSetupWizardOnFirstLaunch = showSetupWizardOnFirstLaunch
        self.focusFollowsCursor = focusFollowsCursor
        self.dictation = dictation
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
}

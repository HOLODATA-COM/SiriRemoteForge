import XCTest
@testable import SiriRemoteCore

final class ConfigLoaderTests: XCTestCase {
    private func decodeAction(_ json: String) throws -> Action {
        try JSONDecoder().decode(Action.self, from: Data(json.utf8))
    }

    // MARK: - Action decoding (Task 3)

    func testDecodesKeystroke() throws {
        XCTAssertEqual(try decodeAction("{\"action\":\"keystroke\",\"keys\":\"cmd+up\"}"),
                       .keystroke(keys: "cmd+up"))
    }
    func testDecodesShell() throws {
        XCTAssertEqual(try decodeAction("{\"action\":\"shell\",\"command\":\"open -a Safari\"}"),
                       .shell(command: "open -a Safari"))
    }
    func testDecodesModeSwitch() throws {
        XCTAssertEqual(try decodeAction("{\"action\":\"mode\",\"to\":\"media\"}"),
                       .mode(to: "media"))
    }
    func testDecodesLayer() throws {
        // `layer` reuses the `to` key (same as `mode`) to name the momentary layer mode.
        XCTAssertEqual(try decodeAction("{\"action\":\"layer\",\"to\":\"tvLayer\"}"),
                       .layer("tvLayer"))
        XCTAssertEqual(Action.layer("tvLayer").displayLabel, "Layer: tvLayer")
    }
    func testDecodesLayerCycle() throws {
        XCTAssertEqual(try decodeAction("{\"action\":\"layerCycle\"}"), .layerCycle)
        XCTAssertEqual(Action.layerCycle.displayLabel, "Next Layer")
    }
    func testUnknownActionThrows() {
        XCTAssertThrowsError(try decodeAction("{\"action\":\"nope\"}"))
    }
    func testDecodesRepeatKeyWithDefaults() throws {
        // delay/interval are optional and fall back to 0.3 / 0.045.
        XCTAssertEqual(try decodeAction("{\"action\":\"repeatKey\",\"keys\":\"delete\"}"),
                       .repeatKey(keys: "delete", delay: 0.3, interval: 0.045))
    }
    func testDecodesRepeatKeyWithExplicitTiming() throws {
        XCTAssertEqual(try decodeAction(
            "{\"action\":\"repeatKey\",\"keys\":\"delete\",\"delay\":0.5,\"interval\":0.02}"),
                       .repeatKey(keys: "delete", delay: 0.5, interval: 0.02))
    }
    func testDecodesBrightnessWithValue() throws {
        XCTAssertEqual(try decodeAction("{\"action\":\"brightness\",\"value\":0.5}"),
                       .brightness(0.5))
    }
    func testDecodesBrightnessDefaultsToZero() throws {
        // value is optional and falls back to 0 (minimum) — used by button.power to dim.
        XCTAssertEqual(try decodeAction("{\"action\":\"brightness\"}"),
                       .brightness(0))
    }
    func testDecodesRelativeBrightnessSteps() throws {
        XCTAssertEqual(try decodeAction("{\"action\":\"brightnessStep\",\"to\":\"up\"}"),
                       .brightnessStep(direction: 1))
        XCTAssertEqual(try decodeAction("{\"action\":\"brightnessStep\",\"to\":\"down\"}"),
                       .brightnessStep(direction: -1))
    }

    // MARK: - Config decoding (Task 4)

    func testDecodesConfigWithModeAndInherits() throws {
        let json = """
        { "settings": { "defaultMode": "global" },
          "appProfiles": { "com.apple.Safari": "web", "default": "global" },
          "modes": {
            "global": { "button.menu": { "action": "mode", "to": "web" } },
            "web":    { "inherits": "global",
                        "ring.up": { "action": "keystroke", "keys": "cmd+up" } }
          } }
        """
        let cfg = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.settings.defaultMode, "global")
        XCTAssertEqual(cfg.settings.swipeVelocity, 0.5)          // default applied
        XCTAssertEqual(cfg.appProfiles["com.apple.Safari"], "web")
        XCTAssertEqual(cfg.modes["web"]?.inherits, "global")
        XCTAssertEqual(cfg.modes["web"]?.bindings["ring.up"], .keystroke(keys: "cmd+up"))
        XCTAssertNil(cfg.modes["web"]?.bindings["inherits"])     // inherits is not a binding
    }

    // MARK: - ConfigLoader load + validation (Task 5)

    func testLoadStripsCommentsAndValidates() throws {
        let text = """
        { // my config
          "settings": { "defaultMode": "global" },
          "modes": { "global": {} } }
        """
        let cfg = try ConfigLoader.load(text)
        XCTAssertEqual(cfg.settings.defaultMode, "global")
    }
    func testDefaultModeMustExist() {
        let text = "{ \"settings\": { \"defaultMode\": \"nope\" }, \"modes\": { \"global\": {} } }"
        XCTAssertThrowsError(try ConfigLoader.load(text)) { error in
            XCTAssertEqual(error as? ConfigError, .validation("defaultMode 'nope' not in modes"))
        }
    }
    func testAppProfileMustPointToExistingMode() {
        let text = """
        { "settings": { "defaultMode": "global" },
          "appProfiles": { "com.apple.Safari": "ghost" },
          "modes": { "global": {} } }
        """
        XCTAssertThrowsError(try ConfigLoader.load(text)) { error in
            XCTAssertEqual(error as? ConfigError,
                           .validation("appProfiles['com.apple.Safari'] -> unknown mode 'ghost'"))
        }
    }
    func testCursorSettingsDefaultsAndOverrides() throws {
        let defaults = try ConfigLoader.load(
            "{ \"settings\": { \"defaultMode\": \"g\" }, \"modes\": { \"g\": {} } }")
        XCTAssertEqual(defaults.settings.cursorSpeed, 0.6)
        XCTAssertEqual(defaults.settings.cursorDeadzone, 0.006)
        XCTAssertNil(defaults.settings.interfaceLanguage)
        XCTAssertNil(defaults.settings.launchAtLoginEnabled)
        XCTAssertTrue(defaults.settings.automaticUpdateChecksEnabled)
        XCTAssertTrue(defaults.settings.automaticallyDownloadUpdatesEnabled)
        XCTAssertTrue(defaults.settings.menuBarIconEnabled)
        XCTAssertTrue(defaults.settings.statusWidgetEnabled)
        XCTAssertFalse(defaults.settings.demoRemoteEnabled)
        XCTAssertTrue(defaults.settings.layerHUDEnabled)
        XCTAssertTrue(defaults.settings.holdHUDEnabled)
        XCTAssertTrue(defaults.settings.dragIndicatorEnabled)
        XCTAssertTrue(defaults.settings.showSetupWizardOnFirstLaunch)

        let overridden = try ConfigLoader.load("""
        { "settings": { "defaultMode": "g", "cursorSpeed": 0.35, "cursorDeadzone": 0.01,
                         "interfaceLanguage": "zh", "launchAtLoginEnabled": true,
                         "automaticUpdateChecksEnabled": false,
                         "automaticallyDownloadUpdatesEnabled": false,
                         "menuBarIconEnabled": false, "statusWidgetEnabled": false,
                         "demoRemoteEnabled": true,
                         "layerHUDEnabled": false, "holdHUDEnabled": false,
                         "dragIndicatorEnabled": false,
                         "showSetupWizardOnFirstLaunch": false },
          "modes": { "g": {} } }
        """)
        XCTAssertEqual(overridden.settings.cursorSpeed, 0.35)
        XCTAssertEqual(overridden.settings.cursorDeadzone, 0.01)
        XCTAssertEqual(overridden.settings.interfaceLanguage, "zh")
        XCTAssertEqual(overridden.settings.launchAtLoginEnabled, true)
        XCTAssertFalse(overridden.settings.automaticUpdateChecksEnabled)
        XCTAssertFalse(overridden.settings.automaticallyDownloadUpdatesEnabled)
        XCTAssertFalse(overridden.settings.menuBarIconEnabled)
        XCTAssertFalse(overridden.settings.statusWidgetEnabled)
        XCTAssertTrue(overridden.settings.demoRemoteEnabled)
        XCTAssertFalse(overridden.settings.layerHUDEnabled)
        XCTAssertFalse(overridden.settings.holdHUDEnabled)
        XCTAssertFalse(overridden.settings.dragIndicatorEnabled)
        XCTAssertFalse(overridden.settings.showSetupWizardOnFirstLaunch)
    }

    func testInterfaceLanguageRejectsUnknownValue() {
        XCTAssertThrowsError(try ConfigLoader.load("""
        { "settings": { "defaultMode": "g", "interfaceLanguage": "fr" },
          "modes": { "g": {} } }
        """)) { error in
            XCTAssertEqual(error as? ConfigError,
                           .validation("settings.interfaceLanguage must be 'en' or 'zh' (got 'fr')"))
        }
    }

    func testDictationDefaultsAndOverrides() throws {
        let defaults = try ConfigLoader.load(
            "{ \"settings\": { \"defaultMode\": \"g\" }, \"modes\": { \"g\": {} } }")
        XCTAssertFalse(defaults.settings.dictation.enabled)
        XCTAssertEqual(defaults.settings.dictation.activeMode, .final)
        XCTAssertEqual(defaults.settings.dictation.outputMode, .final)
        XCTAssertEqual(defaults.settings.dictation.finalModel, "gpt-transcribe")
        XCTAssertEqual(defaults.settings.dictation.streamingModel, "gpt-live-transcribe")
        XCTAssertEqual(defaults.settings.dictation.languageHints, ["zh", "en"])
        XCTAssertEqual(defaults.settings.dictation.cleanupProvider, .deepSeek)
        XCTAssertTrue(defaults.settings.dictation.selectionEditingEnabled)
        XCTAssertEqual(defaults.settings.dictation.selectionEditProvider, .deepSeek)
        XCTAssertTrue(defaults.settings.dictation.copyLastOnSideButtonDouble)
        XCTAssertTrue(defaults.settings.dictation.feedbackSoundsEnabled)
        XCTAssertEqual(defaults.settings.dictation.feedbackSoundVolume, 0.55)
        XCTAssertTrue(defaults.settings.dictation.pipelineOverlayEnabled)
        XCTAssertEqual(defaults.settings.dictation.minimumRecordingSeconds, 1)
        XCTAssertTrue(defaults.settings.dictation.layerModes.isEmpty)
        XCTAssertNil(defaults.settings.dictation.resolvedOutputMode(for: "BASE"))

        let configured = try ConfigLoader.load("""
        { "settings": { "defaultMode": "g", "dictation": {
            "enabled": true, "activeMode": "final", "outputMode": "streaming",
            "layerModes": { "BASE": "existing", "L1": "final", "L2": "streaming" },
            "finalModel": "final-x", "streamingModel": "live-x",
            "languageHints": ["en", "zh"], "cleanupProvider": "deepseek",
            "selectionEditingEnabled": false, "selectionEditProvider": "openai",
            "openAICleanupModel": "clean-a", "deepSeekCleanupModel": "clean-d",
            "autoInsert": false, "copyOnFailure": false,
            "restoreClipboardAfterInsert": false,
            "copyLastOnSideButtonDouble": false,
            "feedbackSoundsEnabled": false, "feedbackSoundVolume": 0.32,
            "pipelineOverlayEnabled": false,
            "minimumRecordingSeconds": 1.5,
            "maxRecordingSeconds": 45,
            "dictionary": [{ "term": "HyperVibe", "aliases": ["hyper vibe"] }]
          } }, "modes": { "g": {} } }
        """)
        let voice = configured.settings.dictation
        XCTAssertTrue(voice.enabled)
        XCTAssertEqual(voice.activeMode, .final)
        XCTAssertEqual(voice.outputMode, .streaming)
        XCTAssertEqual(voice.streamingModel, "live-x")
        XCTAssertEqual(voice.cleanupProvider, .deepSeek)
        XCTAssertFalse(voice.selectionEditingEnabled)
        XCTAssertEqual(voice.selectionEditProvider, .openAI)
        XCTAssertFalse(voice.autoInsert)
        XCTAssertTrue(voice.copyOnFailure, "failed delivery is always recovered to the clipboard")
        XCTAssertFalse(voice.restoreClipboardAfterInsert)
        XCTAssertFalse(voice.copyLastOnSideButtonDouble)
        XCTAssertFalse(voice.feedbackSoundsEnabled)
        XCTAssertEqual(voice.feedbackSoundVolume, 0.32)
        XCTAssertFalse(voice.pipelineOverlayEnabled)
        XCTAssertEqual(voice.minimumRecordingSeconds, 1.5)
        XCTAssertEqual(voice.maxRecordingSeconds, 45)
        XCTAssertEqual(voice.dictionary, [.init(term: "HyperVibe", aliases: ["hyper vibe"])])
        // activeMode is global and authoritative; retained legacy per-Layer values cannot alter it.
        XCTAssertEqual(voice.resolvedOutputMode(for: nil), .final)
        XCTAssertEqual(voice.resolvedOutputMode(for: "L1"), .final)
        XCTAssertEqual(voice.resolvedOutputMode(for: "L2"), .final)
        XCTAssertEqual(voice.resolvedOutputMode(for: "UNSPECIFIED"), .final)
        XCTAssertEqual(voice.outputModesToPrewarm(layerIDs: ["BASE", "L1", "L2"]),
                       Set([.final, .streaming]))
        XCTAssertEqual(voice.resolvedSettings(for: "L1")?.outputMode, .final)

        var switched = voice
        switched.selectMode(.external)
        XCTAssertEqual(switched.activeMode, .external)
        XCTAssertTrue(switched.layerModes.isEmpty)
        XCTAssertNil(switched.resolvedOutputMode(for: "L2"))
    }

    func testPartialDictationBlockMigratesWithCurrentDefaults() throws {
        let configured = try ConfigLoader.load("""
        { "settings": { "defaultMode": "g", "dictation": {
            "enabled": true, "outputMode": "streaming",
            "dictionary": [{ "term": "HyperVibe" }]
          } }, "modes": { "g": {} } }
        """)
        let voice = configured.settings.dictation
        XCTAssertTrue(voice.enabled)
        XCTAssertEqual(voice.activeMode, .streaming) // migrated from the former outputMode field
        XCTAssertEqual(voice.outputMode, .streaming)
        XCTAssertEqual(voice.finalModel, "gpt-transcribe")
        XCTAssertEqual(voice.streamingModel, "gpt-live-transcribe")
        XCTAssertEqual(voice.cleanupProvider, .deepSeek)
        XCTAssertTrue(voice.selectionEditingEnabled)
        XCTAssertEqual(voice.selectionEditProvider, .deepSeek)
        XCTAssertEqual(voice.dictionary, [.init(term: "HyperVibe")])
        XCTAssertTrue(voice.layerModes.isEmpty)
        XCTAssertTrue(voice.feedbackSoundsEnabled)
        XCTAssertEqual(voice.feedbackSoundVolume, 0.55)
        XCTAssertTrue(voice.pipelineOverlayEnabled)
        XCTAssertEqual(voice.minimumRecordingSeconds, 1)
        XCTAssertEqual(voice.resolvedOutputMode(for: "BASE"), .streaming)
    }

    func testDictationValidationRejectsUnsafeOrAmbiguousValues() {
        func document(_ dictation: String) -> String {
            """
            { "settings": { "defaultMode": "g", "dictation": \(dictation) },
              "modes": { "g": {} } }
            """
        }
        func expectValidation(_ dictation: String, _ message: String) {
            XCTAssertThrowsError(try ConfigLoader.load(document(dictation))) { error in
                XCTAssertEqual(error as? ConfigError, .validation(message))
            }
        }
        expectValidation(
            #"{"enabled":true,"finalModel":"","streamingModel":"live"}"#,
            "settings.dictation.finalModel must not be empty"
        )
        expectValidation(
            #"{"maxRecordingSeconds":601}"#,
            "settings.dictation.maxRecordingSeconds must be between 1 and 600"
        )
        expectValidation(
            #"{"minimumRecordingSeconds":31}"#,
            "settings.dictation.minimumRecordingSeconds must be between 0 and 30"
        )
        expectValidation(
            #"{"minimumRecordingSeconds":2,"maxRecordingSeconds":1}"#,
            "settings.dictation.minimumRecordingSeconds must not exceed maxRecordingSeconds"
        )
        expectValidation(
            #"{"feedbackSoundVolume":1.1}"#,
            "settings.dictation.feedbackSoundVolume must be between 0 and 1"
        )
        expectValidation(
            #"{"dictionary":[{"term":" HyperVibe"}]}"#,
            "settings.dictation.dictionary contains an empty or padded term"
        )
        expectValidation(
            #"{"dictionary":[{"term":"HyperVibe"},{"term":"hypervibe"}]}"#,
            "settings.dictation.dictionary contains duplicate term 'hypervibe'"
        )
    }

    func testOrderedLayersDefaultAndOverrides() throws {
        let defaults = try ConfigLoader.load(
            "{ \"settings\": { \"defaultMode\": \"g\" }, \"modes\": { \"g\": {} } }")
        XCTAssertEqual(defaults.settings.layers, [])

        let configured = try ConfigLoader.load("""
        { "settings": {
            "defaultMode": "g",
            "layers": [
              { "id": "BASE", "name": "Daily", "color": "green", "icon": "house.fill" },
              { "id": "L1", "name": "Work", "color": "#FF9500CC", "icon": "hammer.fill" },
              { "id": "L2", "color": "purple" }
            ],
            "icons": {
              "remote.connected": "appletvremote.gen4.fill",
              "voice.copied": "doc.on.doc.fill"
            }
          },
          "modes": { "g": {}, "L1": {}, "L2": {} } }
        """)
        XCTAssertEqual(configured.settings.layers, [
            Config.LayerDefinition(id: "BASE", name: "Daily", color: "green", icon: "house.fill"),
            Config.LayerDefinition(id: "L1", name: "Work", color: "#FF9500CC", icon: "hammer.fill"),
            Config.LayerDefinition(id: "L2", name: nil, color: "purple")
        ])
        XCTAssertEqual(configured.settings.icons, [
            "remote.connected": "appletvremote.gen4.fill",
            "voice.copied": "doc.on.doc.fill",
        ])
    }

    func testInterfaceIconNamesRejectEmptyOrPaddedValues() {
        XCTAssertThrowsError(try ConfigLoader.load("""
        { "settings": { "defaultMode": "g", "icons": { "voice.copied": " doc.fill" } },
          "modes": { "g": {} } }
        """)) { error in
            XCTAssertEqual(error as? ConfigError,
                           .validation("settings.icons keys and values must be non-empty, unpadded names"))
        }
        XCTAssertThrowsError(try ConfigLoader.load("""
        { "settings": { "defaultMode": "g", "layers": [
            { "id": "BASE", "icon": "  " }
          ] }, "modes": { "g": {} } }
        """)) { error in
            XCTAssertEqual(error as? ConfigError,
                           .validation("settings.layers['BASE'].icon must be a non-empty SF Symbol name"))
        }
    }

    func testLegacyLayerHUDMigratesInDeterministicOrder() throws {
        let configured = try ConfigLoader.load("""
        { "settings": { "defaultMode": "g", "layerHUD": {
              "L2": { "label": "Third", "color": "purple" },
              "BASE": { "label": "First", "color": "green" },
              "L1": { "label": "Second", "color": "blue" }
            } },
          "modes": { "g": {}, "L1": {}, "L2": {} } }
        """)
        XCTAssertEqual(configured.settings.layers.map(\.id), ["BASE", "L1", "L2"])
        XCTAssertEqual(configured.settings.layers.map(\.name), ["First", "Second", "Third"])

        // A presentation-only legacy dictionary did not require a BASE override or a corresponding
        // mode. Preserve that compatibility; migration supplies the missing BASE entry itself.
        let partial = try ConfigLoader.load("""
        { "settings": { "defaultMode": "g", "layerHUD": {
              "L1": { "label": "Work", "color": "blue" }
            } },
          "modes": { "g": {} } }
        """)
        XCTAssertEqual(partial.settings.layers.map(\.id), ["BASE", "L1"])
    }

    func testLayersRejectMoreThanTenEntries() {
        let definitions = (["BASE"] + (1...10).map { "L\($0)" })
            .map { "{ \"id\": \"\($0)\" }" }.joined(separator: ",")
        let modes = (["g"] + (1...10).map { "L\($0)" })
            .map { "\"\($0)\": {}" }.joined(separator: ",")
        XCTAssertThrowsError(try ConfigLoader.load("""
        { "settings": { "defaultMode": "g", "layers": [\(definitions)] },
          "modes": { \(modes) } }
        """)) { error in
            XCTAssertEqual(error as? ConfigError,
                           .validation("settings.layers supports at most 10 layers"))
        }
    }

    func testLayersRequireBaseFirstUniqueIDsAndExistingModes() {
        XCTAssertThrowsError(try ConfigLoader.load("""
        { "settings": { "defaultMode": "g", "layers": [{"id":"L1"}] },
          "modes": { "g": {}, "L1": {} } }
        """)) { error in
            XCTAssertEqual(error as? ConfigError,
                           .validation("settings.layers must start with id 'BASE'"))
        }
        XCTAssertThrowsError(try ConfigLoader.load("""
        { "settings": { "defaultMode": "g", "layers": [{"id":"BASE"},{"id":"base"}] },
          "modes": { "g": {}, "base": {} } }
        """)) { error in
            XCTAssertEqual(error as? ConfigError,
                           .validation("settings.layers contains duplicate id 'base'"))
        }
        XCTAssertThrowsError(try ConfigLoader.load("""
        { "settings": { "defaultMode": "g", "layers": [{"id":"BASE"},{"id":"L1"}] },
          "modes": { "g": { "button.tv": { "action": "layerCycle" } } } }
        """)) { error in
            XCTAssertEqual(error as? ConfigError,
                           .validation("settings.layers id 'L1' is not in modes"))
        }
    }

    func testHoldStageThresholdsDefaultsAndOverrides() throws {
        // Multi-stage long-press thresholds: stage 1 = holdThreshold (0.5), stage 2 = holdThreshold2
        // (1.0), stage 3 = holdThreshold3 (1.6). All optional, decodeIfPresent with those defaults.
        let defaults = try ConfigLoader.load(
            "{ \"settings\": { \"defaultMode\": \"g\" }, \"modes\": { \"g\": {} } }")
        XCTAssertEqual(defaults.settings.holdThreshold, 0.5)
        XCTAssertEqual(defaults.settings.holdThreshold2, 1.0)
        XCTAssertEqual(defaults.settings.holdThreshold3, 1.6)

        let overridden = try ConfigLoader.load("""
        { "settings": { "defaultMode": "g", "holdThreshold": 0.4, "holdThreshold2": 0.9, "holdThreshold3": 1.4 },
          "modes": { "g": {} } }
        """)
        XCTAssertEqual(overridden.settings.holdThreshold, 0.4)
        XCTAssertEqual(overridden.settings.holdThreshold2, 0.9)
        XCTAssertEqual(overridden.settings.holdThreshold3, 1.4)
    }

    func testInheritsCycleRejected() {
        let text = """
        { "settings": { "defaultMode": "a" },
          "modes": { "a": { "inherits": "b" }, "b": { "inherits": "a" } } }
        """
        XCTAssertThrowsError(try ConfigLoader.load(text))
    }
}

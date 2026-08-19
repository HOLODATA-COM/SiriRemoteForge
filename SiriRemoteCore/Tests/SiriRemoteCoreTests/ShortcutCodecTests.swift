import XCTest
@testable import SiriRemoteCore

final class ShortcutCodecTests: XCTestCase {
    func testPhysicalKeyCodesCoverLettersNavigationPunctuationAndFunctionKeys() {
        XCTAssertEqual(ShortcutCodec.keyToken(macKeyCode: 17), "t")
        XCTAssertEqual(ShortcutCodec.keyToken(macKeyCode: 123), "left")
        XCTAssertEqual(ShortcutCodec.keyToken(macKeyCode: 33), "[")
        XCTAssertEqual(ShortcutCodec.keyToken(macKeyCode: 122), "f1")
        XCTAssertEqual(ShortcutCodec.keyToken(macKeyCode: 90), "f20")
        XCTAssertNil(ShortcutCodec.keyToken(macKeyCode: 57)) // Caps Lock is not recordable.
    }

    func testModifierKeyCodesPreserveRightSideIdentity() {
        XCTAssertEqual(ShortcutModifier(macKeyCode: 55), .command)
        XCTAssertEqual(ShortcutModifier(macKeyCode: 54), .rightCommand)
        XCTAssertEqual(ShortcutModifier(macKeyCode: 62), .rightControl)
        XCTAssertEqual(ShortcutModifier(macKeyCode: 61), .rightOption)
        XCTAssertEqual(ShortcutModifier(macKeyCode: 63), .function)
        XCTAssertNil(ShortcutModifier(macKeyCode: 57))
    }

    func testCanonicalOrderingMatchesExistingConfigStyle() {
        XCTAssertEqual(
            ShortcutCodec.canonical(modifiers: [.shift, .command], keyToken: "t"),
            "cmd+shift+t"
        )
        XCTAssertEqual(
            ShortcutCodec.canonical(
                modifiers: [.rightOption, .rightCommand, .rightControl], keyToken: nil),
            "rctrl+rcmd+ropt"
        )
    }

    func testCanonicalRetainsBothPhysicalSidesButRemovesExactDuplicates() {
        XCTAssertEqual(
            ShortcutCodec.canonical(
                modifiers: [.command, .rightCommand, .command], keyToken: "p"),
            "cmd+rcmd+p"
        )
    }

    func testManualAliasesNormalizeToRecorderVocabulary() {
        XCTAssertEqual(ShortcutCodec.normalize(" Command + Shift + T "), "cmd+shift+t")
        XCTAssertEqual(ShortcutCodec.normalize("⌘⇧T"), "cmd+shift+t")
        XCTAssertEqual(ShortcutCodec.normalize("rcontrol+rcommand+ralt"), "rctrl+rcmd+ropt")
        XCTAssertEqual(ShortcutCodec.normalize("control+page-down"), "ctrl+pagedown")
        XCTAssertEqual(ShortcutCodec.normalize("function+F12"), "fn+f12")
        XCTAssertEqual(ShortcutCodec.normalize("return"), "enter")
    }

    func testModifierOnlyChordIsValid() {
        XCTAssertEqual(ShortcutCodec.normalize("rctrl+rcmd+ropt"), "rctrl+rcmd+ropt")
        XCTAssertEqual(ShortcutCodec.normalize("cmd"), "cmd")
    }

    func testInvalidOrAmbiguousManualInputIsRejected() {
        XCTAssertNil(ShortcutCodec.normalize(""))
        XCTAssertNil(ShortcutCodec.normalize("cmd+not-a-key"))
        XCTAssertNil(ShortcutCodec.normalize("cmd+a+b"))
        XCTAssertNil(ShortcutCodec.normalize("capslock"))
    }

    func testCaptureStateRecordsPhysicalMainChordAndRightSideIdentity() {
        var state = ShortcutCaptureState()
        XCTAssertNil(state.modifierChanged(macKeyCode: 54)) // right Command down
        XCTAssertNil(state.modifierChanged(macKeyCode: 60)) // right Shift down
        XCTAssertEqual(
            state.shortcut(macKeyCode: 17, fallbackModifiers: [.command, .shift]),
            "rcmd+rshift+t"
        )
    }

    func testCaptureStateCompletesModifierOnlyChordOnFinalRelease() {
        var state = ShortcutCaptureState()
        XCTAssertNil(state.modifierChanged(macKeyCode: 62))
        XCTAssertNil(state.modifierChanged(macKeyCode: 54))
        XCTAssertNil(state.modifierChanged(macKeyCode: 61))
        XCTAssertNil(state.modifierChanged(macKeyCode: 61))
        XCTAssertNil(state.modifierChanged(macKeyCode: 54))
        XCTAssertEqual(state.modifierChanged(macKeyCode: 62), "rctrl+rcmd+ropt")
    }

    func testCaptureStateUsesGenericFallbackWithoutDuplicatingTrackedFamily() {
        var state = ShortcutCaptureState()
        XCTAssertNil(state.modifierChanged(macKeyCode: 54))
        XCTAssertEqual(
            state.shortcut(macKeyCode: 35, fallbackModifiers: [.command, .option]),
            "rcmd+opt+p"
        )
    }

    func testCaptureStateRecordsFunctionModifierAndFunctionKey() {
        var state = ShortcutCaptureState()
        XCTAssertNil(state.modifierChanged(macKeyCode: 63))
        XCTAssertEqual(
            state.shortcut(macKeyCode: 111, fallbackModifiers: [.function]),
            "fn+f12"
        )
        state.reset()
        XCTAssertNil(state.modifierChanged(macKeyCode: 63))
        XCTAssertEqual(state.modifierChanged(macKeyCode: 63), "fn")
    }
}

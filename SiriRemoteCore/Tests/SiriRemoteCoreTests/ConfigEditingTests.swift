import XCTest
@testable import SiriRemoteCore

/// Tests for the value-semantic config mutators the editor uses (`setBinding`, `addMode`,
/// `removeMode`, `setInherits`, `setAppProfile`, `withSettingsUpdated`). The key invariant: every
/// mutator's output must still LOAD — `ConfigLoader.load(ConfigWriter.serialize(c))` must succeed —
/// so a UI edit can never write a config that the app then rejects.
final class ConfigEditingTests: XCTestCase {

    private func load(_ json: String) throws -> Config { try ConfigLoader.load(json) }

    private func base() throws -> Config {
        try load("""
        { "settings": { "defaultMode": "global" },
          "appProfiles": { "com.apple.Music": "music", "default": "global" },
          "modes": {
            "global": {},
            "music":  { "inherits": "global" },
            "child":  { "inherits": "music" }
          } }
        """)
    }

    /// A mutator result must survive a serialize → load round-trip (never produce an invalid config).
    private func assertReloads(_ c: Config, _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
        do { _ = try ConfigLoader.load(try ConfigWriter.serialize(c)) }
        catch { XCTFail("mutated config failed to reload: \(error) \(msg)", file: file, line: line) }
    }

    func testSetBindingCreatesMissingModeInheritingDefault() throws {
        let c = try base().setBinding("ring.up", to: .keystroke(keys: "up"), inMode: "newapp")
        XCTAssertEqual(c.modes["newapp"]?.inherits, "global")
        XCTAssertEqual(c.modes["newapp"]?.bindings["ring.up"], .keystroke(keys: "up"))
        assertReloads(c)
    }

    func testSetBindingNilRemoves() throws {
        var c = try base().setBinding("ring.up", to: .media(key: "playpause"), inMode: "global")
        XCTAssertNotNil(c.modes["global"]?.bindings["ring.up"])
        c = c.setBinding("ring.up", to: nil, inMode: "global")
        XCTAssertNil(c.modes["global"]?.bindings["ring.up"])
        assertReloads(c)
    }

    func testRemoveModeReparentsDanglingInherits() throws {
        // Removing "music" must not leave "child" inheriting a mode that no longer exists.
        let c = try base().removeMode("music")
        XCTAssertNil(c.modes["music"])
        XCTAssertNil(c.modes["child"]?.inherits, "child should be re-parented to nil, not left dangling")
        XCTAssertNil(c.appProfiles["com.apple.Music"], "appProfiles pointing at the removed mode are dropped")
        assertReloads(c, "removeMode output must still load")
    }

    func testRemoveModeRefusesToRemoveDefault() throws {
        let c = try base().removeMode("global")
        XCTAssertNotNil(c.modes["global"], "the default mode must not be removable")
        assertReloads(c)
    }

    func testWithSettingsUpdatedRoundTrips() throws {
        let c = try base().withSettingsUpdated { s in
            s.cursorSpeed = 2.5
            s.holdThreshold = 0.8
            s.findCursorEnabled = false
        }
        XCTAssertEqual(c.settings.cursorSpeed, 2.5)
        XCTAssertEqual(c.settings.holdThreshold, 0.8)
        XCTAssertEqual(c.settings.findCursorEnabled, false)
        XCTAssertEqual(c.settings.defaultMode, "global", "untouched fields are preserved")
        // The written value must survive a serialize → load round-trip.
        let reloaded = try ConfigLoader.load(try ConfigWriter.serialize(c))
        XCTAssertEqual(reloaded.settings.cursorSpeed, 2.5)
        XCTAssertEqual(reloaded, c)
    }

    func testSetAppProfileAddAndRemove() throws {
        var c = try base().setAppProfile(bundleID: "com.google.Chrome", mode: "global")
        XCTAssertEqual(c.appProfiles["com.google.Chrome"], "global")
        c = c.setAppProfile(bundleID: "com.google.Chrome", mode: nil)
        XCTAssertNil(c.appProfiles["com.google.Chrome"])
        assertReloads(c)
    }
}

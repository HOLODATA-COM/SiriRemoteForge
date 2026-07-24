import XCTest
import Foundation
@testable import SiriRemoteCore

final class CircularScrollTests: XCTestCase {
    private func point(angle: Double, radius: Double = 0.4) -> (Double, Double) {
        (0.5 + radius * cos(angle), 0.5 + radius * sin(angle))
    }
    private func feedSum(_ d: CircularScrollDetector, angles: [Double], radius: Double = 0.4) -> Double {
        var total = 0.0
        for a in angles {
            let p = point(angle: a, radius: radius)
            total += d.feed(x: p.0, y: p.1)
        }
        return total
    }
    private let cfg = CircularScrollConfig(
        enabled: true, minRadius: 0.35, startThreshold: 0.5, pixelsPerRadian: 100,
        scrollEase: 0.3, invert: false)

    // Past the threshold, the summed output equals total rotation minus the start threshold.
    func testCounterClockwiseContinuousRotation() {
        let d = CircularScrollDetector(config: cfg)
        let sum = feedSum(d, angles: [0, 0.4, 0.8, 1.2, 1.6])   // total 1.6, threshold 0.5
        XCTAssertEqual(sum, 1.1, accuracy: 1e-9)
    }
    func testClockwiseIsNegative() {
        let d = CircularScrollDetector(config: cfg)
        let sum = feedSum(d, angles: [0, -0.4, -0.8, -1.2, -1.6])
        XCTAssertEqual(sum, -1.1, accuracy: 1e-9)
    }
    func testBelowThresholdNoOutput() {
        let d = CircularScrollDetector(config: cfg)
        XCTAssertEqual(feedSum(d, angles: [0, 0.2, 0.4]), 0, accuracy: 1e-12)  // acc 0.4 < 0.5
    }
    func testCenterZoneIgnored() {
        let d = CircularScrollDetector(config: cfg)
        XCTAssertEqual(feedSum(d, angles: [0, 0.5, 1.0, 1.5], radius: 0.1), 0, accuracy: 1e-12)
    }
    func testInvertFlipsSign() {
        var c = cfg; c.invert = true
        let d = CircularScrollDetector(config: c)
        XCTAssertEqual(feedSum(d, angles: [0, 0.4, 0.8, 1.2, 1.6]), -1.1, accuracy: 1e-9)
    }
    func testContinuousIsSmooth() {
        // Once started, each frame returns exactly that frame's rotation (no quantization).
        let d = CircularScrollDetector(config: cfg)
        _ = feedSum(d, angles: [0, 0.6])              // crosses threshold (overshoot 0.1)
        let p = point(angle: 0.9)                     // +0.3 rad this frame
        XCTAssertEqual(d.feed(x: p.0, y: p.1), 0.3, accuracy: 1e-9)
    }
    func testResetClearsState() {
        let d = CircularScrollDetector(config: cfg)
        _ = feedSum(d, angles: [0, 0.4, 0.8, 1.2, 1.6])
        d.reset()
        XCTAssertEqual(feedSum(d, angles: [0, 0.2]), 0, accuracy: 1e-12)
    }

    func testConfigDecodesWithDefaults() throws {
        let cfg = try ConfigLoader.load(
            "{ \"settings\": { \"defaultMode\": \"g\" }, \"modes\": { \"g\": {} } }")
        XCTAssertEqual(cfg.settings.circularScroll, .default)
    }
    func testConfigDecodesOverrides() throws {
        let cfg = try ConfigLoader.load("""
        { "settings": { "defaultMode": "g",
            "circularScroll": { "minRadius": 0.4, "invert": true, "pixelsPerRadian": 220 } },
          "modes": { "g": {} } }
        """)
        XCTAssertEqual(cfg.settings.circularScroll.minRadius, 0.4)
        XCTAssertTrue(cfg.settings.circularScroll.invert)
        XCTAssertEqual(cfg.settings.circularScroll.pixelsPerRadian, 220)
        XCTAssertEqual(cfg.settings.circularScroll.startThreshold, CircularScrollConfig.default.startThreshold)
    }
}

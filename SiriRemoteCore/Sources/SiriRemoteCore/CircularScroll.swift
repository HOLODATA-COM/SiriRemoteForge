import Foundation

/// All-tunable parameters for the iPod-style circular-scroll gesture. Center is (0.5, 0.5)
/// in normalized touch coordinates; radius/angles are in normalized units / radians.
public struct CircularScrollConfig: Equatable {
    /// Master on/off.
    public var enabled: Bool
    /// Only touches at least this far from center count (the "outer ring"). 0…~0.707.
    public var minRadius: Double
    /// Radians of accumulated rotation before scrolling starts ("how much to turn before it
    /// starts scrolling").
    public var startThreshold: Double
    /// Scroll pixels per radian of rotation — the scroll speed. Applied continuously each frame
    /// so scrolling is smooth, not stepped.
    public var pixelsPerRadian: Double
    /// Position-follow smoothing (0…1): how fast the scroll eases toward the total rotation each
    /// frame. Smaller = smoother but laggier; larger = snappier but jerkier.
    public var scrollEase: Double
    /// Flip scroll direction (set on hardware once we see which way feels right).
    public var invert: Bool

    public init(enabled: Bool, minRadius: Double, startThreshold: Double,
                pixelsPerRadian: Double, scrollEase: Double, invert: Bool) {
        self.enabled = enabled
        self.minRadius = minRadius
        self.startThreshold = startThreshold
        self.pixelsPerRadian = pixelsPerRadian
        self.scrollEase = scrollEase
        self.invert = invert
    }

    public static let `default` = CircularScrollConfig(
        enabled: true, minRadius: 0.35, startThreshold: 0.35, pixelsPerRadian: 107,
        scrollEase: 0.3, invert: false)
}

extension CircularScrollConfig: Decodable {
    private enum K: String, CodingKey {
        case enabled, minRadius, startThreshold, pixelsPerRadian, scrollEase, invert
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let d = CircularScrollConfig.default
        enabled         = try c.decodeIfPresent(Bool.self,   forKey: .enabled)         ?? d.enabled
        minRadius       = try c.decodeIfPresent(Double.self, forKey: .minRadius)       ?? d.minRadius
        startThreshold  = try c.decodeIfPresent(Double.self, forKey: .startThreshold)  ?? d.startThreshold
        pixelsPerRadian = try c.decodeIfPresent(Double.self, forKey: .pixelsPerRadian) ?? d.pixelsPerRadian
        scrollEase      = try c.decodeIfPresent(Double.self, forKey: .scrollEase)      ?? d.scrollEase
        invert          = try c.decodeIfPresent(Bool.self,   forKey: .invert)          ?? d.invert
    }
}

extension CircularScrollConfig: Encodable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(minRadius, forKey: .minRadius)
        try c.encode(startThreshold, forKey: .startThreshold)
        try c.encode(pixelsPerRadian, forKey: .pixelsPerRadian)
        try c.encode(scrollEase, forKey: .scrollEase)
        try c.encode(invert, forKey: .invert)
    }
}

/// Detects circular finger motion on the pad's outer ring and converts it to a continuous,
/// signed rotation amount per frame (for smooth scrolling). Pure logic; unit-tested.
public final class CircularScrollDetector {
    private var config: CircularScrollConfig
    private var lastAngle: Double?
    private var accumulated: Double = 0   // net signed rotation this gesture (radians)
    private var started = false           // has |accumulated| crossed startThreshold yet?

    public init(config: CircularScrollConfig) { self.config = config }

    public func update(config: CircularScrollConfig) { self.config = config }

    /// Reset at the start (or end) of a touch session.
    public func reset() {
        lastAngle = nil
        accumulated = 0
        started = false
    }

    /// Feed one normalized touch point. Returns the signed radians of rotation to convert to
    /// scroll *this frame* — continuous, so scrolling is smooth. Returns 0 in the center dead
    /// zone or before the start threshold has been crossed. Sign is already `invert`-adjusted.
    public func feed(x: Double, y: Double) -> Double {
        let dx = x - 0.5, dy = y - 0.5
        let r = (dx * dx + dy * dy).squareRoot()
        guard r >= config.minRadius else {
            // Center zone: not circular. Break angle continuity so re-entering the ring doesn't
            // register a jump, but keep accumulated progress.
            lastAngle = nil
            return 0
        }
        let angle = atan2(dy, dx)
        defer { lastAngle = angle }
        guard let last = lastAngle else { return 0 }

        var delta = angle - last
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        // Ignore implausible single-frame jumps (finger lift / re-touch across the pad).
        if abs(delta) > .pi / 2 { return 0 }

        accumulated += delta
        var out: Double = 0
        if started {
            out = delta
        } else if abs(accumulated) >= config.startThreshold {
            started = true
            // Emit only the overshoot past the threshold so scrolling starts without a jump.
            let sign = accumulated >= 0 ? 1.0 : -1.0
            out = accumulated - sign * config.startThreshold
        }
        return config.invert ? -out : out
    }
}

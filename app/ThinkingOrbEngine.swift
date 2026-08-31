//
//  ThinkingOrbEngine.swift
//  HyperVibe
//
//  Native Swift port of thinking-orbs' portable geometry engine.
//  Upstream: https://github.com/JakubAntalik/thinking-orbs
//  Pinned reference commit: de85557ca220332586d070d8788c0e1d6e877a0d
//  Copyright (c) 2026 Jakub Antalik. Distributed under the MIT License;
//  the complete license is bundled as Resources/ThinkingOrbs-LICENSE.txt.
//


import Foundation

enum ThinkingOrbState: String, CaseIterable {
    case working
    case searching
    case solving
    case listening
    case connecting
    case weaving
    case composing
    case breathing
    case shaping

    var speed: Double {
        switch self {
        case .working: return 1.885
        case .searching: return 2.015
        case .solving: return 1.82
        case .listening: return 4.388
        case .connecting: return 3.315
        case .weaving: return 1.625
        case .composing: return 2.34
        case .breathing: return 3.24
        case .shaping: return 2.405
        }
    }
}

struct ThinkingOrbDot {
    var x: Double
    var y: Double
    var z: Double
    var r: Double
    var white: Double
    var alpha: Double = 1
}

struct ThinkingOrbLine {
    var x1: Double
    var y1: Double
    var x2: Double
    var y2: Double
    var white: Double
    var alpha: Double = 1
    var width: Double
}

struct ThinkingOrbFrame {
    var dots: [ThinkingOrbDot]
    var lines: [ThinkingOrbLine]
}

/// Ten recent perceptual levels, one for every latitude ring in the 64pt wave preset.
/// A nil value leaves the upstream synthetic wave geometry bit-for-bit unchanged.
struct ThinkingOrbAcoustics {
    var ringLevels: [Double]
    var overallLevel: Double
    /// Normalized around a conversational centre: -1 = low, +1 = high.
    var pitch: Double
    var pitchConfidence: Double
    var brightness: Double
}

enum ThinkingOrbTransitionMath {
    static func smoothstep(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
}

enum ThinkingOrbEngine {
    typealias Projector = (Double, Double, Double) -> (Double, Double, Double)

    /// `time` is the raw mode time used by the upstream portable engine. The UI applies the
    /// state's preset speed before calling this method, exactly like ThinkingOrb.tsx.
    static func frame(state: ThinkingOrbState,
                      size: Double = 64,
                      time: Double,
                      acoustics: ThinkingOrbAcoustics? = nil) -> ThinkingOrbFrame {
        switch state {
        case .working: return frameOrbits(size: size, time: time)
        case .searching: return frameGlobe(size: size, time: time)
        case .solving: return frameRubik(size: size, time: time)
        case .listening: return frameWave(size: size, time: time, acoustics: acoustics)
        case .connecting: return frameWeb(size: size, time: time)
        case .weaving: return frameBraid(size: size, time: time)
        case .composing: return frameRibbon(size: size, time: time, breathing: false)
        case .breathing: return frameRibbon(size: size, time: time, breathing: true)
        case .shaping: return frameMorph(size: size, time: time)
        }
    }

    private static func lerp(_ a: Double, _ b: Double, _ f: Double) -> Double {
        a + (b - a) * f
    }

    private static func frac(_ x: Double) -> Double { x - floor(x) }

    private static func hashD(_ a: Double, _ b: Double) -> Double {
        let h = sin(a * 12.9898 + b * 78.233) * 43_758.5453
        return h - floor(h)
    }

    private static func vnoise(_ x: Double, _ y: Double) -> Double {
        let xi = floor(x)
        let yi = floor(y)
        var fx = x - xi
        var fy = y - yi
        fx = fx * fx * (3 - 2 * fx)
        fy = fy * fy * (3 - 2 * fy)
        let a = hashD(xi, yi)
        let b = hashD(xi + 1, yi)
        let c = hashD(xi, yi + 1)
        let d = hashD(xi + 1, yi + 1)
        return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy
    }

    private static func fibDir(_ i: Int, _ n: Int) -> (Double, Double, Double) {
        let golden = Double.pi * (3 - sqrt(5))
        let y = 1 - (2 * (Double(i) + 0.5)) / Double(n)
        let radius = sqrt(1 - y * y)
        let angle = Double(i) * golden
        return (radius * cos(angle), y, radius * sin(angle))
    }

    private static func angleDelta(_ a: Double, _ b: Double) -> Double {
        atan2(sin(a - b), cos(a - b))
    }

    private static func makeProj(yaw: Double, tilt: Double,
                                 cx: Double, cy: Double, scale: Double) -> Projector {
        let st = sin(tilt)
        let ct = cos(tilt)
        let sy = sin(yaw)
        let cyw = cos(yaw)
        return { x, y, z in
            let x1 = x * cyw + z * sy
            let z1 = -x * sy + z * cyw
            let y1 = y * ct - z1 * st
            let z2 = y * st + z1 * ct
            return (cx + x1 * scale, cy - y1 * scale, z2)
        }
    }

    private static func radiusScale(_ size: Double, _ exponent: Double = 0.6) -> Double {
        pow(size / 300, exponent)
    }

    private static func finalize(_ dots: [ThinkingOrbDot],
                                 _ lines: [ThinkingOrbLine] = [],
                                 radiusMinimum: Double = 0.3) -> ThinkingOrbFrame {
        var visible: [ThinkingOrbDot] = []
        visible.reserveCapacity(dots.count)
        for var dot in dots where dot.alpha >= 0.02 {
            dot.r = max(radiusMinimum, dot.r)
            visible.append(dot)
        }
        visible.sort { $0.z < $1.z }
        return ThinkingOrbFrame(dots: visible, lines: lines.filter { $0.alpha >= 0.02 })
    }

    // MARK: Working / orbits

    private static func frameOrbits(size: Double, time: Double) -> ThinkingOrbFrame {
        let center = size / 2
        let radius = (size / 2) * 0.82
        let project = makeProj(yaw: time * 0.12, tilt: 0.3,
                               cx: center, cy: center, scale: 1)
        let rs = radiusScale(size)
        let orbitCount = 12
        let ghostCount = 40
        let particleCount = 3
        var dots: [ThinkingOrbDot] = []
        dots.reserveCapacity(orbitCount * (ghostCount + particleCount))

        for orbit in 0..<orbitCount {
            let h1 = hashD(Double(orbit), 1.7)
            let h2 = hashD(Double(orbit), 5.2)
            let h3 = hashD(Double(orbit), 8.9)
            let orbitRadius = radius * (0.45 + 0.52 * h1)
            let theta = h1 * 2 * .pi
            let phi = acos(2 * h2 - 1)
            let nx = sin(phi) * cos(theta)
            let ny = cos(phi)
            let nz = sin(phi) * sin(theta)
            var ux = -ny
            var uy = nx
            let uz = 0.0
            let ul = max(0.000_001, sqrt(ux * ux + uy * uy))
            ux /= ul
            uy /= ul
            let vx = ny * uz - nz * uy
            let vy = nz * ux - nx * uz
            let vz = nx * uy - ny * ux
            let speed = (0.25 + 0.55 * h3) * (h3 > 0.5 ? 1 : -1)

            for k in 0..<ghostCount {
                let angle = Double(k) / Double(ghostCount) * 2 * .pi
                let point = project((ux * cos(angle) + vx * sin(angle)) * orbitRadius,
                                    (uy * cos(angle) + vy * sin(angle)) * orbitRadius,
                                    (uz * cos(angle) + vz * sin(angle)) * orbitRadius)
                let depth = (point.2 / orbitRadius + 1) / 2
                dots.append(ThinkingOrbDot(x: point.0, y: point.1, z: point.2,
                                           r: 0.9 * rs, white: 0.72,
                                           alpha: 0.5 * (0.4 + 0.6 * depth)))
            }
            for particle in 0..<particleCount {
                let angle = time * speed + Double(particle) / Double(particleCount) * 2 * .pi
                    + h2 * 6
                let point = project((ux * cos(angle) + vx * sin(angle)) * orbitRadius,
                                    (uy * cos(angle) + vy * sin(angle)) * orbitRadius,
                                    (uz * cos(angle) + vz * sin(angle)) * orbitRadius)
                let depth = (point.2 / orbitRadius + 1) / 2
                dots.append(ThinkingOrbDot(x: point.0, y: point.1, z: point.2,
                                           r: (1.2 + 1.6 * depth) * rs,
                                           white: 0.3 - 0.22 * depth))
            }
        }
        return finalize(dots)
    }

    // MARK: Searching / globe

    private static func frameGlobe(size: Double, time: Double) -> ThinkingOrbFrame {
        let spin = 0.5
        let center = size / 2
        let radius = (size / 2) * 0.82
        let tilt = 0.4 + 0.06 * sin(time * 0.35)
        let project = makeProj(yaw: time * spin, tilt: tilt,
                               cx: center, cy: center, scale: radius)
        let scan = time * (spin + (1.7 - spin) * 4.08)
        let rs = radiusScale(size)
        var dots: [ThinkingOrbDot] = []
        let latRings = 11
        let lonDensity = 29
        for latitudeIndex in 0...latRings {
            let latitude = -.pi / 2 + Double(latitudeIndex) / Double(latRings) * .pi
            let cosLatitude = cos(latitude)
            let sinLatitude = sin(latitude)
            let lonCount = max(1, Int((abs(cosLatitude) * Double(lonDensity)).rounded()))
            for longitudeIndex in 0..<lonCount {
                let longitude = Double(longitudeIndex) / Double(lonCount) * 2 * .pi
                let point = project(cosLatitude * cos(longitude), sinLatitude,
                                    cosLatitude * sin(longitude))
                let depth = (point.2 + 1) / 2
                let distance = angleDelta(longitude + time * spin, scan)
                let boost = exp(-(distance * distance) / 0.18) * max(0, point.2)
                dots.append(ThinkingOrbDot(
                    x: point.0, y: point.1, z: point.2,
                    r: (0.69 + 1.955 * depth + boost) * rs,
                    white: 0.62 - 0.54 * depth,
                    alpha: 0.45 + 0.55 * min(1, boost)
                ))
            }
        }
        return finalize(dots)
    }

    // MARK: Solving / rubik

    private struct Move {
        let axis: Int
        let low: Double
        let high: Double
        let angle: Double
    }

    private struct SolveCycle {
        var amounts: [Double]
        var active: Int
    }

    private static func makeMoves(_ count: Int) -> [Move] {
        (0..<count).map { index in
            let i = Double(index)
            let axis = min(2, Int(floor(hashD(i, 2.3) * 3)))
            let low = -1 + 0.5 * Double(min(3, Int(floor(hashD(i, 5.9) * 4))))
            let direction = hashD(i, 7.7) < 0.5 ? 1.0 : -1.0
            return Move(axis: axis, low: low, high: low + 0.5,
                        angle: direction * .pi / 2)
        }
    }

    private static func solveCycle(time: Double, count: Int,
                                   slotDuration: Double, rest: Double) -> SolveCycle {
        let cycleDuration = 2 * Double(count) * slotDuration + rest
        let cycleTime = time.truncatingRemainder(dividingBy: cycleDuration)
        var amounts = [Double](repeating: 0, count: count)
        var active = -1
        if cycleTime < 2 * Double(count) * slotDuration {
            let slot = Int(floor(cycleTime / slotDuration))
            let progress = (cycleTime - Double(slot) * slotDuration) / slotDuration
            let clamped = min(1, progress / 0.7)
            let eased = 1 - pow(1 - clamped, 3)
            if slot < count {
                if slot > 0 { for index in 0..<slot { amounts[index] = 1 } }
                amounts[slot] = eased
                active = slot
            } else {
                let undo = 2 * count - 1 - slot
                if undo > 0 { for index in 0..<undo { amounts[index] = 1 } }
                amounts[undo] = 1 - eased
                active = undo
            }
        }
        return SolveCycle(amounts: amounts, active: active)
    }

    private static func applyMoves(_ input: (Double, Double, Double),
                                   moves: [Move], cycle: SolveCycle)
        -> (Double, Double, Double, Bool) {
        var (x, y, z) = input
        var inActive = false
        for index in moves.indices where cycle.amounts[index] > 0 {
            let move = moves[index]
            let coordinate = move.axis == 0 ? x : (move.axis == 1 ? y : z)
            guard coordinate >= move.low, coordinate < move.high else { continue }
            if index == cycle.active { inActive = true }
            let angle = move.angle * cycle.amounts[index]
            let cosine = cos(angle)
            let sine = sin(angle)
            if move.axis == 0 {
                let y2 = y * cosine - z * sine
                z = y * sine + z * cosine
                y = y2
            } else if move.axis == 1 {
                let x2 = x * cosine + z * sine
                z = -x * sine + z * cosine
                x = x2
            } else {
                let x2 = x * cosine - y * sine
                y = x * sine + y * cosine
                x = x2
            }
        }
        return (x, y, z, inActive)
    }

    private static func frameRubik(size: Double, time: Double) -> ThinkingOrbFrame {
        let center = size / 2
        let radius = (size / 2) * 0.82
        let project = makeProj(yaw: time * 0.55,
                               tilt: 0.35 + 0.1 * sin(time * 0.9),
                               cx: center, cy: center, scale: radius)
        let rs = radiusScale(size)
        let moves = makeMoves(14)
        let cycle = solveCycle(time: time, count: 14, slotDuration: 0.42, rest: 1.2)
        var dots: [ThinkingOrbDot] = []
        let latRings = 9
        let lonDensity = 24
        for latitudeIndex in 0...latRings {
            let latitude = -.pi / 2 + Double(latitudeIndex) / Double(latRings) * .pi
            let cosLatitude = cos(latitude)
            let sinLatitude = sin(latitude)
            let lonCount = max(1, Int((abs(cosLatitude) * Double(lonDensity)).rounded()))
            for longitudeIndex in 0..<lonCount {
                let longitude = Double(longitudeIndex) / Double(lonCount) * 2 * .pi
                let moved = applyMoves((cosLatitude * cos(longitude), sinLatitude,
                                        cosLatitude * sin(longitude)), moves: moves, cycle: cycle)
                let point = project(moved.0, moved.1, moved.2)
                let depth = (point.2 + 1) / 2
                dots.append(ThinkingOrbDot(
                    x: point.0, y: point.1, z: point.2,
                    r: (0.63 + 1.785 * depth + (moved.3 ? 0.315 : 0)) * rs,
                    white: 0.62 - 0.54 * depth - (moved.3 ? 0.14 : 0)
                ))
            }
        }
        return finalize(dots)
    }

    // MARK: Listening / wave

    private static func frameWave(size: Double, time: Double,
                                  acoustics: ThinkingOrbAcoustics?) -> ThinkingOrbFrame {
        let center = size / 2
        let radius = (size / 2) * 0.874
        // The authored demo turns at 0.18. During real speech the individual latitude rings are
        // the subject, so retain only a near-imperceptible drift instead of spinning the globe.
        let yawRate = acoustics == nil ? 0.18 : 0.012
        let project = makeProj(yaw: time * yawRate, tilt: 0.38,
                               cx: center, cy: center, scale: 1)
        let rs = radiusScale(size)
        let rings = 9
        let lonDensity = 23
        var dots: [ThinkingOrbDot] = []
        for ringIndex in 0...rings {
            let latitude = -.pi / 2 + Double(ringIndex) / Double(rings) * .pi
            let cosLatitude = cos(latitude)
            let sinLatitude = sin(latitude)
            let synthetic = 0.62 * sin(time * 2.1 - Double(ringIndex) * 0.52)
                + 0.38 * sin(time * 1.27 + Double(ringIndex) * 0.83)
            let wave: Double
            let ringEnergy: Double
            let ringImpulse: Double
            if let acoustics, !acoustics.ringLevels.isEmpty {
                let levels = acoustics.ringLevels.map { min(0.82, max(0, $0)) }
                let recentCount = min(3, levels.count)
                let recentLevels = levels.suffix(recentCount)
                let shortLevel = recentLevels.reduce(0, +) / Double(max(1, recentCount))
                let olderLevels = levels.dropLast(recentCount)
                let olderLevel = olderLevels.isEmpty
                    ? shortLevel : olderLevels.reduce(0, +) / Double(olderLevels.count)
                // Time history now creates a single onset strength. It is no longer assigned from
                // south to north across the latitude rings, which made every loud syllable look
                // like an unattractive vertical scan.
                let level = min(0.82, max(0,
                    shortLevel * 0.72 + acoustics.overallLevel * 0.28
                ))
                ringEnergy = level
                ringImpulse = max(0, (levels.last ?? level) - olderLevel)
                let pitch = min(1, max(-1, acoustics.pitch))
                    * min(1, max(0, acoustics.pitchConfidence))
                let layerPhase = sin(Double(ringIndex) * 1.73 + pitch * 0.9)
                let counterPhase = cos(Double(ringIndex) * 0.91 - time * 0.08)
                let pitchShape = pitch
                    * sin(latitude * 1.75 + Double(ringIndex) * 0.34) * 0.055
                let voiceShape = level * (0.045 * layerPhase + 0.025 * counterPhase)
                let hitShape = ringImpulse * (
                    0.09 * layerPhase + 0.045 * sin(Double(ringIndex) * 2.41)
                )
                wave = min(0.14, max(-0.14,
                    synthetic * 0.012 + voiceShape + hitShape + pitchShape
                ))
            } else {
                ringEnergy = 0
                ringImpulse = 0
                wave = synthetic
            }
            // Keep upstream idle geometry untouched for golden parity. The live sphere itself is
            // deliberately larger and nearly fixed; acoustic energy redistributes its layers
            // around that base instead of scaling the whole silhouette with background noise.
            let ringRadius: Double
            if acoustics == nil {
                ringRadius = radius * (0.88 + 0.105 * wave)
            } else {
                ringRadius = radius * (1.06 + wave)
            }
            let acousticBrightness = acoustics.map {
                min(1, max(0, $0.brightness))
            } ?? 0
            let lonCount = max(1, Int((abs(cosLatitude) * Double(lonDensity)).rounded()))
            for longitudeIndex in 0..<lonCount {
                let longitude = Double(longitudeIndex) / Double(lonCount) * 2 * .pi
                // Timbre now changes the surface as well as particle size. The three-lobed ripple
                // keeps neighbouring dots coherent, avoiding random visual noise.
                let shimmer = sin(longitude * 3 + time * 0.42)
                let surfaceRipple = 1 + acousticBrightness * 0.026 * shimmer
                    * (0.35 + 0.65 * ringEnergy)
                let point = project(cosLatitude * cos(longitude) * ringRadius * surfaceRipple,
                                    sinLatitude * ringRadius * surfaceRipple,
                                    cosLatitude * sin(longitude) * ringRadius * surfaceRipple)
                let depth = (point.2 / radius + 1) / 2
                let crest = max(0, wave)
                var liveScale = 1.0
                if let acoustic = acoustics {
                    let brightness = min(1, max(0, acoustic.brightness))
                    let shimmerAmount = 0.5 + 0.5 * shimmer
                    liveScale += 0.26 * ringEnergy
                        + 0.16 * ringImpulse * (0.4 + 0.6 * shimmerAmount)
                        + 0.10 * brightness * shimmerAmount
                }
                dots.append(ThinkingOrbDot(
                    x: point.0, y: point.1, z: point.2,
                    r: (0.6 + 1.7 * depth) * (1 + 0.4 * crest) * liveScale * rs,
                    white: 0.66 - 0.56 * depth - 0.1 * crest
                        - (acoustics == nil ? 0 : 0.08 * ringEnergy)
                ))
            }
        }
        return finalize(dots)
    }

    // MARK: Connecting / web

    private static func frameWeb(size: Double, time: Double) -> ThinkingOrbFrame {
        let center = size / 2
        let radius = (size / 2) * 0.8
        let project = makeProj(yaw: time * 0.12, tilt: 0.32,
                               cx: center, cy: center, scale: radius)
        let rs = radiusScale(size)
        let nodeCount = 41
        let threshold = 0.72
        let nodeRadius = 1.33
        let nodeRadiusDepth = 1.71
        var nodes: [(Double, Double, Double)] = []
        nodes.reserveCapacity(nodeCount)
        for index in 0..<nodeCount {
            let direction = fibDir(index, nodeCount)
            let i = Double(index)
            let x = direction.0 + 0.3 * (vnoise(i * 0.31 + 9, time * 0.24) - 0.5) * 2
            let y = direction.1 + 0.3 * (vnoise(i * 0.53 + 27, time * 0.21) - 0.5) * 2
            let z = direction.2 + 0.3 * (vnoise(i * 0.77 + 55, time * 0.27) - 0.5) * 2
            let length = sqrt(x * x + y * y + z * z)
            nodes.append((x / length, y / length, z / length))
        }

        var lines: [ThinkingOrbLine] = []
        var dots: [ThinkingOrbDot] = []
        for first in 0..<nodeCount {
            for second in (first + 1)..<nodeCount {
                let dx = nodes[first].0 - nodes[second].0
                let dy = nodes[first].1 - nodes[second].1
                let dz = nodes[first].2 - nodes[second].2
                let distance = sqrt(dx * dx + dy * dy + dz * dz)
                guard distance < threshold else { continue }
                let point1 = project(nodes[first].0, nodes[first].1, nodes[first].2)
                let point2 = project(nodes[second].0, nodes[second].1, nodes[second].2)
                let depth = ((point1.2 + point2.2) / 2 + 1) / 2
                lines.append(ThinkingOrbLine(
                    x1: point1.0, y1: point1.1, x2: point2.0, y2: point2.1,
                    white: 0.42,
                    alpha: (1 - distance / threshold) * (0.3 + 0.55 * depth),
                    width: max(0.6, 0.8 * rs)
                ))
            }
        }
        for index in 0..<nodeCount {
            let point = project(nodes[index].0, nodes[index].1, nodes[index].2)
            let depth = (point.2 + 1) / 2
            let pulse = 1 + 0.25 * sin(time * 1.4 + Double(index) * 2.7)
            dots.append(ThinkingOrbDot(
                x: point.0, y: point.1, z: point.2,
                r: (nodeRadius + nodeRadiusDepth * depth) * pulse * rs,
                white: 0.55 - 0.45 * depth
            ))
        }
        for signal in 0..<7 {
            let s = Double(signal)
            let segment = floor(time * 0.55 + s * 7.31)
            let first = Int(floor(hashD(segment, s * 3.1 + 1.7) * Double(nodeCount)))
            let second = Int(floor(hashD(segment, s * 5.7 + 4.2) * Double(nodeCount)))
            guard first != second else { continue }
            let fraction = frac(time * 0.55 + s * 7.31)
            let x = lerp(nodes[first].0, nodes[second].0, fraction)
            let y = lerp(nodes[first].1, nodes[second].1, fraction)
            let z = lerp(nodes[first].2, nodes[second].2, fraction)
            let length = max(0.000_001, sqrt(x * x + y * y + z * z))
            let point = project(x / length, y / length, z / length)
            let depth = (point.2 + 1) / 2
            dots.append(ThinkingOrbDot(
                x: point.0, y: point.1, z: point.2,
                r: (nodeRadius * 1.5 + nodeRadiusDepth * depth) * rs,
                white: 0.05, alpha: 0.5 + 0.5 * depth
            ))
        }
        return finalize(dots, lines)
    }

    // MARK: Weaving / braid

    private static func frameBraid(size: Double, time: Double) -> ThinkingOrbFrame {
        let center = size / 2
        let radius = (size / 2) * 0.76
        let project = makeProj(yaw: time * 0.4, tilt: 0.3,
                               cx: center, cy: center, scale: 1)
        let rs = radiusScale(size)
        var dots: [ThinkingOrbDot] = []
        let ghostCount = 75
        for index in 0..<ghostCount {
            let direction = fibDir(index, ghostCount)
            let point = project(direction.0 * radius, direction.1 * radius,
                                direction.2 * radius)
            let depth = (point.2 / radius + 1) / 2
            dots.append(ThinkingOrbDot(x: point.0, y: point.1, z: point.2,
                                       r: 0.8 * rs, white: 0.78,
                                       alpha: 0.1 + 0.22 * depth))
        }
        let strandCount = 26
        for strand in 0..<3 {
            let phase = Double(strand) / 3 * 2 * .pi
            for index in 0..<strandCount {
                let u = (frac(Double(index) / Double(strandCount) + time * 0.045) * 2 - 1)
                    * 0.96
                let surface = sqrt(max(0, 1 - u * u))
                let endFade = min(1, (1 - abs(u)) / 0.1)
                let angle = u * .pi * 3 + phase
                let weave = 1 + 0.075 * sin(u * .pi * 3 * 2 + phase * 2 + time * 0.8)
                let radial = surface * radius * weave
                let point = project(cos(angle) * radial, u * radius * weave,
                                    sin(angle) * radial)
                let depth = (point.2 / radius + 1) / 2
                dots.append(ThinkingOrbDot(
                    x: point.0, y: point.1, z: point.2,
                    r: (1.2 + 1.8 * depth) * rs,
                    white: 0.55 - 0.45 * depth,
                    alpha: endFade * (0.45 + 0.55 * depth)
                ))
            }
        }
        return finalize(dots)
    }

    // MARK: Composing / ribbon and breathing / ring

    private static func frameRibbon(size: Double, time: Double,
                                    breathing: Bool) -> ThinkingOrbFrame {
        let center = size / 2
        let radius = (size / 2) * 0.78
        let spin = 0.0
        let cameraTilt = 0.3
        let project = makeProj(yaw: time * 0.1 * spin, tilt: cameraTilt,
                               cx: center, cy: center, scale: 1)
        let rs = radiusScale(size)
        let ghostCount = breathing ? 0 : 38
        let radiusBase = breathing ? 1.0516 : 0.935
        let radiusDepth = breathing ? 1.6252 : 1.445
        let bandMultiplier = breathing ? 3.627 : 3.9
        let wobbleMultiplier = breathing ? 0.368 : 1.0
        var dots: [ThinkingOrbDot] = []
        if ghostCount > 0 {
            for index in 0..<ghostCount {
                let direction = fibDir(index, ghostCount)
                let point = project(direction.0 * radius, direction.1 * radius,
                                    direction.2 * radius)
                let depth = (point.2 / radius + 1) / 2
                dots.append(ThinkingOrbDot(x: point.0, y: point.1, z: point.2,
                                           r: 0.8 * rs, white: 0.78,
                                           alpha: 0.1 + 0.22 * depth))
            }
        }

        let yawAngle = time * 0.24 * spin
        let tiltAngle = breathing ? -cameraTilt : 0.55 + 0.3 * sin(time * 0.18) * spin
        let ux = cos(yawAngle)
        let uy = 0.0
        let uz = sin(yawAngle)
        let vx = -uz * sin(tiltAngle)
        let vy = cos(tiltAngle)
        let vz = ux * sin(tiltAngle)
        let nx = uy * vz - uz * vy
        let ny = uz * vx - ux * vz
        let nz = ux * vy - uy * vx
        let wobbleAmplitude = 0.23 * wobbleMultiplier
        let baseRadius = breathing ? radius / (1 + 0.85 * wobbleAmplitude) : radius
        let lanes = max(1, Int((3 * bandMultiplier).rounded()))
        let segments = 44
        for lane in 0..<lanes {
            let laneOffset = (Double(lane) - Double(lanes - 1) / 2) * 0.075
            let edge = abs(Double(lane) - Double(lanes - 1) / 2)
                / max(1, Double(lanes - 1) / 2)
            for segment in 0..<segments {
                let angle = Double(segment) / Double(segments) * 2 * .pi
                let wobble = (0.16 * sin(angle * 3 - time * 1.7 + Double(lane) * 0.22)
                    + 0.07 * sin(angle * 5 + time * 1.1)) * wobbleMultiplier
                let radial = breathing ? 1 + wobble : 1
                let offset = breathing ? laneOffset : laneOffset + wobble
                let x = ux * cos(angle) + vx * sin(angle) + nx * offset
                let y = uy * cos(angle) + vy * sin(angle) + ny * offset
                let z = uz * cos(angle) + vz * sin(angle) + nz * offset
                let length = sqrt(x * x + y * y + z * z)
                let renderedRadius = baseRadius * radial
                let point = project(x / length * renderedRadius,
                                    y / length * renderedRadius,
                                    z / length * renderedRadius)
                let depth = (point.2 / radius + 1) / 2
                dots.append(ThinkingOrbDot(
                    x: point.0, y: point.1, z: point.2,
                    r: (radiusBase + radiusDepth * depth) * (1 - 0.25 * edge) * rs,
                    white: 0.52 - 0.44 * depth + 0.18 * edge,
                    alpha: 0.4 + 0.6 * depth
                ))
            }
        }
        return finalize(dots)
    }

    // MARK: Shaping / morph

    private typealias Path = (Double) -> (Double, Double)

    private static func polygonPath(_ vertices: [(Double, Double)]) -> Path {
        var lengths: [Double] = []
        var total = 0.0
        for index in vertices.indices {
            let first = vertices[index]
            let second = vertices[(index + 1) % vertices.count]
            let length = hypot(second.0 - first.0, second.1 - first.1)
            lengths.append(length)
            total += length
        }
        return { fraction in
            var target = fraction * total
            var index = 0
            while target > lengths[index], index < vertices.count - 1 {
                target -= lengths[index]
                index += 1
            }
            let first = vertices[index]
            let second = vertices[(index + 1) % vertices.count]
            let f = lengths[index] > 0 ? min(1, target / lengths[index]) : 0
            return (first.0 + (second.0 - first.0) * f,
                    first.1 + (second.1 - first.1) * f)
        }
    }

    private static func frameMorph(size: Double, time: Double) -> ThinkingOrbFrame {
        let circle: Path = { fraction in
            let angle = -.pi / 2 + fraction * 2 * .pi
            return (cos(angle) * 0.24, sin(angle) * 0.24)
        }
        let triangle = polygonPath([(0, -0.26), (0.24, 0.16), (-0.24, 0.16)])
        let square = polygonPath([(0, -0.2), (0.2, -0.2), (0.2, 0.2),
                                  (-0.2, 0.2), (-0.2, -0.2)])
        let cycle: [Path] = [circle, triangle, square]
        let hold = 1.4
        let morph = 0.9
        let segmentDuration = hold + morph
        let cycleTime = time.truncatingRemainder(dividingBy: segmentDuration * 3)
        let cycleIndex = Int(floor(cycleTime / segmentDuration))
        let local = cycleTime - Double(cycleIndex) * segmentDuration
        let rawMorph = local > hold ? (local - hold) / morph : 0
        let blend = rawMorph * rawMorph * (3 - 2 * rawMorph)
        let spread = 1.45
        let sampleCount = 160
        var points: [(Double, Double)] = []
        points.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let fraction = Double(index) / Double(sampleCount)
            let first = cycle[cycleIndex](fraction)
            let second = cycle[(cycleIndex + 1) % cycle.count](fraction)
            points.append(((first.0 + (second.0 - first.0) * blend) * spread,
                           (first.1 + (second.1 - first.1) * blend) * spread))
        }
        var lengths: [Double] = []
        var total = 0.0
        for index in 0..<sampleCount {
            let first = points[index]
            let second = points[(index + 1) % sampleCount]
            let length = hypot(second.0 - first.0, second.1 - first.1)
            lengths.append(length)
            total += length
        }
        let dotCount = max(6, Int((34 * 0.702).rounded()))
        let dotRadius = 0.008_295 * 1.35 * spread
        let pulse = 1 + 0.02 * sin(local * 3.1)
        let center = size / 2
        var dots: [ThinkingOrbDot] = []
        var segment = 0
        var accumulated = 0.0
        for dotIndex in 0..<dotCount {
            let target = Double(dotIndex) / Double(dotCount) * total
            while accumulated + lengths[segment] < target, segment < sampleCount - 1 {
                accumulated += lengths[segment]
                segment += 1
            }
            let first = points[segment]
            let second = points[(segment + 1) % sampleCount]
            let fraction = lengths[segment] > 0
                ? min(1, (target - accumulated) / lengths[segment]) : 0
            let x = (first.0 + (second.0 - first.0) * fraction) * pulse
            let y = (first.1 + (second.1 - first.1) * fraction) * pulse
            dots.append(ThinkingOrbDot(
                x: center + x * size, y: center + y * size, z: 0,
                r: max(0.35, dotRadius * size), white: 0.1
            ))
        }
        return finalize(dots, radiusMinimum: 0.25)
    }
}

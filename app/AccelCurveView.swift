//
//  AccelCurveView.swift
//  HyperVibe (settings UI)
//
//  Interactive editor for the velocity-to-gain curve. The maths mirrors TouchHandler exactly:
//  a smoothstep ramp between two speed thresholds, raised to `curve`, then mapped from the slow
//  gain to the fast gain. The three handles edit the two endpoints and the bend directly.
//

import AppKit
import SwiftUI

struct AccelCurveLimits {
    let speedDomain: ClosedRange<Double>
    let gainDomain: ClosedRange<Double>
    let lowSpeed: ClosedRange<Double>
    let highSpeed: ClosedRange<Double>
    let slowGain: ClosedRange<Double>
    let fastGain: ClosedRange<Double>
    let curve: ClosedRange<Double>
    let minimumSpeedGap: Double
    let minimumGainGap: Double

    static let pointer = AccelCurveLimits(
        speedDomain: 0...0.14,
        gainDomain: 0...8.0,
        lowSpeed: 0.001...0.05,
        highSpeed: 0.01...0.14,
        slowGain: 0.05...2.0,
        fastGain: 0.5...8.0,
        curve: 0.35...4.0,
        minimumSpeedGap: 0.003,
        minimumGainGap: 0.05)

    static let circular = AccelCurveLimits(
        speedDomain: 0...0.16,
        gainDomain: 0...6.0,
        lowSpeed: 0.001...0.05,
        highSpeed: 0.01...0.16,
        slowGain: 0.05...2.0,
        fastGain: 0.5...6.0,
        curve: 0.35...4.0,
        minimumSpeedGap: 0.003,
        minimumGainGap: 0.05)
}

struct AccelCurveView: View {
    @Binding var accelMin: Double
    @Binding var accelMax: Double
    @Binding var lowSpeed: Double
    @Binding var highSpeed: Double
    @Binding var curve: Double

    let limits: AccelCurveLimits
    let accent: Color
    let slowLabel: String
    let fastLabel: String
    let formatSpeed: (Double) -> String
    let shapeLinked: Bool
    let onInteraction: () -> Void

    private enum Handle: CaseIterable {
        case slow, shape, fast
    }

    @State private var activeHandle: Handle?

    /// Same ramp TouchHandler applies: smoothstep between the two speeds, bent by `curve`.
    private func gain(at speed: Double) -> Double {
        guard highSpeed > lowSpeed else { return speed < lowSpeed ? accelMin : accelMax }
        let x = clamp((speed - lowSpeed) / (highSpeed - lowSpeed), to: 0...1)
        let smooth = x * x * (3 - 2 * x)
        let shaped = smooth > 0 ? pow(smooth, curve) : 0
        return accelMin + (accelMax - accelMin) * shaped
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { proxy in
                Canvas { context, size in
                    draw(in: &context, size: size)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let handle = activeHandle ?? nearestHandle(to: value.startLocation,
                                                                       size: proxy.size)
                            if activeHandle == nil {
                                activeHandle = handle
                                onInteraction()
                            }
                            update(handle, at: value.location, size: proxy.size)
                        }
                        .onEnded { _ in activeHandle = nil }
                )
            }
            .frame(height: 142)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
            )
            .help("Drag either endpoint to change its speed and gain. Drag the middle point to bend the curve.")

            HStack(spacing: 8) {
                Label(slowLabel, systemImage: "tortoise.fill")
                Spacer(minLength: 4)
                Label(shapeLinked ? "shape linked" : String(format: "curve %.2f", curve),
                      systemImage: shapeLinked ? "link" : "point.topleft.down.curvedto.point.bottomright.up")
                Spacer(minLength: 4)
                Label(fastLabel, systemImage: "hare.fill")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)

            HStack {
                Text(String(format: "%.2f×  @ %@", accelMin, formatSpeed(lowSpeed)))
                Spacer()
                Text("drag the three points")
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(String(format: "%.2f×  @ %@", accelMax, formatSpeed(highSpeed)))
            }
            .font(.system(size: 10, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Drawing

    private func plotRect(for size: CGSize) -> CGRect {
        CGRect(x: 13, y: 11, width: max(size.width - 26, 1), height: max(size.height - 22, 1))
    }

    private func x(for speed: Double, in rect: CGRect) -> CGFloat {
        let d = limits.speedDomain
        let n = (speed - d.lowerBound) / max(d.upperBound - d.lowerBound, .leastNonzeroMagnitude)
        return rect.minX + CGFloat(clamp(n, to: 0...1)) * rect.width
    }

    private func y(for gain: Double, in rect: CGRect) -> CGFloat {
        let d = limits.gainDomain
        let n = (gain - d.lowerBound) / max(d.upperBound - d.lowerBound, .leastNonzeroMagnitude)
        return rect.maxY - CGFloat(clamp(n, to: 0...1)) * rect.height
    }

    private func speed(at x: CGFloat, in rect: CGRect) -> Double {
        let n = clamp(Double((x - rect.minX) / rect.width), to: 0...1)
        return limits.speedDomain.lowerBound
            + n * (limits.speedDomain.upperBound - limits.speedDomain.lowerBound)
    }

    private func gain(at y: CGFloat, in rect: CGRect) -> Double {
        let n = 1 - clamp(Double((y - rect.minY) / rect.height), to: 0...1)
        return limits.gainDomain.lowerBound
            + n * (limits.gainDomain.upperBound - limits.gainDomain.lowerBound)
    }

    private func point(for handle: Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .slow:
            return CGPoint(x: x(for: lowSpeed, in: rect), y: y(for: accelMin, in: rect))
        case .shape:
            let middleSpeed = (lowSpeed + highSpeed) / 2
            return CGPoint(x: x(for: middleSpeed, in: rect), y: y(for: gain(at: middleSpeed), in: rect))
        case .fast:
            return CGPoint(x: x(for: highSpeed, in: rect), y: y(for: accelMax, in: rect))
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let rect = plotRect(for: size)

        // A quiet 4×4 grid makes the handle movement legible without turning the control into a
        // technical plotting tool.
        for step in 1..<4 {
            let f = CGFloat(step) / 4
            var vertical = Path()
            vertical.move(to: CGPoint(x: rect.minX + rect.width * f, y: rect.minY))
            vertical.addLine(to: CGPoint(x: rect.minX + rect.width * f, y: rect.maxY))
            context.stroke(vertical, with: .color(.secondary.opacity(0.11)), lineWidth: 0.5)

            var horizontal = Path()
            horizontal.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * f))
            horizontal.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * f))
            context.stroke(horizontal, with: .color(.secondary.opacity(0.11)), lineWidth: 0.5)
        }

        if limits.gainDomain.contains(1) {
            var unit = Path()
            unit.move(to: CGPoint(x: rect.minX, y: y(for: 1, in: rect)))
            unit.addLine(to: CGPoint(x: rect.maxX, y: y(for: 1, in: rect)))
            context.stroke(unit, with: .color(.secondary.opacity(0.32)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        for threshold in [lowSpeed, highSpeed] {
            var marker = Path()
            marker.move(to: CGPoint(x: x(for: threshold, in: rect), y: rect.minY))
            marker.addLine(to: CGPoint(x: x(for: threshold, in: rect), y: rect.maxY))
            context.stroke(marker, with: .color(accent.opacity(0.18)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
        }

        var line = Path()
        var area = Path()
        area.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        let samples = max(Int(rect.width.rounded()), 1)
        for i in 0...samples {
            let fraction = Double(i) / Double(samples)
            let speed = limits.speedDomain.lowerBound
                + fraction * (limits.speedDomain.upperBound - limits.speedDomain.lowerBound)
            let p = CGPoint(x: rect.minX + CGFloat(fraction) * rect.width,
                            y: y(for: gain(at: speed), in: rect))
            if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            area.addLine(to: p)
        }
        area.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        area.closeSubpath()

        context.fill(area, with: .linearGradient(
            Gradient(colors: [accent.opacity(0.28), accent.opacity(0.025)]),
            startPoint: CGPoint(x: 0, y: rect.minY),
            endPoint: CGPoint(x: 0, y: rect.maxY)))
        context.stroke(line, with: .color(accent), lineWidth: 2.25)

        for handle in Handle.allCases {
            let p = point(for: handle, in: rect)
            let active = handle == activeHandle
            if active {
                context.fill(Path(ellipseIn: CGRect(x: p.x - 11, y: p.y - 11,
                                                    width: 22, height: 22)),
                             with: .color(accent.opacity(0.16)))
            }
            context.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)),
                         with: .color(active ? accent : Color(nsColor: .controlBackgroundColor)))
            context.stroke(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)),
                           with: .color(accent), lineWidth: active ? 2.5 : 2)
            if handle == .shape {
                context.fill(Path(ellipseIn: CGRect(x: p.x - 1.75, y: p.y - 1.75,
                                                    width: 3.5, height: 3.5)),
                             with: .color(accent))
            }
        }
    }

    // MARK: - Interaction

    private func nearestHandle(to location: CGPoint, size: CGSize) -> Handle {
        let rect = plotRect(for: size)
        return Handle.allCases.min { lhs, rhs in
            distanceSquared(from: location, to: point(for: lhs, in: rect))
                < distanceSquared(from: location, to: point(for: rhs, in: rect))
        } ?? .shape
    }

    private func distanceSquared(from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }

    private func update(_ handle: Handle, at location: CGPoint, size: CGSize) {
        let rect = plotRect(for: size)
        switch handle {
        case .slow:
            let speedUpper = min(limits.lowSpeed.upperBound,
                                 highSpeed - limits.minimumSpeedGap)
            lowSpeed = clamp(speed(at: location.x, in: rect),
                             to: limits.lowSpeed.lowerBound...max(limits.lowSpeed.lowerBound, speedUpper))

            let gainUpper = min(limits.slowGain.upperBound,
                                accelMax - limits.minimumGainGap)
            accelMin = clamp(gain(at: location.y, in: rect),
                             to: limits.slowGain.lowerBound...max(limits.slowGain.lowerBound, gainUpper))

        case .fast:
            let speedLower = max(limits.highSpeed.lowerBound,
                                 lowSpeed + limits.minimumSpeedGap)
            highSpeed = clamp(speed(at: location.x, in: rect),
                              to: min(speedLower, limits.highSpeed.upperBound)...limits.highSpeed.upperBound)

            let gainLower = max(limits.fastGain.lowerBound,
                                accelMin + limits.minimumGainGap)
            accelMax = clamp(gain(at: location.y, in: rect),
                             to: min(gainLower, limits.fastGain.upperBound)...limits.fastGain.upperBound)

        case .shape:
            // The shape handle lives halfway between the thresholds. At that point smoothstep is
            // exactly 0.5, so target = 0.5^curve and curve = log(target)/log(0.5).
            let span = accelMax - accelMin
            guard span > limits.minimumGainGap else { return }
            let targetGain = clamp(gain(at: location.y, in: rect),
                                   to: (accelMin + 0.001)...(accelMax - 0.001))
            let normalized = clamp((targetGain - accelMin) / span, to: 0.0001...0.9999)
            curve = clamp(log(normalized) / log(0.5), to: limits.curve)
        }
    }

    private func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

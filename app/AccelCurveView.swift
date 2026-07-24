//
//  AccelCurveView.swift
//  HyperVibe (settings UI)
//
//  Draws the circular-scroll velocity gain curve so it can be shaped by eye instead of by guessing
//  at four numbers. The maths here mirrors TouchHandler's per-frame gain exactly — if one changes,
//  change the other, or the picture stops telling the truth.
//

import SwiftUI

struct AccelCurveView: View {
    var accelMin: Double
    var accelMax: Double
    var lowSpeed: Double
    var highSpeed: Double
    var curve: Double

    /// Same ramp TouchHandler applies: smoothstep between the two speeds, bent by `curve`.
    private func gain(at speed: Double) -> Double {
        guard highSpeed > lowSpeed else { return speed < lowSpeed ? accelMin : accelMax }
        let x = min(max((speed - lowSpeed) / (highSpeed - lowSpeed), 0), 1)
        var t = x * x * (3 - 2 * x)
        if curve != 1, t > 0 { t = pow(t, curve) }
        return accelMin + (accelMax - accelMin) * t
    }

    /// A little past `highSpeed`, so the flat cap is visible rather than ending at the knee.
    private var maxSpeed: Double { max(highSpeed * 1.35, lowSpeed + 0.001) }
    /// Always include 1.0 so the "faster / slower than base speed" line is on-chart.
    private var maxGain: Double { max(accelMax, 1.0) * 1.12 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { ctx, size in
                let w = size.width, h = size.height
                func px(_ speed: Double) -> CGFloat { CGFloat(speed / maxSpeed) * w }
                func py(_ g: Double) -> CGFloat { h - CGFloat(g / maxGain) * h }

                // Gain = 1.0 reference: above it the wheel beats `pixelsPerRadian`, below it is
                // finer than the nominal speed. The single most useful line on the chart.
                if maxGain > 1 {
                    var unit = Path()
                    unit.move(to: CGPoint(x: 0, y: py(1)))
                    unit.addLine(to: CGPoint(x: w, y: py(1)))
                    ctx.stroke(unit, with: .color(.secondary.opacity(0.35)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }

                // The two speed thresholds — where the ramp starts and where it caps.
                for s in [lowSpeed, highSpeed] where s > 0 && s < maxSpeed {
                    var v = Path()
                    v.move(to: CGPoint(x: px(s), y: 0))
                    v.addLine(to: CGPoint(x: px(s), y: h))
                    ctx.stroke(v, with: .color(.secondary.opacity(0.22)),
                               style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                }

                // The curve itself, sampled per pixel.
                var line = Path()
                var area = Path()
                area.move(to: CGPoint(x: 0, y: h))
                for i in 0...Int(w) {
                    let speed = Double(i) / Double(w) * maxSpeed
                    let p = CGPoint(x: CGFloat(i), y: py(gain(at: speed)))
                    if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                    area.addLine(to: p)
                }
                area.addLine(to: CGPoint(x: w, y: h))
                area.closeSubpath()

                ctx.fill(area, with: .linearGradient(
                    Gradient(colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.02)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
                ctx.stroke(line, with: .color(.accentColor), lineWidth: 2)
            }
            .frame(height: 104)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary))

            HStack(spacing: 0) {
                Label("slow circling", systemImage: "tortoise.fill")
                Spacer()
                Text(String(format: "gain %.2f× → %.2f×", accelMin, accelMax))
                    .monospacedDigit()
                Spacer()
                Label("fast", systemImage: "hare.fill")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
        }
    }
}

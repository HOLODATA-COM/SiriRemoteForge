//
//  TouchMonitor.swift
//  HyperVibe
//
//  A live window showing everything the clickpad reports, including the fields the gesture code
//  never reads. Built to answer questions by looking rather than by reasoning — the Z band in
//  particular turned out to carry a clean, graded hover signal that nobody had noticed.
//
//  Opened with `--touch-monitor`, alongside the normal app, so the remote keeps working while you
//  watch it. Everything here is read-only.
//

import AppKit
import SwiftUI

// MARK: - Model

final class TouchMonitorModel: ObservableObject {
    @Published var touches: [TouchSnapshot] = []
    /// Rolling history of the primary contact's zTotal. This is the plot that makes an approaching
    /// finger visible as a curve rather than a number twitching too fast to read.
    @Published var zHistory: [Float] = []
    @Published var peakZ: Float = 0
    @Published var hoverFloor: Float = 0

    /// Surface size in 0.01 mm units, so the pad can be drawn at its true aspect.
    @Published var surface: CGSize = CGSize(width: 2775, height: 2775)

    private let historyLength = 240        // ~4 s at 60 Hz

    func ingest(_ snaps: [TouchSnapshot]) {
        touches = snaps
        let z = snaps.first?.zTotal ?? 0
        zHistory.append(z)
        if zHistory.count > historyLength { zHistory.removeFirst(zHistory.count - historyLength) }
        if z > peakZ { peakZ = z }
        // Smallest non-zero reading seen — the practical noise floor of the hover band.
        if z > 0, hoverFloor == 0 || z < hoverFloor { hoverFloor = z }
    }

    func resetPeaks() { peakZ = 0; hoverFloor = 0 }
}

// MARK: - View

struct TouchMonitorView: View {
    @ObservedObject var model: TouchMonitorModel

    /// Contact begins around here; below it the finger is near the surface but not on it.
    private let contactZ: Float = 0.5
    private let maxZ: Float = 1.6

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                padView
                zColumn
                readouts
            }
            zPlot
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 430)
    }

    // The pad, drawn at its real aspect ratio, with each contact as an ellipse of the reported size.
    private var padView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("触摸面  \(Int(model.surface.width) / 100)×\(Int(model.surface.height) / 100) mm")
                .font(.caption).foregroundStyle(.secondary)
            Canvas { ctx, size in
                let rect = CGRect(origin: .zero, size: size)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 10),
                         with: .color(.gray.opacity(0.12)))
                ctx.stroke(Path(roundedRect: rect, cornerRadius: 10),
                           with: .color(.gray.opacity(0.35)), lineWidth: 1)
                // Thirds, purely as a reading aid for position.
                for f in [CGFloat(1.0 / 3.0), CGFloat(2.0 / 3.0)] {
                    var p = Path()
                    p.move(to: CGPoint(x: rect.width * f, y: 0))
                    p.addLine(to: CGPoint(x: rect.width * f, y: rect.height))
                    p.move(to: CGPoint(x: 0, y: rect.height * f))
                    p.addLine(to: CGPoint(x: rect.width, y: rect.height * f))
                    ctx.stroke(p, with: .color(.gray.opacity(0.18)), lineWidth: 0.5)
                }
                for t in model.touches {
                    // Normalized y is bottom-up; the canvas is top-down.
                    let cx = rect.width * t.normalized.x
                    let cy = rect.height * (1 - t.normalized.y)
                    // Ellipse axes are millimetres; scale them by the pad's own size.
                    let mmToPx = rect.width / (model.surface.width / 100)
                    let w = CGFloat(t.majorAxis) * mmToPx
                    let h = CGFloat(t.minorAxis) * mmToPx
                    let e = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
                    let strength = min(Double(t.zTotal) / Double(maxZ), 1)
                    ctx.fill(Path(ellipseIn: e),
                             with: .color(t.isHovering
                                          ? .orange.opacity(0.20 + strength * 0.5)
                                          : .accentColor.opacity(0.25 + strength * 0.6)))
                    ctx.fill(Path(ellipseIn: CGRect(x: cx - 2, y: cy - 2, width: 4, height: 4)),
                             with: .color(.primary))
                }
            }
            .frame(width: 200, height: 200)
        }
    }

    // Z as a vertical gauge, with the hover band and the contact threshold marked.
    private var zColumn: some View {
        VStack(spacing: 6) {
            Text("Z").font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                let h = geo.size.height
                let z = model.touches.first?.zTotal ?? 0
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 5).fill(.gray.opacity(0.14))
                    // Hover band: below the contact threshold.
                    VStack(spacing: 0) {
                        Spacer()
                        Rectangle().fill(.orange.opacity(0.12))
                            .frame(height: h * CGFloat(contactZ / maxZ))
                    }
                    RoundedRectangle(cornerRadius: 5)
                        .fill(z >= contactZ ? Color.accentColor : .orange)
                        .frame(height: max(2, h * CGFloat(min(z, maxZ) / maxZ)))
                    // Contact threshold line.
                    VStack(spacing: 0) {
                        Spacer()
                        Rectangle().fill(.red.opacity(0.55)).frame(height: 1)
                            .padding(.bottom, h * CGFloat(contactZ / maxZ))
                    }
                }
            }
            .frame(width: 34, height: 200)
            Text(String(format: "%.3f", model.touches.first?.zTotal ?? 0))
                .font(.system(.caption, design: .monospaced))
        }
    }

    private var readouts: some View {
        let t = model.touches.first
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle()
                    .fill(t == nil ? Color.gray : (t!.isHovering ? .orange : .accentColor))
                    .frame(width: 9, height: 9)
                Text(t?.stateName ?? "无接触").font(.system(.body, design: .monospaced)).bold()
                if let t = t, t.isHovering {
                    Text("悬空").font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.bottom, 2)

            row("接触点", "\(model.touches.count)")
            if let t = t {
                row("归一化", String(format: "%.4f , %.4f", t.normalized.x, t.normalized.y))
                row("绝对 mm", String(format: "%.2f , %.2f", t.absoluteMM.x, t.absoluteMM.y))
                row("速度", String(format: "%.2f , %.2f", t.velocity.x, t.velocity.y))
                Divider().padding(.vertical, 3)
                row("zTotal", String(format: "%.4f", t.zTotal))
                row("zDensity", String(format: "%.4f", t.zDensity))
                row("接触椭圆", String(format: "%.2f × %.2f mm", t.majorAxis, t.minorAxis))
                row("angle", String(format: "%.3f", t.angle))
                Divider().padding(.vertical, 3)
                row("fingerID", "\(t.fingerID)")
                row("pathIndex", "\(t.id)")
            }
            Spacer(minLength: 0)
            HStack {
                row("本次峰值 z", String(format: "%.3f", model.peakZ))
                Button("清零") { model.resetPeaks() }.controlSize(.small)
            }
            row("最低非零 z", String(format: "%.3f", model.hoverFloor))
        }
        .frame(minWidth: 250, alignment: .leading)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(spacing: 8) {
            Text(k).font(.caption).foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(v).font(.system(.caption, design: .monospaced))
        }
    }

    // The history plot: an approaching finger reads as a rising curve, which a live number cannot show.
    private var zPlot: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("zTotal 时间曲线(最近约 4 秒) — 红线以下为悬空")
                .font(.caption).foregroundStyle(.secondary)
            Canvas { ctx, size in
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6),
                         with: .color(.gray.opacity(0.10)))
                let y = { (z: Float) in size.height * (1 - CGFloat(min(z, self.maxZ) / self.maxZ)) }
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(contactZ)))
                line.addLine(to: CGPoint(x: size.width, y: y(contactZ)))
                ctx.stroke(line, with: .color(.red.opacity(0.5)), lineWidth: 1)

                guard model.zHistory.count > 1 else { return }
                let dx = size.width / CGFloat(max(model.zHistory.count - 1, 1))
                var p = Path()
                for (i, z) in model.zHistory.enumerated() {
                    let pt = CGPoint(x: CGFloat(i) * dx, y: y(z))
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
                ctx.stroke(p, with: .color(.accentColor), lineWidth: 1.5)
            }
            .frame(height: 110)
        }
    }
}

// MARK: - Window

final class TouchMonitorWindowController {
    let model = TouchMonitorModel()
    private var window: NSWindow?

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 450),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Siri Remote — 触摸监视"
        w.contentView = NSHostingView(rootView: TouchMonitorView(model: model))
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

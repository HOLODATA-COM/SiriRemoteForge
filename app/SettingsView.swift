//
//  SettingsView.swift
//  HyperVibe (settings UI)
//
//  Minimal, Apple-style settings window. Every value applies live and persists.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    private enum Tab: String, CaseIterable { case tuning = "Tuning", layout = "Layout" }
    @State private var tab: Tab = .tuning

    var body: some View {
        VStack(spacing: 0) {
            header
            tabPicker
            Divider()
            switch tab {
            case .tuning:
                Form {
                    cursorSection
                    accelerationSection
                    clickSection
                    circularSection
                    buttonsSection
                    footerSection
                }
                .formStyle(.grouped)
            case .layout:
                if let config = model.config {
                    LayoutView(config: config, onSave: { newConfig in
                        // Atomic, validated write → hot-reloads → refreshes model.config. A failed
                        // write (invalid config / permissions) leaves the old file intact; log it.
                        do { try ConfigStore.save(newConfig) }
                        catch { NSLog("[siriRemote] config save failed: \(error)") }
                    })
                } else {
                    Spacer()
                    Text("Loading config…").foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        // Flexible height (not fixed) so the window can be shrunk to fit smaller displays — the
        // inner ScrollView/Form then scroll instead of the content being clipped.
        .frame(width: tab == .layout ? 900 : 452)
        .frame(minHeight: 480, idealHeight: 900, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: tab)
    }

    // MARK: - Tab switcher

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 22).padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.68)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 50, height: 50)
                .overlay(
                    Image(systemName: "appletvremote.gen4.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                )
                .shadow(color: Color.accentColor.opacity(0.35), radius: 7, y: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text("siriRemote").font(.system(size: 19, weight: .semibold))
                Text("Touch & gesture tuning")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            statusPill
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(.bar)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.connected ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 7, height: 7)
            Text(model.connected ? "Connected" : "Waiting")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(.quaternary))
    }

    // MARK: - Sections

    private var cursorSection: some View {
        Section {
            slider(icon: "cursorarrow.motionlines", title: "Speed",
                   value: $model.tune.cursorSpeed, range: 0.1...3.0,
                   minIcon: "tortoise.fill", maxIcon: "hare.fill",
                   display: { String(format: "%.2f×", $0) })
            slider(icon: "hand.raised.fill", title: "Steadiness",
                   value: $model.tune.cursorDeadzone, range: 0.0...0.02,
                   minIcon: "scribble.variable", maxIcon: "hand.raised.fill",
                   display: { String(format: "%.0f", $0 * 1000) })
            Toggle(isOn: $model.tune.findCursorEnabled) {
                rowLabel("Find cursor on shake", "cursorarrow.rays")
            }
        } header: {
            Text("Cursor")
        } footer: {
            Text("Higher steadiness ignores finger jitter, so it's easier to hold still and click. Find cursor on shake flashes a ring around the pointer when you rapidly shake it back and forth.")
        }
    }

    private var accelerationSection: some View {
        Section {
            slider(icon: "tortoise.fill", title: "Slow-move factor",
                   value: $model.tune.accelMin, range: 0.2...1.0,
                   minIcon: "tortoise.fill", maxIcon: "cursorarrow.motionlines",
                   display: { String(format: "%.2f×", $0) })
            slider(icon: "hare.fill", title: "Fast-move factor",
                   value: $model.tune.accelMax, range: 1.0...4.0,
                   minIcon: "cursorarrow.motionlines", maxIcon: "hare.fill",
                   display: { String(format: "%.2f×", $0) })
            slider(icon: "arrow.down.forward", title: "Slow threshold",
                   value: $model.tune.accelLowSpeed, range: 0.002...0.03,
                   minIcon: "tortoise.fill", maxIcon: "hare.fill",
                   display: { String(format: "%.0f", $0 * 1000) })
            slider(icon: "arrow.up.forward", title: "Fast threshold",
                   value: $model.tune.accelHighSpeed, range: 0.02...0.12,
                   minIcon: "tortoise.fill", maxIcon: "hare.fill",
                   display: { String(format: "%.0f", $0 * 1000) })
        } header: {
            Text("Pointer Acceleration")
        } footer: {
            Text("Slow finger motion moves the cursor less (precision); fast motion moves it more (reach), scaling on top of Speed. The two thresholds mark where the slow and fast ends kick in — below the slow threshold the factor is the slow-move factor, above the fast threshold it's the fast-move factor, smooth between.")
        }
    }

    private var clickSection: some View {
        Section {
            slider(icon: "hand.tap.fill", title: "Press sensitivity",
                   value: $model.tune.clickRiseThreshold, range: 0.04...0.25,
                   minIcon: "hare.fill", maxIcon: "tortoise.fill",
                   display: { String(format: "%.2f", $0) })
            slider(icon: "arrow.up.and.down.and.arrow.left.and.right", title: "Move tolerance",
                   value: $model.tune.pressMoveMax, range: 0.01...0.06,
                   minIcon: "smallcircle.filled.circle.fill", maxIcon: "circle",
                   display: { String(format: "%.3f", $0) })
        } header: {
            Text("Click")
        } footer: {
            Text("Pressing to click freezes the cursor so it doesn't drift. Lower sensitivity freezes more readily; higher move tolerance keeps it from feeling stuck.")
        }
    }

    private var buttonsSection: some View {
        Section {
            slider(icon: "clock", title: "Long-press time",
                   value: $model.tune.holdThreshold, range: 0.2...1.2,
                   minIcon: "hare.fill", maxIcon: "tortoise.fill",
                   display: { String(format: "%.1fs", $0) })
            slider(icon: "hand.tap.fill", title: "Double-tap speed",
                   value: $model.tune.doubleTapWindow, range: 0.15...0.6,
                   minIcon: "hare.fill", maxIcon: "tortoise.fill",
                   display: { String(format: "%.2fs", $0) })
            slider(icon: "rectangle.on.rectangle", title: "Spaces Mode timeout",
                   value: $model.tune.spacesModeWindow, range: 2.0...15.0,
                   minIcon: "hare.fill", maxIcon: "tortoise.fill",
                   display: { String(format: "%.0fs", $0) })
        } header: {
            Text("Buttons")
        } footer: {
            Text("Long-press time: how long to hold a button before its \u{201C}.hold\u{201D} fires. Double-tap speed: the window for a second tap to trigger a \u{201C}.double\u{201D} binding instead of a second single press. Spaces Mode timeout: after long-pressing ring-up to arm desktop switching, how long without a left/right switch before it disarms.")
        }
    }

    private var circularSection: some View {
        Section {
            Toggle(isOn: $model.tune.circularEnabled) {
                rowLabel("Circular scroll", "arrow.clockwise")
            }
            if model.tune.circularEnabled {
                slider(icon: "circle.dashed", title: "Outer ring only",
                       value: $model.tune.circularMinRadius, range: 0.15...0.45,
                       minIcon: "smallcircle.filled.circle.fill", maxIcon: "circle",
                       display: { String(format: "%.0f%%", $0 * 100) })
                slider(icon: "timer", title: "Start resistance",
                       value: $model.tune.circularStartThreshold, range: 0.1...1.5,
                       minIcon: "hare.fill", maxIcon: "tortoise.fill",
                       display: { String(format: "%.0f°", $0 * 180 / .pi) })
                slider(icon: "speedometer", title: "Scroll speed",
                       value: $model.tune.circularPixelsPerRadian, range: 40...400,
                       minIcon: "tortoise.fill", maxIcon: "hare.fill",
                       display: { String(format: "%.0f", $0) })
                slider(icon: "wind", title: "Smoothness",
                       value: $model.tune.circularScrollEase, range: 0.1...0.6,
                       minIcon: "tortoise.fill", maxIcon: "hare.fill",
                       display: { String(format: "%.2f", $0) })
                Toggle(isOn: $model.tune.circularInvert) {
                    rowLabel("Reverse direction", "arrow.left.arrow.right")
                }
            }
        } header: {
            Text("Circular Scroll")
        } footer: {
            Text("Circle a finger on the pad's outer ring to scroll — like a click wheel.")
        }
        .animation(.easeInOut(duration: 0.22), value: model.tune.circularEnabled)
    }

    private var footerSection: some View {
        Section {
            Button(role: .destructive) {
                withAnimation { model.resetToDefaults() }
            } label: {
                rowLabel("Reset to defaults", "arrow.counterclockwise")
            }
        } footer: {
            Text("Button, ring, and swipe mappings live in ~/.config/siriremote/config.jsonc")
                .font(.system(size: 11))
        }
    }

    // MARK: - Reusable rows

    private func rowLabel(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 18)
            Text(title).font(.system(size: 13))
        }
    }

    private func slider(icon: String, title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, minIcon: String, maxIcon: String,
                        display: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                rowLabel(title, icon)
                Spacer()
                Text(display(value.wrappedValue))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 9) {
                Image(systemName: minIcon).font(.system(size: 11)).foregroundStyle(.tertiary)
                Slider(value: value, in: range)
                Image(systemName: maxIcon).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

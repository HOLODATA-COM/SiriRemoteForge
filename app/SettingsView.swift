//
//  SettingsView.swift
//  HyperVibe (settings UI)
//
//  Minimal, Apple-style settings window. Every value applies live and persists.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// Owned by the model (see `SettingsModel.device`) so the window controller drives its polling.
    @ObservedObject var device: DeviceInfo

    init(model: SettingsModel) {
        self.model = model
        self.device = model.device
    }

    /// Mirrors the real SMAppService registration — never assume the toggle succeeded.
    @State private var launchAtLogin = LaunchAtLogin.state.isOn
    @State private var launchAtLoginError: String?
    @State private var saveErrorDetail: String?

    /// Drives live relocalization: changing the language republishes, re-running this view's body
    /// (so every `L(...)` in the Tuning tab re-evaluates) and re-`.id()`-ing the Layout subview.
    @ObservedObject private var loc = Loc.shared

    private enum Tab: String, CaseIterable { case tuning = "Tuning", layout = "Layout" }
    @State private var tab: Tab = .tuning

    private enum CurveTarget: Equatable { case pointer, circular }
    /// When the user closes the lock, the curve they touched most recently becomes the source.
    /// Starting with circular is intentional: existing installs already expose/tune that curve,
    /// while pointer curve shaping is new.
    @State private var lastEditedCurve: CurveTarget = .circular

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .tuning:
                tuningWorkspace
            case .layout:
                if let config = model.config {
                    LayoutView(config: config, onSave: { newConfig in
                        // Atomic, validated write → hot-reloads → refreshes model.config. A failed
                        // write leaves the old file intact and is now visible in the shared header.
                        model.noteConfigSavePending(from: .layout)
                        do {
                            try ConfigStore.save(newConfig)
                            // Publish the exact written snapshot immediately instead of waiting for
                            // the file watcher. A pending debounced Tuning save will now merge onto
                            // this Layout edit and cannot accidentally restore the previous layout.
                            model.config = newConfig
                            model.noteConfigSaveSucceeded(from: .layout)
                        } catch {
                            model.noteConfigSaveFailed(error, from: .layout)
                            NSLog("[siriRemote] config save failed: \(error)")
                        }
                    })
                    // LayoutView is a separate view struct with unchanged inputs, so re-running this
                    // body would not re-run its body; keying it on the language forces relocalization.
                    .id(loc.language)
                } else {
                    Spacer()
                    Text(L("Loading config…")).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        // Flexible height (not fixed) so the window can be shrunk to fit smaller displays — the
        // inner ScrollView/Form then scroll instead of the content being clipped.
        .frame(width: tab == .layout ? 1100 : 1040)
        .frame(minHeight: 620, idealHeight: 780, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: tab)
        // Polling start/stop lives in SettingsWindowController — `.onDisappear` never fires for
        // this window (it is cached and only ordered out). Refresh on appear so reopening shows
        // current values immediately, and re-read the login-item registration, which the user may
        // have changed in System Settings → Login Items while the window was closed.
        .onAppear {
            device.refresh()
            launchAtLogin = LaunchAtLogin.state.isOn
        }
        // The remote can connect/disconnect while the window is open; refresh so battery and the
        // interface map do not go stale.
        .onChange(of: model.connected) { _ in device.refresh() }
        .alert(L("Couldn't save changes"), isPresented: Binding(
            get: { saveErrorDetail != nil },
            set: { if !$0 { saveErrorDetail = nil } }
        )) {
            Button("OK", role: .cancel) { saveErrorDetail = nil }
        } message: {
            Text(saveErrorDetail ?? "")
        }
    }

    // MARK: - Desktop workspace

    private var tuningWorkspace: some View {
        // One document, one scroll position. The old split view forced people to remember which
        // column owned a setting and could leave two unrelated scroll positions on screen. Curve
        // ownership is now explicit and everything shared follows in a predictable vertical order.
        Form {
            curveRelationshipSection
            pointerMovementSection
            circularMovementSection
            generalSettingsIntro
            clickSection
            buttonsSection
            widgetSection
            startupSection
            languageSection
            deviceSection
            footerSection
        }
        .formStyle(.grouped)
    }

    private var curveRelationshipSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.accentColor.opacity(0.11)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Acceleration Curves"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(model.tune.accelerationCurvesLinked
                         ? L("Pointer and ring share the same curve shape.")
                         : L("Pointer and ring are tuned independently."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                shapeLockButton
            }
            .padding(.vertical, 5)
        } footer: {
            Text(L("Each graph is a complete editor. Drag either endpoint to set its slow and fast range; drag the middle point to shape the acceleration."))
        }
    }

    private var pointerMovementSection: some View {
        Section {
            curvePanel(title: L("Pointer Movement"),
                       subtitle: L("Finger velocity → pointer gain"),
                       icon: "cursorarrow.motionlines",
                       accent: .blue,
                       target: .pointer)

            DisclosureGroup {
                VStack(spacing: 13) {
                    slider(icon: "cursorarrow.motionlines", title: L("Base speed"),
                           value: $model.tune.cursorSpeed, range: 0.1...3.0,
                           minIcon: "tortoise.fill", maxIcon: "hare.fill",
                           display: { String(format: "%.2f×", $0) })
                    slider(icon: "hand.raised.fill", title: L("Steadiness"),
                           value: $model.tune.cursorDeadzone, range: 0.0...0.02,
                           minIcon: "scribble.variable", maxIcon: "hand.raised.fill",
                           display: { String(format: "%.0f", $0 * 1000) })
                    slider(icon: "tortoise.fill", title: L("Slow-move gain"),
                           value: $model.tune.accelMin, range: 0.05...2.0,
                           minIcon: "tortoise.fill", maxIcon: "cursorarrow.motionlines",
                           display: { String(format: "%.2f×", $0) })
                    slider(icon: "hare.fill", title: L("Fast-move gain"),
                           value: $model.tune.accelMax, range: 0.5...8.0,
                           minIcon: "cursorarrow.motionlines", maxIcon: "hare.fill",
                           display: { String(format: "%.2f×", $0) })
                    slider(icon: "arrow.down.forward", title: L("Slow threshold"),
                           value: $model.tune.accelLowSpeed, range: 0.001...0.05,
                           minIcon: "tortoise.fill", maxIcon: "hare.fill",
                           display: { String(format: "%.0f", $0 * 1000) })
                    slider(icon: "arrow.up.forward", title: L("Fast threshold"),
                           value: $model.tune.accelHighSpeed, range: 0.01...0.14,
                           minIcon: "tortoise.fill", maxIcon: "hare.fill",
                           display: { String(format: "%.0f", $0 * 1000) })
                    slider(icon: "point.topleft.down.curvedto.point.bottomright.up",
                           title: L("Curve shape"), value: curveBinding(for: .pointer),
                           range: 0.35...4.0, minIcon: "arrow.up.right",
                           maxIcon: "arrow.turn.up.right",
                           display: { String(format: "%.2f", $0) })

                    Divider()
                    Toggle(isOn: $model.tune.findCursorEnabled) {
                        rowLabel(L("Find cursor on shake"), "cursorarrow.rays")
                    }
                    Toggle(isOn: $model.tune.focusFollowsCursor) {
                        rowLabel(L("Focus app under cursor"), "macwindow.on.rectangle")
                    }
                }
                .padding(.top, 9)
            } label: {
                Label(L("Pointer fine tuning"), systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium))
            }
        } header: {
            Text(L("Pointer Movement"))
        } footer: {
            Text(L("Only these controls affect pointer movement. Changes apply live while you drag the graph or a slider."))
        }
    }

    private var circularMovementSection: some View {
        Section {
            Toggle(isOn: $model.tune.circularEnabled) {
                rowLabel(L("Enable ring scrolling"), "arrow.clockwise")
            }

            if model.tune.circularEnabled {
                curvePanel(title: L("Ring Scrolling"),
                           subtitle: L("Ring rotation → scroll gain"),
                           icon: "arrow.clockwise",
                           accent: .orange,
                           target: .circular)

                DisclosureGroup {
                    VStack(spacing: 13) {
                        slider(icon: "circle.dashed", title: L("Outer ring only"),
                               value: $model.tune.circularMinRadius, range: 0.15...0.45,
                               minIcon: "smallcircle.filled.circle.fill", maxIcon: "circle",
                               display: { String(format: "%.0f%%", $0 * 100) })
                        slider(icon: "timer", title: L("Start resistance"),
                               value: $model.tune.circularStartThreshold, range: 0.1...1.5,
                               minIcon: "hare.fill", maxIcon: "tortoise.fill",
                               display: { String(format: "%.0f°", $0 * 180 / .pi) })
                        slider(icon: "speedometer", title: L("Base scroll speed"),
                               value: $model.tune.circularPixelsPerRadian, range: 40...600,
                               minIcon: "tortoise.fill", maxIcon: "hare.fill",
                               display: { String(format: "%.0f", $0) })
                        slider(icon: "wind", title: L("Smoothness"),
                               value: $model.tune.circularScrollEase, range: 0.1...0.6,
                               minIcon: "tortoise.fill", maxIcon: "hare.fill",
                               display: { String(format: "%.2f", $0) })
                        slider(icon: "tortoise.fill", title: L("Slow-scroll gain"),
                               value: $model.tune.circularAccelMin, range: 0.05...2.0,
                               minIcon: "minus", maxIcon: "plus",
                               display: { String(format: "%.2f×", $0) })
                        slider(icon: "hare.fill", title: L("Fast-scroll gain"),
                               value: $model.tune.circularAccelMax, range: 0.5...6.0,
                               minIcon: "minus", maxIcon: "plus",
                               display: { String(format: "%.2f×", $0) })
                        slider(icon: "arrow.down.forward", title: L("Slow threshold"),
                               value: $model.tune.circularAccelLowSpeed, range: 0.001...0.05,
                               minIcon: "tortoise.fill", maxIcon: "hare.fill",
                               display: { String(format: "%.0f", $0 * 1000) })
                        slider(icon: "arrow.up.forward", title: L("Fast threshold"),
                               value: $model.tune.circularAccelHighSpeed, range: 0.01...0.16,
                               minIcon: "tortoise.fill", maxIcon: "hare.fill",
                               display: { String(format: "%.0f", $0 * 1000) })
                        slider(icon: "point.topleft.down.curvedto.point.bottomright.up",
                               title: L("Curve shape"), value: curveBinding(for: .circular),
                               range: 0.35...4.0, minIcon: "arrow.up.right",
                               maxIcon: "arrow.turn.up.right",
                               display: { String(format: "%.2f", $0) })

                        Divider()
                        Toggle(isOn: $model.tune.circularInvert) {
                            rowLabel(L("Reverse direction"), "arrow.left.arrow.right")
                        }
                    }
                    .padding(.top, 9)
                } label: {
                    Label(L("Ring fine tuning"), systemImage: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                }
            }
        } header: {
            Text(L("Ring Scrolling"))
        } footer: {
            Text(L("Only these controls affect rotation around the outer ring. Pointer movement keeps its own independent curve above."))
        }
        .animation(.easeInOut(duration: 0.18), value: model.tune.circularEnabled)
    }

    private var generalSettingsIntro: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("General Settings"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(L("Click, button timing, on-screen feedback, startup and device information."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func curvePanel(title: String, subtitle: String, icon: String,
                            accent: Color, target: CurveTarget) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(target == .pointer ? L("POINTER") : L("SCROLL"))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(accent.opacity(0.12)))
            }

            if target == .pointer {
                AccelCurveView(
                    accelMin: $model.tune.accelMin,
                    accelMax: $model.tune.accelMax,
                    lowSpeed: $model.tune.accelLowSpeed,
                    highSpeed: $model.tune.accelHighSpeed,
                    curve: curveBinding(for: .pointer),
                    limits: .pointer,
                    accent: accent,
                    slowLabel: L("slow pointer"),
                    fastLabel: L("fast pointer"),
                    formatSpeed: { String(format: "%.0f", $0 * 1000) },
                    shapeLinked: model.tune.accelerationCurvesLinked,
                    onInteraction: { lastEditedCurve = .pointer })
            } else {
                AccelCurveView(
                    accelMin: $model.tune.circularAccelMin,
                    accelMax: $model.tune.circularAccelMax,
                    lowSpeed: $model.tune.circularAccelLowSpeed,
                    highSpeed: $model.tune.circularAccelHighSpeed,
                    curve: curveBinding(for: .circular),
                    limits: .circular,
                    accent: accent,
                    slowLabel: L("slow scroll"),
                    fastLabel: L("fast scroll"),
                    formatSpeed: { String(format: "%.0f", $0 * 1000) },
                    shapeLinked: model.tune.accelerationCurvesLinked,
                    onInteraction: { lastEditedCurve = .circular })
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(accent.opacity(0.16), lineWidth: 1)
        )
    }

    // MARK: - Tab switcher

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(Tab.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 220)
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
                Text(L("Touch & gesture tuning"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            tabPicker
            Spacer()
            saveStatusPill
            statusPill
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(.bar)
    }

    private var saveStatusPill: some View {
        let appearance: (icon: String, label: String, color: Color, error: String?)
        switch model.configSaveState {
        case .saving:
            appearance = ("arrow.triangle.2.circlepath", L("Saving…"), .secondary, nil)
        case .saved:
            appearance = ("checkmark.circle.fill", L("Auto-saved"), .green, nil)
        case .failed(let message):
            appearance = ("exclamationmark.triangle.fill", L("Save failed"), .red, message)
        }

        return Button {
            if let message = appearance.error { saveErrorDetail = message }
        } label: {
            HStack(spacing: 6) {
                if model.configSaveState == .saving {
                    ProgressView().controlSize(.mini).frame(width: 11, height: 11)
                } else {
                    Image(systemName: appearance.icon)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(appearance.color)
                }
                Text(appearance.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(appearance.error == nil ? .secondary : appearance.color)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(
                appearance.error == nil ? Color.secondary.opacity(0.10) : Color.red.opacity(0.10)
            ))
        }
        .buttonStyle(.plain)
        .help(appearance.error ?? L("GUI changes are saved automatically to config.jsonc."))
        .animation(.easeInOut(duration: 0.2), value: model.configSaveState)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.connected ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 7, height: 7)
            Text(model.connected ? L("Connected") : L("Waiting"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            if model.connected, let pct = device.battery {
                Divider().frame(height: 9)
                Image(systemName: batterySymbol(pct))
                    .font(.system(size: 11))
                    .foregroundStyle(batteryTint(pct))
                Text("\(pct)%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(.quaternary))
        .animation(.easeInOut(duration: 0.2), value: device.battery)
    }

    private func batterySymbol(_ pct: Int) -> String {
        switch pct {
        case ..<13:  return "battery.0percent"
        case ..<38:  return "battery.25percent"
        case ..<63:  return "battery.50percent"
        case ..<88:  return "battery.75percent"
        default:     return "battery.100percent"
        }
    }

    private func batteryTint(_ pct: Int) -> Color {
        pct < 20 ? .red : (pct < 40 ? .orange : .secondary)
    }

    // MARK: - Device

    private var deviceSection: some View {
        Section {
            if model.connected {
                if let pct = device.battery {
                    LabeledContent {
                        HStack(spacing: 6) {
                            Image(systemName: batterySymbol(pct)).foregroundStyle(batteryTint(pct))
                            Text("\(pct)%").monospacedDigit()
                        }
                    } label: { rowLabel(L("Battery"), "bolt.fill") }
                }
                if let fw = device.firmware {
                    LabeledContent {
                        Text(fw).monospacedDigit().foregroundStyle(.secondary)
                    } label: { rowLabel(L("Firmware"), "cpu") }
                }
                if let addr = device.address {
                    LabeledContent {
                        Text(addr)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } label: { rowLabel(L("Bluetooth address"), "dot.radiowaves.left.and.right") }
                }
                if let name = device.name {
                    LabeledContent {
                        Text(name)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } label: { rowLabel(L("Serial"), "number") }
                }
                if let vid = device.vendorID, let pid = device.productID {
                    LabeledContent {
                        Text("\(vid) / \(pid)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } label: { rowLabel(L("Vendor / Product"), "tag") }
                }
                if !device.interfaces.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(device.interfaces) { i in
                                HStack(spacing: 8) {
                                    Text(i.usageDescription)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 92, alignment: .leading)
                                    Text(i.label).font(.system(size: 11))
                                    Spacer()
                                    Text(L("in %d · feat %d", i.maxInput, i.maxFeature))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        rowLabel(L("HID interfaces (%d)", device.interfaces.count), "list.bullet.indent")
                    }
                }
            } else {
                Text(L("Remote not connected"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text(L("Device"))
                Spacer()
                Button {
                    device.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .disabled(device.refreshing)
                .help(L("Refresh device information"))
            }
        } footer: {
            Text(device.updatedAt == nil
                 ? L("The remote's microphone is not readable on macOS — see %@", "docs/mic-reverse-engineering.md")
                 : L("Battery and firmware come from the system Bluetooth stack. The microphone is not readable on macOS."))
                .font(.system(size: 11))
        }
    }

    // MARK: - Sections

    private var clickSection: some View {
        Section {
            slider(icon: "hand.tap.fill", title: L("Press sensitivity"),
                   value: $model.tune.clickRiseThreshold, range: 0.04...0.25,
                   minIcon: "hare.fill", maxIcon: "tortoise.fill",
                   display: { String(format: "%.2f", $0) })
            slider(icon: "arrow.up.and.down.and.arrow.left.and.right", title: L("Move tolerance"),
                   value: $model.tune.pressMoveMax, range: 0.01...0.06,
                   minIcon: "smallcircle.filled.circle.fill", maxIcon: "circle",
                   display: { String(format: "%.3f", $0) })
        } header: {
            Text(L("Click"))
        } footer: {
            Text(L("Pressing to click freezes the cursor so it doesn't drift. Lower sensitivity freezes more readily; higher move tolerance keeps it from feeling stuck."))
        }
    }

    private var buttonsSection: some View {
        Section {
            slider(icon: "clock", title: L("Long-press time"),
                   value: $model.tune.holdThreshold, range: 0.2...1.2,
                   minIcon: "hare.fill", maxIcon: "tortoise.fill",
                   display: { String(format: "%.1fs", $0) })
            slider(icon: "hand.tap.fill", title: L("Double-tap speed"),
                   value: $model.tune.doubleTapWindow, range: 0.15...0.6,
                   minIcon: "hare.fill", maxIcon: "tortoise.fill",
                   display: { String(format: "%.2fs", $0) })
            slider(icon: "rectangle.on.rectangle", title: L("Spaces Mode timeout"),
                   value: $model.tune.spacesModeWindow, range: 2.0...15.0,
                   minIcon: "hare.fill", maxIcon: "tortoise.fill",
                   display: { String(format: "%.0fs", $0) })
        } header: {
            Text(L("Buttons"))
        } footer: {
            Text(L("Long-press time: how long to hold a button before its \u{201C}.hold\u{201D} fires. Double-tap speed: the window for a second tap to trigger a \u{201C}.double\u{201D} binding instead of a second single press. Spaces Mode timeout: after long-pressing ring-up to arm desktop switching, how long without a left/right switch before it disarms."))
        }
    }

    /// Shape is the dimensionless exponent only. End gains, thresholds, and the two base-speed
    /// controls never cross the link because pointer delta/frame and ring radians/frame are not
    /// interchangeable units.
    private func curveBinding(for target: CurveTarget) -> Binding<Double> {
        Binding(
            get: {
                switch target {
                case .pointer: return model.tune.accelCurve
                case .circular: return model.tune.circularAccelCurve
                }
            },
            set: { newValue in
                lastEditedCurve = target
                var tune = model.tune
                switch target {
                case .pointer: tune.accelCurve = newValue
                case .circular: tune.circularAccelCurve = newValue
                }
                if tune.accelerationCurvesLinked {
                    tune.accelCurve = newValue
                    tune.circularAccelCurve = newValue
                }
                model.tune = tune
            }
        )
    }

    private var shapeLockButton: some View {
        Button {
            var tune = model.tune
            let shouldLink = !tune.accelerationCurvesLinked
            if shouldLink {
                // Closing the lock uses the last graph the user touched as the source, so enabling
                // it never unexpectedly destroys the curve they just finished shaping.
                let source = lastEditedCurve == .pointer ? tune.accelCurve : tune.circularAccelCurve
                tune.accelCurve = source
                tune.circularAccelCurve = source
            }
            tune.accelerationCurvesLinked = shouldLink
            model.tune = tune
        } label: {
            Label(model.tune.accelerationCurvesLinked ? L("Locked") : L("Independent"),
                  systemImage: model.tune.accelerationCurvesLinked ? "lock.fill" : "lock.open")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(model.tune.accelerationCurvesLinked ? .accentColor : .secondary)
        .help(model.tune.accelerationCurvesLinked
              ? L("Pointer and scroll use the same normalised curve shape. Click to edit independently.")
              : L("Click to lock both normalised curve shapes. Numeric speed and gain ranges stay independent."))
    }

    private var startupSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { launchAtLogin },
                set: { wanted in
                    do {
                        try LaunchAtLogin.setEnabled(wanted)
                        launchAtLoginError = nil
                    } catch {
                        launchAtLoginError = error.localizedDescription
                    }
                    // Always re-read the real registration rather than trusting `wanted`, so the
                    // switch cannot sit in a position macOS did not actually accept.
                    launchAtLogin = LaunchAtLogin.state.isOn
                }
            )) {
                rowLabel(L("Start at login"), "arrow.up.forward.app")
            }
            .disabled(LaunchAtLogin.state == .unavailable)
        } header: {
            Text(L("Startup"))
        } footer: {
            Text(launchAtLoginError.map { L("Couldn't change it: %@", $0) }
                 ?? LaunchAtLogin.note
                 ?? L("Runs HyperVibe automatically after you log in. Also listed under System Settings → General → Login Items."))
                .font(.system(size: 11))
                .foregroundStyle(launchAtLoginError == nil ? Color.secondary : Color.red)
        }
    }

    private var widgetSection: some View {
        Section {
            Toggle(isOn: $model.tune.statusWidgetEnabled) {
                rowLabel(L("Always-on status widget"), "rectangle.on.rectangle")
            }
            Toggle(isOn: $model.tune.holdHUDEnabled) {
                rowLabel(L("Long-press progress HUD"), "wave.3.right.circle.fill")
            }
        } header: {
            Text(L("On-screen Status"))
        } footer: {
            Text(L("The compact widget stays above every app, shows the current Layer at rest, and follows a hold until release. The larger progress HUD visualises release-to-select stages. They can be enabled independently."))
        }
    }

    private var languageSection: some View {
        Section {
            Picker(selection: Binding(
                get: { loc.language },
                set: { loc.language = $0 }
            )) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            } label: {
                rowLabel(L("Interface language"), "globe")
            }
            .pickerStyle(.menu)
        } header: {
            Text(L("Language"))
        } footer: {
            Text(L("The whole app switches immediately — no relaunch needed."))
                .font(.system(size: 11))
        }
    }

    private var footerSection: some View {
        Section {
            Button(role: .destructive) {
                withAnimation { model.resetToDefaults() }
            } label: {
                rowLabel(L("Reset to defaults"), "arrow.counterclockwise")
            }
        } footer: {
            Text(L("Button, ring, and swipe mappings live in %@", "~/.config/siriremote/config.jsonc"))
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

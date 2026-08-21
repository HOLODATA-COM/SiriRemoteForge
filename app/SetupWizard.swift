//
//  SetupWizard.swift
//  HyperVibe
//
//  First-run setup guide for a fresh Mac. Walks the user through the things the app genuinely needs
//  before it can work — the two permissions (Accessibility to move the pointer / press keys, Input
//  Monitoring to read the remote), pairing the remote, and launch-at-login — with LIVE status on
//  every step so granting a permission in System Settings updates the wizard without a relaunch.
//
//  Shown once (UserDefaults `app.setupCompleted`), and re-openable from the menu bar. Step 1 is the
//  language choice, so the rest of the guide reads in the user's language immediately.
//

import AppKit
import SwiftUI
import ApplicationServices
import IOKit.hid

/// Observable remote-connection state, fed from `RemoteDetector` in the app delegate so any surface
/// (the setup wizard here) can react to the remote connecting without owning HID itself.
final class RemoteConnection: ObservableObject {
    static let shared = RemoteConnection()
    @Published var connected = false
    private init() {}
    func update(_ value: Bool) {
        if Thread.isMainThread { connected = value }
        else { DispatchQueue.main.async { self.connected = value } }
    }
}

final class SetupWizardController {
    static let completedKey = "app.setupCompleted"
    private var window: NSWindow?
    private let onFinished: () -> Void
    private let onLanguageChosen: (AppLanguage) -> Void
    private let onLaunchAtLoginChanged: (Bool) -> Void

    init(onFinished: @escaping () -> Void = {},
         onLanguageChosen: @escaping (AppLanguage) -> Void = { _ in },
         onLaunchAtLoginChanged: @escaping (Bool) -> Void = { _ in }) {
        self.onFinished = onFinished
        self.onLanguageChosen = onLanguageChosen
        self.onLaunchAtLoginChanged = onLaunchAtLoginChanged
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SetupWizardView(
                onDone: { [weak self] in self?.finish() },
                onLanguageChosen: onLanguageChosen,
                onLaunchAtLoginChanged: onLaunchAtLoginChanged
            ))
            let win = NSWindow(contentViewController: hosting)
            win.styleMask = [.titled, .fullSizeContentView]
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.isMovableByWindowBackground = true
            win.isReleasedWhenClosed = false
            win.standardWindowButton(.miniaturizeButton)?.isHidden = true
            win.standardWindowButton(.zoomButton)?.isHidden = true
            win.standardWindowButton(.closeButton)?.isHidden = true
            win.setContentSize(NSSize(width: 580, height: 600))
            win.center()
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        window?.close()
        window = nil
        onFinished()
    }
}

// MARK: - Model

final class SetupModel: ObservableObject {
    @Published var step = 0
    @Published var accessibility = false
    @Published var inputMonitoring = false
    @Published var launchAtLogin = LaunchAtLogin.state.isOn

    /// Language, then the two permissions, then pairing, then startup, then the summary.
    static let stepCount = 6
    private var timer: Timer?
    private let onLaunchAtLoginChanged: (Bool) -> Void

    init(onLaunchAtLoginChanged: @escaping (Bool) -> Void = { _ in }) {
        self.onLaunchAtLoginChanged = onLaunchAtLoginChanged
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        let ax = AXIsProcessTrusted()
        let im = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        let login = LaunchAtLogin.state.isOn
        if ax != accessibility { accessibility = ax }
        if im != inputMonitoring { inputMonitoring = im }
        if login != launchAtLogin { launchAtLogin = login }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings("com.apple.preference.security?Privacy_Accessibility")
    }

    func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        openSettings("com.apple.preference.security?Privacy_ListenEvent")
    }

    func openBluetooth() {
        for candidate in ["x-apple.systempreferences:com.apple.Bluetooth-Settings.extension",
                          "x-apple.systempreferences:com.apple.preferences.Bluetooth"] {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    func setLaunchAtLogin(_ wanted: Bool) {
        try? LaunchAtLogin.setEnabled(wanted)
        launchAtLogin = LaunchAtLogin.state.isOn
        onLaunchAtLoginChanged(launchAtLogin)
    }

    private func openSettings(_ path: String) {
        if let url = URL(string: "x-apple.systempreferences:\(path)") { NSWorkspace.shared.open(url) }
    }
}

// MARK: - View

private struct SetupWizardView: View {
    let onDone: () -> Void
    let onLanguageChosen: (AppLanguage) -> Void
    @StateObject private var model: SetupModel
    @ObservedObject private var loc = Loc.shared
    @ObservedObject private var remote = RemoteConnection.shared

    init(onDone: @escaping () -> Void,
         onLanguageChosen: @escaping (AppLanguage) -> Void,
         onLaunchAtLoginChanged: @escaping (Bool) -> Void) {
        self.onDone = onDone
        self.onLanguageChosen = onLanguageChosen
        _model = StateObject(wrappedValue: SetupModel(
            onLaunchAtLoginChanged: onLaunchAtLoginChanged
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            progressBar
            Divider().opacity(0.5)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 44)
            Divider().opacity(0.5)
            navBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    // MARK: Progress

    private var progressBar: some View {
        HStack(spacing: 8) {
            ForEach(0..<SetupModel.stepCount, id: \.self) { index in
                Capsule()
                    .fill(index <= model.step ? Color.accentColor : Color.primary.opacity(0.12))
                    .frame(height: 4)
                    .animation(.easeInOut(duration: 0.25), value: model.step)
            }
        }
        .padding(.horizontal, 44)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    // MARK: Step content

    @ViewBuilder private var content: some View {
        switch model.step {
        case 0: languageStep
        case 1: accessibilityStep
        case 2: inputMonitoringStep
        case 3: connectStep
        case 4: loginStep
        default: doneStep
        }
    }

    private var languageStep: some View {
        VStack(spacing: 26) {
            icon("globe", tint: .accentColor)
            VStack(spacing: 5) {
                Text("Choose your language").font(.system(size: 21, weight: .semibold))
                Text("选择语言").font(.system(size: 14)).foregroundStyle(Color.secondary)
            }
            VStack(spacing: 12) {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        Loc.shared.choose(language)
                        onLanguageChosen(language)
                        advance()
                    } label: {
                        HStack {
                            Text(language.displayName).font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Color.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.secondary)
                        }
                        .padding(.horizontal, 18).frame(width: 300, height: 52)
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(Color.primary.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var accessibilityStep: some View {
        permissionStep(
            symbol: "cursorarrow.rays",
            title: L("Control your Mac"),
            body: L("siriRemote moves the pointer and presses keys for you. macOS requires Accessibility permission to allow this."),
            granted: model.accessibility,
            caution: L("Without this, clicks and keystrokes won't work."),
            button: L("Open Accessibility Settings"),
            action: model.requestAccessibility
        )
    }

    private var inputMonitoringStep: some View {
        permissionStep(
            symbol: "dot.radiowaves.left.and.right",
            title: L("Read your remote"),
            body: L("To receive button presses and the trackpad from the Siri Remote, macOS requires Input Monitoring permission."),
            granted: model.inputMonitoring,
            caution: L("Without this, the remote's buttons and trackpad can't be read."),
            button: L("Open Input Monitoring Settings"),
            action: model.requestInputMonitoring
        )
    }

    private var connectStep: some View {
        VStack(spacing: 22) {
            icon(remote.connected ? "appletvremote.gen4.fill" : "appletvremote.gen4",
                 tint: remote.connected ? .green : .accentColor)
            stepTitle(L("Connect your Siri Remote"))
            stepBody(L("Pair the aluminium Siri Remote (3rd gen) over Bluetooth. It will appear here once connected."))
            statusPill(ok: remote.connected,
                       okText: L("Connected"),
                       waitText: L("Searching…"))
            Button(action: model.openBluetooth) {
                Text(L("Open Bluetooth Settings")).fontWeight(.medium)
            }
            .controlSize(.large)
        }
    }

    private var loginStep: some View {
        VStack(spacing: 22) {
            icon("power", tint: .accentColor)
            stepTitle(L("Start automatically"))
            stepBody(L("Launch siriRemote whenever you log in, so your remote just works."))
            Toggle(isOn: Binding(get: { model.launchAtLogin },
                                 set: { model.setLaunchAtLogin($0) })) {
                Text(L("Start at login")).font(.system(size: 15, weight: .medium))
            }
            .toggleStyle(.switch)
            .frame(width: 300)
            .disabled(LaunchAtLogin.state == .unavailable)
        }
    }

    private var doneStep: some View {
        VStack(spacing: 22) {
            icon("checkmark.circle.fill", tint: .green)
            stepTitle(L("You're all set"))
            stepBody(L("siriRemote is ready. Open Settings any time from the menu bar to customise buttons, gestures and more."))
            Text(L("Tip: the remote's microphone needs an extra one-time setup — see the docs."))
                .font(.system(size: 11))
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 360)
        }
    }

    // MARK: Reusable pieces

    private func permissionStep(symbol: String, title: String, body: String, granted: Bool,
                                caution: String, button: String,
                                action: @escaping () -> Void) -> some View {
        VStack(spacing: 20) {
            icon(symbol, tint: granted ? .green : .accentColor)
            HStack(spacing: 8) {
                stepTitle(title)
                Text(L("Required")).font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.16)))
                    .foregroundStyle(Color.orange)
            }
            stepBody(body)
            statusPill(ok: granted, okText: L("Granted"), waitText: L("Not granted yet"))
            if !granted {
                Text(caution).font(.system(size: 11)).foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center).frame(width: 360)
            }
            Button(action: action) { Text(button).fontWeight(.medium) }
                .controlSize(.large)
                .disabled(granted)
        }
    }

    private func icon(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 46, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(height: 54)
    }

    private func stepTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 21, weight: .semibold)).multilineTextAlignment(.center)
    }

    private func stepBody(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Color.secondary)
            .multilineTextAlignment(.center).frame(width: 400).fixedSize(horizontal: false, vertical: true)
    }

    private func statusPill(ok: Bool, okText: String, waitText: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(ok ? Color.green : Color.secondary)
            Text(ok ? okText : waitText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ok ? Color.green : Color.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(ok ? Color.green.opacity(0.12) : Color.primary.opacity(0.05)))
    }

    // MARK: Navigation

    private var navBar: some View {
        HStack {
            if model.step > 0 {
                Button(L("Back")) { withAnimation(.easeInOut(duration: 0.2)) { model.step -= 1 } }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
            Text(L("Step %d of %d", model.step + 1, SetupModel.stepCount))
                .font(.system(size: 11)).foregroundStyle(Color.secondary)
            Spacer()
            if model.step == 0 {
                // Language advances on selection; keep the row balanced.
                Color.clear.frame(width: 60, height: 1)
            } else if model.step == SetupModel.stepCount - 1 {
                Button(L("Done")) { onDone() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            } else {
                Button(L("Continue")) { advance() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 18)
    }

    private func advance() {
        withAnimation(.easeInOut(duration: 0.2)) {
            model.step = min(model.step + 1, SetupModel.stepCount - 1)
        }
    }
}

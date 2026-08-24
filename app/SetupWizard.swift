//
//  SetupWizard.swift
//  HyperVibe
//
//  A live first-run and recovery surface. Unlike the old three-dialog installer walkthrough, this
//  window never assumes that opening a System Settings pane means permission was granted. Required
//  permissions are checked continuously, optional voice/automation capabilities are explained in
//  context, and the same surface can be reopened whenever something stops working.
//

import AppKit
import SwiftUI

/// Observable remote-connection state, fed from `RemoteDetector` in the app delegate so the setup
/// surface never opens or competes for the HID device itself.
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
    static let languageChosenKey = "app.setupLanguageChosen"

    private var window: NSWindow?
    private let onFinished: () -> Void
    private let onLanguageChosen: (AppLanguage) -> Void
    private let onLaunchAtLoginChanged: (Bool) -> Void
    private let onPermissionStateChanged: () -> Void

    init(onFinished: @escaping () -> Void = {},
         onLanguageChosen: @escaping (AppLanguage) -> Void = { _ in },
         onLaunchAtLoginChanged: @escaping (Bool) -> Void = { _ in },
         onPermissionStateChanged: @escaping () -> Void = {}) {
        self.onFinished = onFinished
        self.onLanguageChosen = onLanguageChosen
        self.onLaunchAtLoginChanged = onLaunchAtLoginChanged
        self.onPermissionStateChanged = onPermissionStateChanged
    }

    func show() {
        if window == nil {
            let hasChosenLanguage = UserDefaults.standard.bool(forKey: Self.languageChosenKey)
                || UserDefaults.standard.bool(forKey: Self.completedKey)
            let hosting = NSHostingController(rootView: SetupWizardView(
                initialStep: hasChosenLanguage ? 1 : 0,
                onDone: { [weak self] in self?.finish() },
                onLanguageChosen: onLanguageChosen,
                onLaunchAtLoginChanged: onLaunchAtLoginChanged,
                onPermissionStateChanged: onPermissionStateChanged
            ))
            // NSHostingController otherwise promotes the ScrollView's full document height to the
            // window's preferredContentSize (observed as a 4059 px-tall window). The setup window
            // owns its geometry; SwiftUI lays out inside it and scrolls only the feature list.
            hosting.sizingOptions = []
            hosting.view.frame = NSRect(x: 0, y: 0, width: 760, height: 680)
            let win = NSWindow(contentViewController: hosting)
            win.styleMask = [.titled, .closable, .fullSizeContentView]
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.isMovableByWindowBackground = true
            win.isReleasedWhenClosed = false
            win.title = L("System Check")
            win.standardWindowButton(.miniaturizeButton)?.isHidden = true
            win.standardWindowButton(.zoomButton)?.isHidden = true
            win.setContentSize(NSSize(width: 760, height: 680))
            win.minSize = NSSize(width: 700, height: 620)
            win.maxSize = NSSize(width: 1100, height: 900)
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
    @Published var step: Int
    @Published private(set) var readiness: SystemReadinessSnapshot
    @Published private(set) var automationState: AutomationPermissionState = .checking
    @Published var launchAtLoginError: String?

    static let stepCount = 5

    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private let onLaunchAtLoginChanged: (Bool) -> Void
    private let onPermissionStateChanged: () -> Void
    private var previousAccessibility: Bool
    private var previousInputMonitoring: Bool

    init(initialStep: Int,
         onLaunchAtLoginChanged: @escaping (Bool) -> Void = { _ in },
         onPermissionStateChanged: @escaping () -> Void = {}) {
        let initialReadiness = SystemReadiness.snapshot()
        step = min(max(initialStep, 0), Self.stepCount - 1)
        readiness = initialReadiness
        previousAccessibility = initialReadiness.accessibilityGranted
        previousInputMonitoring = initialReadiness.inputMonitoringGranted
        self.onLaunchAtLoginChanged = onLaunchAtLoginChanged
        self.onPermissionStateChanged = onPermissionStateChanged

        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refresh() }

        refreshAutomation(askUserIfNeeded: false)
    }

    deinit {
        timer?.invalidate()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    var coreReady: Bool { readiness.corePermissionsGranted }

    func refresh() {
        let updated = SystemReadiness.snapshot(automation: automationState)
        readiness = updated

        if updated.accessibilityGranted != previousAccessibility
            || updated.inputMonitoringGranted != previousInputMonitoring {
            previousAccessibility = updated.accessibilityGranted
            previousInputMonitoring = updated.inputMonitoringGranted
            onPermissionStateChanged()
        }
    }

    func chooseLanguage(_ language: AppLanguage) {
        Loc.shared.choose(language)
        UserDefaults.standard.set(true, forKey: SetupWizardController.languageChosenKey)
    }

    func requestAccessibility() {
        SystemReadiness.requestAccessibility()
        scheduleRefresh()
    }

    func requestInputMonitoring() {
        SystemReadiness.requestInputMonitoring()
        scheduleRefresh()
    }

    func requestMicrophone() {
        if readiness.microphone == .denied || readiness.microphone == .restricted {
            SystemReadiness.openMicrophoneSettings()
            return
        }
        SystemReadiness.requestMicrophone { [weak self] in self?.refresh() }
    }

    func requestAutomation() {
        refreshAutomation(askUserIfNeeded: true)
    }

    func setLaunchAtLogin(_ wanted: Bool) {
        do {
            try LaunchAtLogin.setEnabled(wanted)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refresh()
        onLaunchAtLoginChanged(readiness.launchAtLogin.isOn)
    }

    private func refreshAutomation(askUserIfNeeded: Bool) {
        automationState = .checking
        readiness = SystemReadiness.snapshot(automation: .checking)
        SystemReadiness.checkAutomationPermission(askUserIfNeeded: askUserIfNeeded) {
            [weak self] state in
            guard let self else { return }
            self.automationState = state
            self.refresh()
        }
    }

    private func scheduleRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.refresh() }
    }
}

// MARK: - View

private struct SetupWizardView: View {
    let onDone: () -> Void
    let onLanguageChosen: (AppLanguage) -> Void

    @StateObject private var model: SetupModel
    @ObservedObject private var loc = Loc.shared
    @ObservedObject private var remote = RemoteConnection.shared

    init(initialStep: Int,
         onDone: @escaping () -> Void,
         onLanguageChosen: @escaping (AppLanguage) -> Void,
         onLaunchAtLoginChanged: @escaping (Bool) -> Void,
         onPermissionStateChanged: @escaping () -> Void) {
        self.onDone = onDone
        self.onLanguageChosen = onLanguageChosen
        _model = StateObject(wrappedValue: SetupModel(
            initialStep: initialStep,
            onLaunchAtLoginChanged: onLaunchAtLoginChanged,
            onPermissionStateChanged: onPermissionStateChanged
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            progressBar
            Divider().opacity(0.45)
            ZStack {
                content
                    .id(model.step)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)),
                        removal: .opacity.combined(with: .move(edge: .leading))
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48)
            Divider().opacity(0.45)
            navBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 700, idealWidth: 760, maxWidth: 1100,
               minHeight: 620, idealHeight: 680, maxHeight: 900)
        .background(.ultraThinMaterial)
        .environment(\.locale, Locale(identifier: loc.language.rawValue))
    }

    private var progressBar: some View {
        HStack(spacing: 8) {
            ForEach(0..<SetupModel.stepCount, id: \.self) { index in
                Capsule()
                    .fill(index <= model.step ? Color.accentColor : Color.primary.opacity(0.11))
                    .frame(height: 4)
                    .animation(.easeInOut(duration: 0.22), value: model.step)
            }
        }
        .padding(.horizontal, 48)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case 0: languageStep
        case 1: corePermissionsStep
        case 2: voiceAndAutomationStep
        case 3: connectStep
        default: summaryStep
        }
    }

    // MARK: Language

    private var languageStep: some View {
        VStack(spacing: 30) {
            heroIcon("globe.americas.fill", tint: .accentColor)
            VStack(spacing: 7) {
                Text("Choose your language").font(.system(size: 25, weight: .semibold))
                Text("选择语言").font(.system(size: 14)).foregroundStyle(Color.secondary)
            }
            HStack(spacing: 14) {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        model.chooseLanguage(language)
                        onLanguageChosen(language)
                        advance()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: language == .english ? "textformat.abc" : "character.book.closed.fill.zh")
                                .font(.system(size: 19, weight: .medium))
                            Text(language.displayName)
                                .font(.system(size: 16, weight: .semibold))
                            Spacer()
                            Image(systemName: "arrow.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.secondary)
                        }
                        .padding(.horizontal, 18)
                        .frame(width: 270, height: 64)
                        .background(cardBackground)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Required permissions

    private var corePermissionsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeading(
                symbol: "checkmark.shield.fill",
                title: L("Make control reliable"),
                body: L("HyperVibe checks the two permissions required for every button, gesture and pointer action. Status updates automatically when you return from System Settings.")
            )

            VStack(spacing: 10) {
                permissionCard(
                    symbol: "cursorarrow.rays",
                    title: L("Accessibility"),
                    body: L("Moves the pointer, clicks, types shortcuts and controls the active window."),
                    granted: model.readiness.accessibilityGranted,
                    requestTitle: L("Request Access"),
                    request: model.requestAccessibility,
                    openSettings: SystemReadiness.openAccessibilitySettings
                )
                permissionCard(
                    symbol: "dot.radiowaves.left.and.right",
                    title: L("Input Monitoring"),
                    body: L("Receives the Siri Remote's buttons, outer ring and touch surface."),
                    granted: model.readiness.inputMonitoringGranted,
                    requestTitle: L("Request Access"),
                    request: model.requestInputMonitoring,
                    openSettings: SystemReadiness.openInputMonitoringSettings
                )
            }

            HStack(spacing: 10) {
                Image(systemName: model.coreReady ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(model.coreReady ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.coreReady ? L("Core controls are ready") : L("Finish both required permissions to continue"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(L("macOS keeps these switches under your control; the installer cannot enable them silently."))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                }
                Spacer()
                Button {
                    model.refresh()
                } label: {
                    Label(L("Recheck"), systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill((model.coreReady ? Color.green : Color.orange).opacity(0.09)))
        }
    }

    // MARK: Optional / feature-specific setup

    private var voiceAndAutomationStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeading(
                symbol: "waveform.badge.mic",
                title: L("Unlock voice and advanced actions"),
                body: L("These checks are feature-specific. Pointer, scrolling and ordinary buttons already work even if you finish them later.")
            )

            ScrollView {
                VStack(spacing: 10) {
                    microphonePermissionCard

                    componentCard(
                        symbol: "waveform.path",
                        title: L("Siri Remote Mic components"),
                        body: L("The virtual microphone, router and on-demand capture service are installed by the Full Installer."),
                        ready: model.readiness.microphoneStackInstalled,
                        readyText: L("Installed"),
                        missingText: L("Not installed"),
                        actionTitle: L("Get Full Installer"),
                        action: SystemReadiness.openReleaseDownloads
                    )

                    componentCard(
                        symbol: "shippingbox.fill",
                        title: "Apple PacketLogger",
                        body: L("Required only for voice from the remote. Apple distributes it inside Additional Tools for Xcode."),
                        ready: model.readiness.packetLoggerInstalled,
                        readyText: L("Installed"),
                        missingText: L("Download needed"),
                        actionTitle: L("Open Apple Download"),
                        action: SystemReadiness.openPacketLoggerDownload
                    )

                    automationCard
                }
                .padding(.vertical, 1)
            }
        }
    }

    private var microphonePermissionCard: some View {
        let state = model.readiness.microphone
        let granted = state == .granted
        let status: String = {
            switch state {
            case .granted: return L("Granted")
            case .notRequested: return L("Not requested")
            case .denied: return L("Denied")
            case .restricted: return L("Restricted")
            }
        }()
        return capabilityCard(
            symbol: "mic.fill",
            title: L("Microphone"),
            body: L("Lets the live Voice waveform and built-in microphone fallback hear real audio."),
            status: status,
            statusColor: granted ? .green : (state == .restricted ? .red : .orange),
            actionTitle: granted ? nil : (state == .notRequested ? L("Allow Microphone") : L("Open Settings")),
            action: granted ? nil : model.requestMicrophone,
            settingsAction: SystemReadiness.openMicrophoneSettings
        )
    }

    private var automationCard: some View {
        let state = model.automationState
        let status: String = {
            switch state {
            case .checking: return L("Checking…")
            case .granted: return L("Granted")
            case .notRequested: return L("Not requested")
            case .denied: return L("Denied")
            case .unavailable: return L("Unavailable")
            }
        }()
        let color: Color = state == .granted ? .green : (state == .denied ? .red : .orange)
        let actionTitle: String? = state == .granted || state == .checking
            ? nil : L("Test Automation")
        return capabilityCard(
            symbol: "rectangle.2.swap",
            title: L("Automation"),
            body: L("Used only by Space switching and AppleScript bindings. Testing sends a harmless request to System Events."),
            status: status,
            statusColor: color,
            actionTitle: actionTitle,
            action: actionTitle == nil ? nil : model.requestAutomation,
            settingsAction: SystemReadiness.openAutomationSettings
        )
    }

    // MARK: Remote

    private var connectStep: some View {
        VStack(spacing: 22) {
            heroIcon(remote.connected ? "appletvremote.gen4.fill" : "appletvremote.gen4",
                     tint: remote.connected ? .green : .accentColor)
            VStack(spacing: 8) {
                Text(L("Connect your Siri Remote"))
                    .font(.system(size: 25, weight: .semibold))
                Text(L("Pair the aluminium Siri Remote (3rd gen) over Bluetooth. HyperVibe detects it live — no restart or reconnect button is needed."))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            statusBadge(
                text: remote.connected ? L("Connected") : L("Waiting for remote…"),
                color: remote.connected ? .green : .orange,
                symbol: remote.connected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right"
            )
            Button(action: SystemReadiness.openBluetoothSettings) {
                Label(L("Open Bluetooth Settings"), systemImage: "gear")
                    .fontWeight(.medium)
            }
            .controlSize(.large)
            Text(L("You can continue without the remote and pair it later."))
                .font(.system(size: 11))
                .foregroundStyle(Color.secondary)
        }
    }

    // MARK: Summary

    private var summaryStep: some View {
        VStack(spacing: 20) {
            heroIcon("checkmark.seal.fill", tint: .green)
            VStack(spacing: 7) {
                Text(L("HyperVibe is ready"))
                    .font(.system(size: 25, weight: .semibold))
                Text(L("The system check remains available from the menu bar and Settings whenever you need it."))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                summaryCard(
                    L("Application"),
                    model.readiness.appInstalledInApplications ? L("Installed") : L("Move to Applications"),
                    model.readiness.appInstalledInApplications,
                    "app.badge.checkmark"
                )
                summaryCard(
                    L("Core permissions"),
                    model.coreReady ? L("Ready") : L("Action needed"),
                    model.coreReady,
                    "checkmark.shield"
                )
                summaryCard(
                    L("Siri Remote"),
                    remote.connected ? L("Connected") : L("Pair later"),
                    remote.connected,
                    "appletvremote.gen4"
                )
                summaryCard(
                    L("Remote voice"),
                    model.readiness.voiceReady ? L("Ready") : L("Optional setup incomplete"),
                    model.readiness.voiceReady,
                    "waveform.badge.mic"
                )
            }

            VStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { model.readiness.launchAtLogin.isOn },
                    set: { model.setLaunchAtLogin($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Start at login")).font(.system(size: 14, weight: .semibold))
                        Text(L("Keep the remote ready without opening HyperVibe manually."))
                            .font(.system(size: 11)).foregroundStyle(Color.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(model.readiness.launchAtLogin == .unavailable)

                if let error = model.launchAtLoginError ?? LaunchAtLogin.note {
                    Text(error).font(.system(size: 10)).foregroundStyle(Color.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .background(cardBackground)
        }
    }

    // MARK: Reusable components

    private func sectionHeading(symbol: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 23, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Color.accentColor.opacity(0.10)))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 23, weight: .semibold))
                Text(body).font(.system(size: 12)).foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func permissionCard(symbol: String, title: String, body: String, granted: Bool,
                                requestTitle: String, request: @escaping () -> Void,
                                openSettings: @escaping () -> Void) -> some View {
        capabilityCard(
            symbol: symbol,
            title: title,
            body: body,
            status: granted ? L("Granted") : L("Action needed"),
            statusColor: granted ? .green : .orange,
            actionTitle: granted ? nil : requestTitle,
            action: granted ? nil : request,
            settingsAction: openSettings
        )
    }

    private func componentCard(symbol: String, title: String, body: String, ready: Bool,
                               readyText: String, missingText: String,
                               actionTitle: String, action: @escaping () -> Void) -> some View {
        capabilityCard(
            symbol: symbol,
            title: title,
            body: body,
            status: ready ? readyText : missingText,
            statusColor: ready ? .green : .orange,
            actionTitle: ready ? nil : actionTitle,
            action: ready ? nil : action,
            settingsAction: nil
        )
    }

    private func capabilityCard(symbol: String, title: String, body: String,
                                status: String, statusColor: Color,
                                actionTitle: String?, action: (() -> Void)?,
                                settingsAction: (() -> Void)?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusColor)
                .frame(width: 38, height: 38)
                .background(Circle().fill(statusColor.opacity(0.10)))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    statusBadge(text: status, color: statusColor,
                                symbol: statusColor == .green ? "checkmark.circle.fill" : "circle.dotted")
                }
                Text(body).font(.system(size: 11)).foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            if let actionTitle, let action {
                Button(actionTitle, action: action).controlSize(.small)
            }
            if let settingsAction {
                Button(action: settingsAction) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help(L("Open System Settings"))
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private func statusBadge(text: String, color: Color, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.11)))
    }

    private func summaryCard(_ title: String, _ detail: String, _ ready: Bool,
                             _ symbol: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(ready ? Color.green : Color.orange)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(Color.secondary)
            }
            Spacer()
        }
        .padding(13)
        .background(cardBackground)
    }

    private func heroIcon(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 50, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: 78, height: 78)
            .background(Circle().fill(tint.opacity(0.10)))
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(Color.primary.opacity(0.045))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.075), lineWidth: 1))
    }

    // MARK: Navigation

    private var navBar: some View {
        HStack {
            if model.step > 0 {
                Button(L("Back")) {
                    withAnimation(.easeInOut(duration: 0.22)) { model.step -= 1 }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.secondary)
            } else {
                Color.clear.frame(width: 44, height: 1)
            }
            Spacer()
            Text(L("Step %d of %d", model.step + 1, SetupModel.stepCount))
                .font(.system(size: 11)).foregroundStyle(Color.secondary)
            Spacer()
            if model.step == 0 {
                Color.clear.frame(width: 72, height: 1)
            } else if model.step == SetupModel.stepCount - 1 {
                Button(L("Done")) { onDone() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(!model.coreReady)
            } else {
                Button(model.step == 1 && !model.coreReady ? L("Waiting for access") : L("Continue")) {
                    advance()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(model.step == 1 && !model.coreReady)
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 17)
    }

    private func advance() {
        withAnimation(.easeInOut(duration: 0.22)) {
            model.step = min(model.step + 1, SetupModel.stepCount - 1)
        }
    }
}

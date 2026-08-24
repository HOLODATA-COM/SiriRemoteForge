//
//  SystemReadiness.swift
//  HyperVibe
//
//  One source of truth for first-run and ongoing health checks. Querying this type is passive: it
//  never opens System Settings and never triggers a TCC prompt. Permission prompts only happen from
//  the explicit request methods after the user has read why a capability is needed.
//

import AppKit
import ApplicationServices
import AVFoundation
import CoreServices
import IOKit.hid

enum MicrophonePermissionState: Equatable {
    case granted
    case notRequested
    case denied
    case restricted
}

enum AutomationPermissionState: Equatable {
    case checking
    case granted
    case notRequested
    case denied
    case unavailable
}

struct SystemReadinessSnapshot: Equatable {
    let accessibilityGranted: Bool
    let inputMonitoringGranted: Bool
    let microphone: MicrophonePermissionState
    let automation: AutomationPermissionState
    let appInstalledInApplications: Bool
    let microphoneStackInstalled: Bool
    let packetLoggerInstalled: Bool
    let launchAtLogin: LaunchAtLogin.State

    var corePermissionsGranted: Bool {
        accessibilityGranted && inputMonitoringGranted
    }

    var voiceReady: Bool {
        microphone == .granted && microphoneStackInstalled && packetLoggerInstalled
    }
}

enum SystemReadiness {
    private static let appPath = "/Applications/HyperVibe.app"
    private static let systemEventsBundleID = "com.apple.systemevents"

    static func snapshot(automation: AutomationPermissionState = .checking) -> SystemReadinessSnapshot {
        let microphone: MicrophonePermissionState
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .notRequested
        case .denied: microphone = .denied
        case .restricted: microphone = .restricted
        @unknown default: microphone = .restricted
        }

        let fm = FileManager.default
        let microphoneStackInstalled = [
            "/Library/Audio/Plug-Ins/HAL/SiriRemoteMic.driver",
            "/Library/Application Support/SiriRemoteMic/srm_router",
            "/Library/Application Support/SiriRemoteMic/srm_captured",
            "/Library/LaunchDaemons/au.holodata.SiriRemoteMic.captured.plist",
        ].allSatisfy { fm.fileExists(atPath: $0) }

        let runningPath = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let installedPath = URL(fileURLWithPath: appPath)
            .resolvingSymlinksInPath().standardizedFileURL.path

        return SystemReadinessSnapshot(
            accessibilityGranted: AXIsProcessTrusted(),
            inputMonitoringGranted: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
                == kIOHIDAccessTypeGranted,
            microphone: microphone,
            automation: automation,
            appInstalledInApplications: runningPath == installedPath,
            microphoneStackInstalled: microphoneStackInstalled,
            packetLoggerInstalled: fm.fileExists(atPath: "/Applications/PacketLogger.app"),
            launchAtLogin: LaunchAtLogin.state
        )
    }

    /// Register HyperVibe with the Accessibility privacy service and let macOS present its native
    /// explanation. Opening the pane is a separate UI affordance, so the user never gets a prompt
    /// and a settings jump piled on top of one another.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// IOHID does not reliably list an app until it has made this explicit request. This call is
    /// user-initiated from the readiness screen; normal startup only performs the passive check.
    static func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func requestMicrophone(completion: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async(execute: completion)
            }
        default:
            completion()
        }
    }

    static func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        openPrivacyPane("Privacy_ListenEvent")
    }

    static func openMicrophoneSettings() {
        openPrivacyPane("Privacy_Microphone")
    }

    static func openAutomationSettings() {
        openPrivacyPane("Privacy_Automation")
    }

    static func openBluetoothSettings() {
        for candidate in [
            "x-apple.systempreferences:com.apple.Bluetooth-Settings.extension",
            "x-apple.systempreferences:com.apple.preferences.Bluetooth",
        ] {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    static func openPacketLoggerDownload() {
        guard let url = URL(string: "https://developer.apple.com/download/all/?q=Additional+Tools+for+Xcode")
        else { return }
        NSWorkspace.shared.open(url)
    }

    static func openReleaseDownloads() {
        guard let url = URL(string: "https://github.com/HOLODATA-COM/SiriRemoteForge/releases")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Check the actual Apple Events permission used by Space switching. Apple requires the target
    /// to be running, so System Events is launched as a non-activating background application first.
    /// The C API may block while macOS displays consent UI; keep it off the main thread.
    static func checkAutomationPermission(
        askUserIfNeeded: Bool,
        completion: @escaping (AutomationPermissionState) -> Void
    ) {
        ensureSystemEventsRunning { app in
            guard let app else {
                DispatchQueue.main.async { completion(.unavailable) }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let state = determineAutomationPermission(
                    processIdentifier: app.processIdentifier,
                    askUserIfNeeded: askUserIfNeeded
                )
                DispatchQueue.main.async { completion(state) }
            }
        }
    }

    private static func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func ensureSystemEventsRunning(
        completion: @escaping (NSRunningApplication?) -> Void
    ) {
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: systemEventsBundleID).first {
            completion(running)
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: systemEventsBundleID
        ) else {
            completion(nil)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
            completion(app)
        }
    }

    private static func determineAutomationPermission(
        processIdentifier: pid_t,
        askUserIfNeeded: Bool
    ) -> AutomationPermissionState {
        var pid = processIdentifier
        var target = AEAddressDesc(descriptorType: typeNull, dataHandle: nil)
        let createStatus = AECreateDesc(
            DescType(typeKernelProcessID),
            &pid,
            MemoryLayout<pid_t>.size,
            &target
        )
        guard createStatus == noErr else { return .unavailable }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askUserIfNeeded
        )
        if status == noErr { return .granted }
        if status == OSStatus(errAEEventWouldRequireUserConsent) { return .notRequested }
        if status == OSStatus(errAEEventNotPermitted) { return .denied }
        return .unavailable
    }
}

extension Notification.Name {
    static let hyperVibeOpenSystemCheck = Notification.Name("com.hypervibe.openSystemCheck")
}

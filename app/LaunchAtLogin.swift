//
//  LaunchAtLogin.swift
//  HyperVibe
//
//  Start at login via SMAppService (macOS 13+). Registration is by bundle, so it follows
//  HyperVibe.app wherever it lives and survives rebuilds in place — no LaunchAgent plist to keep in
//  sync with the binary's path. The registration also shows up in System Settings → General →
//  Login Items, so it can always be turned off there even if this app is not running.
//

import Foundation
import ServiceManagement

enum LaunchAtLogin {

    enum State: Equatable {
        /// Registered and will start at login.
        case enabled
        /// Not registered.
        case disabled
        /// Registered, but macOS wants the user to approve it in System Settings → Login Items.
        case requiresApproval
        /// SMAppService could not find this bundle to register (e.g. running the bare binary rather
        /// than HyperVibe.app).
        case unavailable

        var isOn: Bool { self == .enabled || self == .requiresApproval }
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled:          return .enabled
        case .notRegistered:    return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound:         return .unavailable
        @unknown default:       return .unavailable
        }
    }

    /// Register or unregister. Throws so callers can surface the real failure instead of silently
    /// leaving the toggle in a state that does not match reality.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            // Registering while already registered throws; treat that as success.
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status != .notRegistered else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    /// Short human-readable note for the UI — nil when there is nothing worth saying.
    static var note: String? {
        switch state {
        case .enabled:  return nil
        case .disabled: return nil
        case .requiresApproval:
            return "Approve HyperVibe in System Settings → General → Login Items to finish enabling."
        case .unavailable:
            return "Unavailable — run the packaged HyperVibe.app (not the bare ./HyperVibe binary)."
        }
    }

    /// `--enable-login-item` / `--disable-login-item`: apply and exit. Registration must be made by
    /// the app bundle itself (SMAppService.mainApp is always the *calling* bundle), so this is how
    /// it can be scripted rather than only toggled in the UI.
    static func handleCommandLineIfNeeded() {
        let args = CommandLine.arguments
        let wantsEnable = args.contains("--enable-login-item")
        let wantsDisable = args.contains("--disable-login-item")
        guard wantsEnable || wantsDisable else { return }

        do {
            try setEnabled(wantsEnable)
            print("launch-at-login → \(state)")
            if let note = note { print("note: \(note)") }
            exit(0)
        } catch {
            print("launch-at-login FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }
}

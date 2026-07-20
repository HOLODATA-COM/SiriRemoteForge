//
//  SettingsModel.swift
//  HyperVibe (settings UI)
//

import Foundation
import Combine

/// Observable wrapper around TuneSettings. Any change persists and applies live.
final class SettingsModel: ObservableObject {
    @Published var tune: TuneSettings {
        didSet {
            guard tune != oldValue else { return }
            // Persistence is via config.jsonc (SiriRemoteApp.persistTuneToConfig) — config is the
            // single source of truth; there's no separate UserDefaults store.
            onApply?(tune)
        }
    }

    /// Live connection status shown in the window header.
    @Published var connected: Bool = false

    /// Remote battery/firmware/interfaces. Owned here rather than by the SwiftUI view so the
    /// window controller can start and stop the polling: the settings window is cached with
    /// `isReleasedWhenClosed = false`, so closing it only orders it out and SwiftUI's
    /// `.onDisappear` never runs — a view-owned poller would keep spawning `system_profiler`
    /// forever with the window shut.
    let device = DeviceInfo()

    /// The live parsed config (modes / bindings / appProfiles), refreshed on hot-reload.
    /// Read-only for the "Layout" tab. Set by AppDelegate at load and on every config reload.
    @Published var config: Config?

    /// Set by AppDelegate to push values into the running TouchHandler.
    var onApply: ((TuneSettings) -> Void)?

    init(initial: TuneSettings) {
        self.tune = initial
    }

    func resetToDefaults() {
        tune = .default
    }
}

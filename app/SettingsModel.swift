//
//  SettingsModel.swift
//  HyperVibe (settings UI)
//

import Foundation
import Combine

enum ConfigSaveState: Equatable {
    case saving
    case saved
    case failed(String)
}

enum ConfigSaveSource: Hashable {
    case tuning
    case layout
}

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

    /// One status for both GUI writers: debounced Tuning edits and immediate Layout edits. Keeping
    /// it on the shared model makes the header tell the truth whichever tab initiated the write.
    @Published private(set) var configSaveState: ConfigSaveState = .saved
    private var pendingConfigSaves = Set<ConfigSaveSource>()
    private var configSaveErrors: [ConfigSaveSource: String] = [:]

    /// Set by AppDelegate to push values into the running TouchHandler.
    var onApply: ((TuneSettings) -> Void)?

    init(initial: TuneSettings) {
        self.tune = initial
    }

    func resetToDefaults() {
        tune = .default
    }

    func noteConfigSavePending(from source: ConfigSaveSource) {
        pendingConfigSaves.insert(source)
        configSaveErrors.removeValue(forKey: source)
        refreshConfigSaveState()
    }

    func noteConfigSaveSucceeded(from source: ConfigSaveSource) {
        pendingConfigSaves.remove(source)
        // Every GUI save writes a complete validated Config, so one successful write also proves a
        // previous error from the other tab is no longer current.
        configSaveErrors.removeAll()
        refreshConfigSaveState()
    }

    func noteConfigSaveFailed(_ error: Error, from source: ConfigSaveSource) {
        pendingConfigSaves.remove(source)
        configSaveErrors[source] = error.localizedDescription
        refreshConfigSaveState()
    }

    private func refreshConfigSaveState() {
        if let error = configSaveErrors.values.first {
            configSaveState = .failed(error)
        } else if !pendingConfigSaves.isEmpty {
            configSaveState = .saving
        } else {
            configSaveState = .saved
        }
    }
}

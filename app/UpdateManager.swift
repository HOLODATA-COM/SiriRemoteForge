//
//  UpdateManager.swift
//  HyperVibe
//
//  One long-lived Sparkle controller for signed background updates. Preferences are mirrored from
//  config.jsonc instead of being split between JSON and Sparkle's UserDefaults-backed controls.
//

import AppKit
import Sparkle

@MainActor
final class UpdateManager: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: self
    )
    private var hasStarted = false
    private let isLocalBuild = (Bundle.main.object(
        forInfoDictionaryKey: "HyperVibeReleaseVersion"
    ) as? String)?.contains("-local.") == true

    /// A scheduled check found an update but intentionally did not steal focus. The app delegate
    /// mirrors this into the menu-bar badge and Settings. Selecting either surface calls
    /// checkForUpdates(), which brings Sparkle's existing update session into focus.
    var onUpdateAvailable: ((String) -> Void)?
    var onUpdateCleared: (() -> Void)?

    func start(automaticChecks: Bool, automaticDownloads: Bool) {
        apply(automaticChecks: automaticChecks, automaticDownloads: automaticDownloads)
        guard !hasStarted else { return }
        controller.startUpdater()
        hasStarted = true
    }

    func apply(automaticChecks: Bool, automaticDownloads: Bool) {
        // Set checks first: Sparkle intentionally reports automatic downloads as unavailable while
        // checks are disabled. Re-enabling checks therefore restores the separately saved download
        // choice in the same call.
        let checksEnabled = automaticChecks && !isLocalBuild
        controller.updater.automaticallyChecksForUpdates = checksEnabled
        controller.updater.automaticallyDownloadsUpdates = checksEnabled && automaticDownloads
    }

    func checkForUpdates() {
        guard hasStarted else { return }
        controller.checkForUpdates(nil)
    }

    /// Stable builds see stable items only. Prerelease builds keep following the signed beta
    /// channel, while also remaining eligible for a newer stable build.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let release = Bundle.main.object(forInfoDictionaryKey: "HyperVibeReleaseVersion")
            as? String ?? ""
        return release.contains("-") ? ["beta"] : []
    }

    // MARK: - Gentle scheduled reminders

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // When Sparkle knows it is appropriate to take focus, retain its polished standard alert.
        // Otherwise keep the background app quiet and expose a persistent, user-driven affordance.
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !state.userInitiated, !handleShowingUpdate else { return }
        let version = update.displayVersionString
        Task { @MainActor [weak self] in self?.onUpdateAvailable?(version) }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor [weak self] in self?.onUpdateCleared?() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor [weak self] in self?.onUpdateCleared?() }
    }
}

//
//  SystemControlState.swift
//  HyperVibe
//
//  Read-only state for controls whose icon should describe the system after an action, not the
//  direction of the button that was pressed. Volume uses CoreAudio's current default output
//  device; brightness reuses the display fallback already proven by Brightness.swift.
//

import AudioToolbox
import CoreAudio
import Foundation

enum ControlVisualKind: Equatable {
    case volume
    case brightness
}

struct ControlVisualState: Equatable {
    let kind: ControlVisualKind
    let value: Double
    let isMuted: Bool

    init(kind: ControlVisualKind, value: Double, isMuted: Bool = false) {
        self.kind = kind
        // Quantising to one percent avoids rebuilding an identical variable symbol for harmless
        // floating-point noise while retaining much finer resolution than hardware key notches.
        let clamped = min(1, max(0, value.isFinite ? value : 0))
        self.value = (clamped * 100).rounded() / 100
        self.isMuted = isMuted
    }
}

enum SystemControlState {

    private static let sampleQueue = DispatchQueue(
        label: "com.hypervibe.system-control-state", qos: .userInitiated
    )
    private static let cacheLock = NSLock()
    private static var cachedVolume: ControlVisualState?
    private static var cachedBrightness: ControlVisualState?

    /// Main-thread-safe snapshot: this performs no HAL or display I/O. UI callers get the most
    /// recent background sample (or a deterministic fallback) in constant time.
    static func snapshot(for action: Action) -> ControlVisualState? {
        guard let request = sampleRequest(for: action) else { return nil }
        return cached(request.kind) ?? request.fallback
    }

    /// Prime both hardware-backed values before any widget/Layout render. The calls are serialized
    /// away from the main thread so neither CoreAudio nor DisplayServices can delay input handling.
    static func prewarm() {
        refresh(for: .media(key: "volup")) { _ in }
        refresh(for: .brightnessStep(direction: 1)) { _ in }
    }

    /// Asynchronously obtain a fresh state and publish it on the main queue. StatusWidget uses this
    /// after the real key edge; Layout never needs a live hardware query merely to draw an icon.
    static func refresh(for action: Action,
                        completion: @escaping (ControlVisualState?) -> Void) {
        guard let request = sampleRequest(for: action) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        sampleQueue.async {
            let measured: ControlVisualState?
            switch request.kind {
            case .volume:
                measured = outputVolumeState()
            case .brightness:
                measured = Brightness.currentValue().map {
                    ControlVisualState(kind: .brightness, value: Double($0))
                }
            }
            let resolved = measured ?? cached(request.kind) ?? request.fallback
            if let measured { store(measured) }
            DispatchQueue.main.async { completion(resolved) }
        }
    }

    /// True only for the system-output mute toggle. App-specific scripts such as
    /// `tell application "Music" to set mute ...` intentionally stay out of this path because
    /// CoreAudio cannot truthfully describe that application's private playback state.
    static func isSystemOutputMuteToggle(_ action: Action) -> Bool {
        switch action {
        case .media(let key):
            return key.lowercased() == "mute"
        case .applescript(let script):
            let lower = script.lowercased()
            return lower.contains("output muted")
                && (lower.contains("set volume") || lower.contains("volume settings"))
        default:
            return false
        }
    }

    /// `Controller` announces an action immediately before executing it. A mute press therefore
    /// needs to present the post-toggle state, not flash the measured pre-toggle state and then
    /// animate again after CoreAudio catches up. The later sample remains a confirmation/correction.
    static func predictedMuteResult(for action: Action) -> ControlVisualState? {
        guard isSystemOutputMuteToggle(action), let current = snapshot(for: action) else { return nil }
        return predictedMuteResult(from: current)
    }

    static func predictedMuteResult(from current: ControlVisualState) -> ControlVisualState? {
        guard current.kind == .volume else { return nil }
        return ControlVisualState(kind: .volume, value: current.value, isMuted: !current.isMuted)
    }

    private static func sampleRequest(for action: Action)
        -> (kind: ControlVisualKind, fallback: ControlVisualState)? {
        switch action {
        case .media(let key) where ["volup", "volumeup", "voldown", "volumedown", "mute"]
            .contains(key.lowercased()):
            return (.volume, ControlVisualState(kind: .volume, value: 0.5))
        case .applescript where isSystemOutputMuteToggle(action):
            return (.volume, ControlVisualState(kind: .volume, value: 0.5))
        case .brightness(let requested):
            return (.brightness, ControlVisualState(kind: .brightness, value: requested))
        case .brightnessStep:
            return (.brightness, ControlVisualState(kind: .brightness, value: 0.5))
        default:
            return nil
        }
    }

    private static func cached(_ kind: ControlVisualKind) -> ControlVisualState? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        switch kind {
        case .volume: return cachedVolume
        case .brightness: return cachedBrightness
        }
    }

    private static func store(_ state: ControlVisualState) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        switch state.kind {
        case .volume: cachedVolume = state
        case .brightness: cachedBrightness = state
        }
    }

    // MARK: - CoreAudio output state

    private static func outputVolumeState() -> ControlVisualState? {
        guard let device = defaultOutputDevice() else { return nil }
        let muted = readUInt32(
            device: device,
            selector: kAudioDevicePropertyMute,
            elements: [kAudioObjectPropertyElementMain, 1, 2]
        ).map { $0 != 0 } ?? false

        // Virtual main volume is the user-facing scalar used by the menu bar. Some devices expose
        // only the older master/channel property, so retain those as ordered fallbacks.
        let virtualMain = readFloat(
            device: device,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            elements: [kAudioObjectPropertyElementMain]
        )
        let volume = virtualMain ?? averagedChannelVolume(device: device)
        guard let volume else { return nil }
        // Muting does not destroy the stored output scalar. Preserve it so the predicted Unmute
        // face has the correct authored wave level before CoreAudio confirms the edge.
        return ControlVisualState(kind: .volume, value: Double(volume), isMuted: muted)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func averagedChannelVolume(device: AudioDeviceID) -> Float32? {
        if let master = readFloat(
            device: device,
            selector: kAudioDevicePropertyVolumeScalar,
            elements: [kAudioObjectPropertyElementMain]
        ) {
            return master
        }
        let channels = [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)]
            .compactMap {
                readFloat(device: device, selector: kAudioDevicePropertyVolumeScalar,
                          elements: [$0])
            }
        guard !channels.isEmpty else { return nil }
        return channels.reduce(0, +) / Float32(channels.count)
    }

    private static func readFloat(
        device: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        elements: [AudioObjectPropertyElement]
    ) -> Float32? {
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
                return min(1, max(0, value))
            }
        }
        return nil
    }

    private static func readUInt32(
        device: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        elements: [AudioObjectPropertyElement]
    ) -> UInt32? {
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        return nil
    }
}

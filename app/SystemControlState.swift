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

    static func snapshot(for action: Action) -> ControlVisualState? {
        switch action {
        case .media(let key):
            switch key.lowercased() {
            case "volup", "volumeup", "voldown", "volumedown", "mute":
                return outputVolumeState()
                    ?? ControlVisualState(kind: .volume, value: 0.5)
            default:
                return nil
            }
        case .applescript where isSystemOutputMuteToggle(action):
            // The shipped configuration owns Mute so it can coexist with double-click bindings.
            // It therefore toggles the same system state through AppleScript instead of posting a
            // media key. Treat both implementations as one CoreAudio-backed visual control.
            return outputVolumeState()
                ?? ControlVisualState(kind: .volume, value: 0.5)
        case .brightness(let requested):
            return ControlVisualState(
                kind: .brightness,
                value: Brightness.currentValue().map(Double.init) ?? requested
            )
        case .brightnessStep:
            return ControlVisualState(
                kind: .brightness,
                value: Brightness.currentValue().map(Double.init) ?? 0.5
            )
        default:
            return nil
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
        guard isSystemOutputMuteToggle(action), let current = outputVolumeState() else { return nil }
        return predictedMuteResult(from: current)
    }

    static func predictedMuteResult(from current: ControlVisualState) -> ControlVisualState? {
        guard current.kind == .volume else { return nil }
        return ControlVisualState(kind: .volume, value: current.value, isMuted: !current.isMuted)
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

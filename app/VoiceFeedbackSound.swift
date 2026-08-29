//
//  VoiceFeedbackSound.swift
//  HyperVibe
//
//  Low-latency, preloaded Voice edge cues. The paired Sci-fi Toggle on/off assets come from UI SFX
//  and are bundled under CC0-1.0; see Resources/Sounds/UI-SFX-LICENSE.txt.
//

import AVFoundation
import Foundation

final class VoiceFeedbackSound {
    /// The rendered assets include a short encoded/reverb tail (about 0.34–0.37 s total). Capture and the live
    /// meter exclude this bounded interval so the laptop microphone cannot turn HyperVibe's own
    /// cue into the first dictated phoneme; the already-prewarmed cloud session remains untouched.
    static let acousticExclusionDuration: TimeInterval = 0.30

    enum Cue: Hashable, CaseIterable {
        case began
        case ended

        fileprivate var resourceName: String {
            switch self {
            case .began: return "VoiceToggleOn"
            case .ended: return "VoiceToggleOff"
            }
        }
    }

    private let playbackQueue = DispatchQueue(
        label: "com.hypervibe.voice-feedback", qos: .userInteractive
    )
    private var players: [Cue: AVAudioPlayer] = [:]

    init(bundle: Bundle = .main) {
        // Resolving, decoding and preparing MP3 data can touch CoreAudio. Do all three once, away
        // from both the main thread and the physical side-button edge.
        playbackQueue.async { [weak self] in
            guard let self else { return }
            for cue in Cue.allCases {
                guard let data = Self.bundledAudioData(for: cue, bundle: bundle),
                      let player = try? AVAudioPlayer(data: data) else {
                    NSLog("[siriRemote] Voice feedback asset missing or invalid: \(cue.resourceName).mp3")
                    continue
                }
                player.numberOfLoops = 0
                player.volume = 0.55
                player.prepareToPlay()
                self.players[cue] = player
            }
        }
    }

    /// Non-blocking and edge-safe. Rewinding the dedicated player prevents a duplicated HID edge
    /// from stacking the same cue; RemoteInputHandler already de-duplicates physical edges, while
    /// this keeps the feedback layer defensive on its own.
    func play(_ cue: Cue, volume: Double) {
        let gain = Float(min(1, max(0, volume.isFinite ? volume : 0.55)))
        playbackQueue.async { [weak self] in
            guard let player = self?.players[cue] else { return }
            if player.isPlaying { player.stop() }
            player.currentTime = 0
            player.volume = gain
            player.play()
        }
    }

    /// Internal test seams: the native regression suite runs from the packaged candidate, so these
    /// checks prove the real signed App contains two independently decodable audio resources.
    static func bundledAudioData(for cue: Cue, bundle: Bundle = .main) -> Data? {
        guard let url = bundle.url(
            forResource: cue.resourceName, withExtension: "mp3", subdirectory: "Sounds"
        ) else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    static func bundledAudioDuration(for cue: Cue, bundle: Bundle = .main) -> TimeInterval? {
        guard let data = bundledAudioData(for: cue, bundle: bundle),
              let player = try? AVAudioPlayer(data: data) else { return nil }
        return player.duration
    }
}

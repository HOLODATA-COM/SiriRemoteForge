//
//  BuiltinMicFeeder.swift
//  HyperVibe
//
//  Phase 2b of the virtual-mic fallback: feeds the Mac's BUILT-IN microphone into the
//  "/SiriRemoteMicBuiltin" shared-memory ring (BuiltinMicRingWriter.c) that the
//  SiriRemoteMic HAL plug-in serves whenever the remote's voice ring is stale. Net
//  effect: an app that selected "Siri Remote Mic" always hears something sensible —
//  the room via the built-in mic normally, the remote's mic while Siri is held.
//
//  Three rules this file exists to enforce:
//
//  1. NEVER touch the "default input" device. If the user makes "Siri Remote Mic"
//     their default mic (the whole point of the feature), capturing the default would
//     capture our OWN virtual device — which is playing the very ring we are writing —
//     and howl. Capture uses a raw AUHAL unit bound to the CoreAudio device with UID
//     "BuiltInMicrophoneDevice" (fallback: transport Built-in with input streams)
//     BEFORE the unit is ever initialized, and refuses to run unbound. Deliberately
//     not AVAudioEngine: its inputNode starts life on the default input and its setup
//     enumerates the whole device graph — third-party aggregate devices included.
//
//  2. The mic is only hot while some app actually has the virtual device open OR while
//     the user is physically holding the configured Voice button and its live waveform
//     needs a level. The plug-in broadcasts the Darwin notification
//     au.holodata.SiriRemoteMic.consumers with state = number of clients running IO (the
//     same demand signal srm_captured uses). Both demands stop immediately on their
//     release edge; an idle Mac never has its microphone open because of this feature.
//
//  3. NOTHING here runs on the main thread. HAL property calls are synchronous mach
//     IPC into coreaudiod and can stall for minutes when it is busy — observed live,
//     with the whole app (and the remote) frozen behind one such call. All capture
//     work is confined to a private serial queue; the main thread never waits on it.
//

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// One display-cadence acoustic snapshot. `level` is the existing perceptual envelope; the
/// remaining values enrich only the compact Voice visual and never feed transcription/audio IO.
struct VoiceMeterSample {
    let level: Float
    let pitchHz: Float
    let pitchConfidence: Float
    let brightness: Float

    static let silence = VoiceMeterSample(level: 0, pitchHz: 0,
                                          pitchConfidence: 0, brightness: 0)
}

final class BuiltinMicFeeder {

    /// The plug-in's demand signal (see SiriRemoteMic.c, SRM_PublishConsumerCount).
    private static let consumersNotification = "au.holodata.SiriRemoteMic.consumers"
    /// CoreAudio's fixed UID for the internal microphone on modern Macs.
    private static let builtInMicUID = "BuiltInMicrophoneDevice"

    /// Rule 3: every capture-side call (HAL properties, AU lifecycle, demand state)
    /// happens on this queue. If coreaudiod stalls, this queue stalls — nothing else.
    private let queue = DispatchQueue(label: "com.hypervibe.builtin-mic-feeder")

    private var notifyToken: Int32?
    private var demandActive = false
    private var meteringActive = false
    private var capturing = false
    private var context: CaptureContext?      // live AUHAL + RT buffers (built once, reused)
    private var deviceListeners: [(AudioDeviceID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var meterTimer: DispatchSourceTimer?
    private var meterLevelHandler: ((VoiceMeterSample) -> Void)?
    private var smoothedMeterLevel: Float = 0
    private var builtinMeterWriteIndex: UInt64?
    private var remoteMeterWriteIndex: UInt64?
    private var remoteMeterLastAdvanceNanoseconds: UInt64 = 0

    // The waveform is a status signal, not a studio level meter. Keep room noise visually quiet,
    // but retain enough lower-range travel for an ordinary speaking voice. The old 0.72 exponent
    // expanded noise; the first corrective 1.60 curve over-compressed quieter speech.
    private static let meterFloorDBFS: Float = -52
    private static let meterCeilingDBFS: Float = -14
    private static let meterCurve: Float = 1.15
    private static let meterVisualGate: Float = 0.012

    // MARK: - Lifecycle (called from the main thread by AppDelegate)

    func start() {
        var token: Int32 = 0
        let status = notify_register_dispatch(Self.consumersNotification, &token,
                                              queue) { [weak self] _ in
            self?.handleDemand()
        }
        guard status == 0 else {   // NOTIFY_STATUS_OK
            print("🎙️ notify_register_dispatch failed (\(status)) — built-in-mic fallback disabled")
            return
        }
        notifyToken = token
        queue.async { [weak self] in
            guard let self = self else { return }
            // Create the ring NOW, not at first demand. The plug-in maps rings only at a
            // session's first StartIO and never re-checks mid-session — and because the
            // virtual device can be the DEFAULT input, some always-on app may start a
            // session that then runs for days. A ring born mid-session would never be
            // seen. Existing early costs nothing: producerActive=0 means silence per the
            // contract, and no mic is touched until demand arrives.
            if srm_builtin_ring_open() != 0 {
                print("🎙️ ring open failed: \(String(cString: srm_builtin_ring_last_error()))")
            }
            // Ground truth at startup: an app may already have the device open (the
            // notification only fires on edges, and the last edge predates this process).
            self.handleDemand()
        }
    }

    /// Idempotent — cleanup() runs on both termination paths. Deliberately does NOT
    /// wait on the feeder queue: if it is wedged in a stalled HAL call, quitting must
    /// still proceed. producerActive is a plain C atomic, safe to clear from here; the
    /// mapped region is never munmapped mid-flight (process exit reclaims it), so the
    /// render thread can never touch freed memory.
    func stop() {
        if let token = notifyToken {
            notify_cancel(token)
            notifyToken = nil
        }
        srm_builtin_ring_set_active(0)
        srm_builtin_meter_store_power(0)
        queue.async { [weak self] in
            guard let self = self else { return }
            self.meteringActive = false
            self.stopMeterTimer(publishSilence: true)
            self.stopCapture()
        }   // best-effort graceful stop
    }

    /// Receives a perceptually-normalised 0...1 level at ~30 Hz while Voice metering is
    /// active. Delivery happens on the feeder queue; UI clients must hop to the main thread.
    func setMeterLevelHandler(_ handler: @escaping (VoiceMeterSample) -> Void) {
        queue.async { [weak self] in self?.meterLevelHandler = handler }
    }

    /// Adds/removes the compact Voice widget's capture demand. This deliberately reuses the
    /// already pinned built-in-mic AUHAL instead of opening the default input through a second
    /// AVAudioEngine, which could accidentally select our own virtual microphone.
    func setVoiceMetering(_ active: Bool) {
        queue.async { [weak self] in
            guard let self = self, active != self.meteringActive else { return }
            self.meteringActive = active
            if active {
                srm_builtin_meter_store_power(0)
                self.smoothedMeterLevel = 0
                self.builtinMeterWriteIndex = nil
                self.remoteMeterWriteIndex = nil
                self.remoteMeterLastAdvanceNanoseconds = 0
                self.startMeterTimer()
            } else {
                self.stopMeterTimer(publishSilence: true)
            }
            self.reconcileCaptureDemand()
        }
    }

    // MARK: - Demand gating (feeder queue)

    private func handleDemand() {
        var state: UInt64 = 0
        if let token = notifyToken { notify_get_state(token, &state) }
        demandActive = state >= 1
        // No stop debounce (srm_captured keeps one for its heavy pipeline): stopping the
        // AU is cheap, the plug-in crossfades over blips, and stopping immediately is
        // the privacy-maximal reading of "only hot while in use".
        reconcileCaptureDemand()
    }

    private var captureWanted: Bool { demandActive || meteringActive }

    private func reconcileCaptureDemand() {
        captureWanted ? startCapture() : stopCapture()
    }

    // MARK: - Voice waveform metering (feeder queue)

    private func startMeterTimer() {
        guard meterTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33),
                       leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.publishMeterLevel() }
        meterTimer = timer
        timer.resume()
    }

    private func stopMeterTimer(publishSilence: Bool) {
        meterTimer?.cancel()
        meterTimer = nil
        smoothedMeterLevel = 0
        srm_builtin_meter_store_power(0)
        builtinMeterWriteIndex = nil
        if publishSilence { meterLevelHandler?(.silence) }
    }

    private func publishMeterLevel() {
        guard meteringActive else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        var power = max(0, srm_builtin_meter_load_power())
        var pitchHz: Float = 0
        var pitchConfidence: Float = 0
        var brightness: Float = 0

        // The built-in PCM already lands in its 48 kHz fallback ring. Analyse that published
        // window here on the feeder queue, never in the real-time render callback. The first
        // index only establishes freshness so stale samples from a prior capture cannot colour
        // the first frame of a new Voice hold.
        var builtinFeatures = SRMMeterFeatures()
        var builtinWriteIndex: UInt64 = 0
        var builtinProducerActive: UInt32 = 0
        if srm_builtin_meter_snapshot(&builtinFeatures, &builtinWriteIndex,
                                      &builtinProducerActive) == 0,
           builtinProducerActive != 0 {
            if let previous = builtinMeterWriteIndex, builtinWriteIndex != previous {
                pitchHz = max(0, builtinFeatures.pitchHz)
                pitchConfidence = min(1, max(0, builtinFeatures.pitchConfidence))
                brightness = min(1, max(0, builtinFeatures.brightness))
            }
            builtinMeterWriteIndex = builtinWriteIndex
        } else {
            builtinMeterWriteIndex = nil
        }

        // Match the virtual device's source priority: decoded Siri Remote voice owns the
        // waveform while its ring is actively advancing; otherwise use the built-in fallback.
        // The first observation only establishes a baseline — it does not make old backlog look
        // fresh. One subsequent writeIndex change proves that live remote audio is arriving.
        var remoteFeatures = SRMMeterFeatures()
        var remoteWriteIndex: UInt64 = 0
        var remoteProducerActive: UInt32 = 0
        if srm_remote_meter_snapshot(&remoteFeatures, &remoteWriteIndex,
                                     &remoteProducerActive) == 0,
           remoteProducerActive != 0 {
            if let previous = remoteMeterWriteIndex, remoteWriteIndex != previous {
                remoteMeterLastAdvanceNanoseconds = now
            }
            remoteMeterWriteIndex = remoteWriteIndex
            if remoteMeterLastAdvanceNanoseconds != 0,
               now >= remoteMeterLastAdvanceNanoseconds,
               now - remoteMeterLastAdvanceNanoseconds <= 150_000_000 {
                power = max(0, remoteFeatures.meanSquarePower)
                pitchHz = max(0, remoteFeatures.pitchHz)
                pitchConfidence = min(1, max(0, remoteFeatures.pitchConfidence))
                brightness = min(1, max(0, remoteFeatures.brightness))
            }
        } else {
            remoteMeterWriteIndex = nil
            remoteMeterLastAdvanceNanoseconds = 0
        }

        let target = Self.displayMeterLevel(meanSquarePower: power)

        // Reject one-frame clicks while following normal speech promptly enough to feel live. The
        // gentler release preserves word shape without making every syllable pump the whole card.
        let response: Float = target > smoothedMeterLevel ? 0.40 : 0.13
        smoothedMeterLevel += (target - smoothedMeterLevel) * response
        meterLevelHandler?(VoiceMeterSample(
            level: min(1, max(0, smoothedMeterLevel)),
            pitchHz: pitchHz.isFinite ? pitchHz : 0,
            pitchConfidence: pitchConfidence.isFinite ? pitchConfidence : 0,
            brightness: brightness.isFinite ? brightness : 0
        ))
    }

    /// Convert mean-square power to the compact waveform's perceptual 0...1 range. This affects
    /// display only; neither the shared audio rings nor the samples served by the virtual mic are
    /// changed. `meterVisualGate` removes the tiny residual after the curved noise floor, then
    /// renormalises the remaining travel so genuinely loud speech can still reach full height.
    private static func displayMeterLevel(meanSquarePower power: Float) -> Float {
        guard power.isFinite, power > 0 else { return 0 }
        let decibels = 10 * log10(max(power, 0.000_000_000_001))
        let span = meterCeilingDBFS - meterFloorDBFS
        let linear = min(1, max(0, (decibels - meterFloorDBFS) / span))
        let curved = pow(linear, meterCurve)
        return min(1, max(0, (curved - meterVisualGate) / (1 - meterVisualGate)))
    }

    // MARK: - Capture (feeder queue)

    private func startCapture() {
        guard !capturing else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginCapture()
        case .notDetermined:
            // First use fires the TCC prompt (NSMicrophoneUsageDescription is in the
            // bundle's Info.plist). The answer can arrive minutes later — an app may
            // have closed the device meanwhile, so re-check demand before starting.
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                self?.queue.async {
                    guard let self = self else { return }
                    guard granted else {
                        print("🎙️ mic permission denied — built-in-mic fallback stays silent")
                        return
                    }
                    if self.captureWanted && !self.capturing { self.beginCapture() }
                }
            }
        default:
            // Denied/restricted: no-op by design — the virtual device just serves
            // silence when the remote isn't feeding. Never crash over a permission.
            print("🎙️ mic permission denied — built-in-mic fallback silent (System Settings → Privacy & Security → Microphone)")
        }
    }

    private func beginCapture() {
        guard !capturing else { return }
        // Build the AU once and reuse it across demand cycles: setup is where HAL
        // stalls and device churn live, start/stop is cheap and safe.
        if context == nil {
            context = buildContext()
        }
        guard var live = context else { return }
        guard srm_builtin_ring_open() == 0 else {
            print("🎙️ ring open failed: \(String(cString: srm_builtin_ring_last_error()))")
            return
        }
        var status = AudioOutputUnitStart(live.unit)
        if status != noErr {
            // One rebuild attempt: the device may have changed shape while we were idle.
            teardownContext()
            context = buildContext()
            guard let rebuilt = context else { return }
            live = rebuilt
            status = AudioOutputUnitStart(rebuilt.unit)
            guard status == noErr else {
                print("🎙️ AudioOutputUnitStart failed (\(status)) — built-in-mic fallback unavailable")
                return
            }
        }
        srm_builtin_ring_set_active(1)
        capturing = true
        print("🎙️ built-in mic → /SiriRemoteMicBuiltin (\(live.deviceName), uid=\(live.deviceUID), \(Int(live.deviceRate)) Hz)")
    }

    private func stopCapture() {
        guard capturing else { return }
        capturing = false
        srm_builtin_ring_set_active(0)   // plug-in crossfades to remote/silence
        if let context = context {
            AudioOutputUnitStop(context.unit)   // blocks until the in-flight IO cycle ends
        }
        // The AU stays built (stopped = mic not recording, no TCC indicator) and the shm
        // stays mapped: recreating either per demand cycle is pointless churn, and a
        // recreated ring would reset writeIndex under an attached reader.
        print("🎙️ built-in mic capture stopped (device idle)")
    }

    // MARK: - AUHAL setup (feeder queue)

    /// Everything the real-time render proc touches, with its lifetime pinned so the
    /// RT thread can never see freed memory: torn down only after AudioOutputUnitStop +
    /// AudioUnitUninitialize have drained the IO thread. (fileprivate: the C-convention
    /// render proc lives at file scope and needs the type.)
    fileprivate final class CaptureContext {
        var unit: AudioUnit
        let deviceID: AudioDeviceID
        let deviceUID: String
        let deviceName: String
        let deviceRate: Double
        let resampler: LinearResampler?               // nil when the device runs 48 kHz
        let storage: UnsafeMutablePointer<Float>      // AudioUnitRender target, mono
        let storageCapacity: Int
        var bufferList: AudioBufferList

        init(unit: AudioUnit, deviceID: AudioDeviceID, deviceUID: String, deviceName: String,
             deviceRate: Double, storageCapacity: Int) {
            self.unit = unit
            self.deviceID = deviceID
            self.deviceUID = deviceUID
            self.deviceName = deviceName
            self.deviceRate = deviceRate
            self.resampler = deviceRate == 48000 ? nil : LinearResampler(inputRate: deviceRate)
            self.storageCapacity = storageCapacity
            self.storage = .allocate(capacity: storageCapacity)
            self.bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1,
                                      mDataByteSize: UInt32(storageCapacity * MemoryLayout<Float>.size),
                                      mData: nil))
            self.bufferList.mBuffers.mData = UnsafeMutableRawPointer(storage)
        }
        deinit { storage.deallocate() }
    }

    private func buildContext() -> CaptureContext? {
        guard let mic = Self.resolveBuiltInMic() else {
            print("🎙️ no built-in microphone found — built-in-mic fallback unavailable")
            return nil
        }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var maybeUnit: AudioUnit?
        guard AudioComponentInstanceNew(component, &maybeUnit) == noErr,
              let unit = maybeUnit else { return nil }

        func fail(_ what: String, _ status: OSStatus) -> CaptureContext? {
            print("🎙️ AUHAL setup failed at \(what) (\(status)) — built-in-mic fallback unavailable")
            AudioComponentInstanceDispose(unit)
            return nil
        }
        // All the scalar AU properties below are UInt32 (AudioDeviceID included).
        func setProperty(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
                         _ element: AudioUnitElement, _ value: UInt32) -> OSStatus {
            var value = value
            return AudioUnitSetProperty(unit, property, scope, element, &value,
                                        UInt32(MemoryLayout<UInt32>.size))
        }

        // Input-only AUHAL: input (element 1) on, output (element 0) off.
        var status = setProperty(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1))
        if status != noErr { return fail("enable input", status) }
        status = setProperty(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0))
        if status != noErr { return fail("disable output", status) }

        // Rule 1: bind the built-in mic BEFORE initializing. The unit is never valid
        // on any other device, so there is no window where the default input is read.
        status = setProperty(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, mic.id)
        if status != noErr { return fail("pin device", status) }

        // ~10 ms of device IO per render — the ring contract's publish cadence, well
        // inside the plug-in's 40 ms prime buffer. Best effort: the common 512-frame
        // default would also be fine.
        _ = setProperty(kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, UInt32(480))

        // AUHAL converts channel count but NOT sample rate on the input side, so the
        // client format mirrors the device rate; LinearResampler bridges to the ring's
        // fixed 48 kHz in the rare case the mic isn't already there.
        let deviceRate = Self.f64Property(mic.id, kAudioDevicePropertyNominalSampleRate) ?? 48000
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: deviceRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output, 1, &clientFormat,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        if status != noErr { return fail("client format", status) }

        let context = CaptureContext(unit: unit, deviceID: mic.id, deviceUID: mic.uid,
                                     deviceName: mic.name, deviceRate: deviceRate,
                                     storageCapacity: 16384)

        var callback = AURenderCallbackStruct(
            inputProc: builtinMicRenderProc,
            inputProcRefCon: Unmanaged.passUnretained(context).toOpaque())
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                      kAudioUnitScope_Global, 0, &callback,
                                      UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        if status != noErr { return fail("input callback", status) }

        status = AudioUnitInitialize(unit)
        if status != noErr { return fail("initialize", status) }

        installDeviceListeners(for: mic.id)
        return context
    }

    private func teardownContext() {
        removeDeviceListeners()
        if let context = context {
            AudioOutputUnitStop(context.unit)
            AudioUnitUninitialize(context.unit)
            AudioComponentInstanceDispose(context.unit)
        }
        context = nil   // frees the RT buffers only after the IO thread is drained above
    }

    /// If the pinned device dies or changes sample rate, rebuild from scratch (after a
    /// short settle) — the AU bound to a dead/reshaped device just stops rendering.
    private func installDeviceListeners(for device: AudioDeviceID) {
        for selector in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate] {
            let address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self = self, self.context != nil else { return }
                print("🎙️ built-in mic device changed — rebuilding capture")
                self.stopCapture()
                self.teardownContext()
                self.queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self = self else { return }
                    if self.captureWanted { self.startCapture() }
                }
            }
            var mutableAddress = address
            if AudioObjectAddPropertyListenerBlock(device, &mutableAddress, queue, block) == noErr {
                deviceListeners.append((device, address, block))
            }
        }
    }

    private func removeDeviceListeners() {
        for (device, address, block) in deviceListeners {
            var mutableAddress = address
            AudioObjectRemovePropertyListenerBlock(device, &mutableAddress, queue, block)
        }
        deviceListeners.removeAll()
    }

    // MARK: - Built-in device resolution (never the default input)

    /// Finds the built-in microphone explicitly: prefer the well-known UID, fall back to
    /// transport type Built-in with input streams. Deliberately never consults
    /// kAudioHardwarePropertyDefaultInputDevice — see rule 1 in the header. (The
    /// virtual device can't be picked by mistake either: its UID differs and it
    /// advertises transport USB.)
    private static func resolveBuiltInMic() -> (id: AudioDeviceID, uid: String, name: String)? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &devices) == noErr else {
            return nil
        }

        var transportMatch: (id: AudioDeviceID, uid: String, name: String)?
        for device in devices where hasInputStreams(device) {
            let uid = stringProperty(device, kAudioDevicePropertyDeviceUID) ?? ""
            let name = stringProperty(device, kAudioObjectPropertyName) ?? "?"
            if uid == builtInMicUID {
                return (device, uid, name)
            }
            if transportMatch == nil,
               u32Property(device, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn {
                transportMatch = (device, uid, name)
            }
        }
        return transportMatch
    }

    private static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func u32Property(_ device: AudioDeviceID,
                                    _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func f64Property(_ device: AudioDeviceID,
                                    _ selector: AudioObjectPropertySelector) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func stringProperty(_ device: AudioDeviceID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let cfString = value?.takeRetainedValue() else { return nil }
        return cfString as String
    }
}

// MARK: - Real-time render proc

/// Runs on the AU's real-time IO thread each ~10 ms cycle: pull the mic frames, write
/// them to the shm ring. Atomics + memcpy only — no locks, no allocation, no logging,
/// no Swift objects beyond the pre-built context.
private func builtinMicRenderProc(inRefCon: UnsafeMutableRawPointer,
                                  ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                  inTimeStamp: UnsafePointer<AudioTimeStamp>,
                                  inBusNumber: UInt32,
                                  inNumberFrames: UInt32,
                                  ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let context = Unmanaged<BuiltinMicFeeder.CaptureContext>.fromOpaque(inRefCon).takeUnretainedValue()
    let frames = Int(inNumberFrames)
    guard frames > 0, frames <= context.storageCapacity else { return noErr }

    context.bufferList.mBuffers.mDataByteSize = inNumberFrames * UInt32(MemoryLayout<Float>.size)
    context.bufferList.mBuffers.mData = UnsafeMutableRawPointer(context.storage)
    let status = AudioUnitRender(context.unit, ioActionFlags, inTimeStamp, 1,
                                 inNumberFrames, &context.bufferList)
    guard status == noErr else { return status }

    var meanSquarePower: Float = 0
    for frame in 0..<frames {
        let sample = context.storage[frame]
        meanSquarePower += sample * sample
    }
    meanSquarePower /= Float(frames)
    srm_builtin_meter_store_power(meanSquarePower.isFinite ? meanSquarePower : 0)

    if let resampler = context.resampler {
        resampler.process(context.storage, frames) { resampled, count in
            _ = srm_builtin_ring_write(resampled, count)
        }
    } else {
        _ = srm_builtin_ring_write(context.storage, frames)
    }
    return noErr
}

// MARK: - Real-time helpers

/// Allocation-free linear resampler to 48 kHz for the rare Mac whose built-in mic isn't
/// already running at 48 kHz. Deliberately simple: voice-grade quality, zero allocation
/// and zero locks after init, so it is safe on the real-time IO thread.
final class LinearResampler {
    private let step: Double              // input frames advanced per output frame
    private var position = 0.0            // fractional read position into the current chunk
    private var previous: Float = 0       // last sample of the previous chunk (continuity)
    private var hasPrevious = false
    private let out: UnsafeMutablePointer<Float>
    private let outCapacity: Int

    init(inputRate: Double) {
        step = inputRate / 48000.0
        outCapacity = Int(16384.0 / step) + 8
        out = .allocate(capacity: outCapacity)
    }
    deinit { out.deallocate() }

    /// Consumes one input chunk, delivers the resampled frames once. `position` rebases
    /// below zero across chunks so index -1 refers to the carried `previous` sample.
    func process(_ input: UnsafePointer<Float>, _ frames: Int,
                 _ deliver: (UnsafePointer<Float>, Int) -> Void) {
        guard frames > 0 else { return }
        var produced = 0
        while produced < outCapacity {
            let index = Int(position.rounded(.down))
            guard index + 1 < frames else { break }   // rest of this output needs the next chunk
            let fraction = Float(position - Double(index))
            let s0 = index >= 0 ? input[index] : (hasPrevious ? previous : input[0])
            let s1 = input[index + 1]
            out[produced] = s0 + (s1 - s0) * fraction
            produced += 1
            position += step
        }
        previous = input[frames - 1]
        hasPrevious = true
        position -= Double(frames)
        if produced > 0 { deliver(out, produced) }
    }
}

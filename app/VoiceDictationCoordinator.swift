//
//  VoiceDictationCoordinator.swift
//  HyperVibe
//
//  Latency-critical dictation state machine. Audio capture and the Realtime handshake begin on the
//  raw side-button press, hiding their startup under the existing 200 ms tap/hold discriminator.
//  A quick tap cancels both without ever showing Voice or inserting text.
//

import Combine
import Foundation
import QuartzCore

enum VoiceStreamingReconciliation {
    /// Only a strict suffix is safe after deltas have already reached somebody else's editor.
    static func missingSuffix(committed: String, inserted: String) -> String? {
        guard committed.hasPrefix(inserted) else { return nil }
        return String(committed.dropFirst(inserted.count))
    }
}

enum VoiceDictationPhase: String, Equatable {
    case idle
    case priming
    case listening
    case transcribing
    case polishing
    case rewriting
    case inserting
    case inserted
    case replaced
    case copied
    case error
}

/// Admission must distinguish a temporarily occupied native pipeline, a user-fixable
/// misconfiguration, and a disabled/unavailable route. Busy and misconfigured native Voice both
/// consume the promoted hold; only the latter presents an actionable error after the existing
/// accidental-touch threshold.
enum VoiceDictationAdmission: Equatable {
    case accepted
    case busy
    case misconfigured
    case unavailable
}

/// Streaming text is already visible at the captured caret, so a successful stream must not open
/// a second set of result cards after key-up. Final mode keeps the genuinely useful waiting states
/// and a terminal result, but does not expose a separate Inserting card for a normally millisecond-
/// scale delivery operation. Failures and clipboard fallback stay visible in both modes because
/// they require the user's attention.
enum VoiceDictationPresentationPolicy {
    static func releasePhase(
        for mode: Config.DictationOutputMode
    ) -> VoiceDictationPhase? {
        mode == .final ? .transcribing : nil
    }

    static func showsInsertionProgress(
        for _: Config.DictationOutputMode
    ) -> Bool {
        false
    }

    static func completionPhase(
        for mode: Config.DictationOutputMode,
        outcome: VoiceTextDeliveryOutcome
    ) -> VoiceDictationPhase? {
        switch outcome {
        case .inserted:
            return mode == .final ? .inserted : nil
        case .copied:
            return .copied
        case .focusChanged, .secureField, .unavailable:
            return .error
        }
    }
}

struct VoiceLatencyMetrics: Equatable {
    var audioSource: String?
    var audioDurationMilliseconds: Double?
    var pressToFirstAudioMilliseconds: Double?
    var pressToSessionReadyMilliseconds: Double?
    var pressToFirstDeltaMilliseconds: Double?
    var releaseToTranscriptMilliseconds: Double?
    var cleanupMilliseconds: Double?
    var insertionMilliseconds: Double?

    static let empty = VoiceLatencyMetrics()
}

final class VoiceRuntimeModel: ObservableObject {
    @Published fileprivate(set) var phase: VoiceDictationPhase = .idle
    @Published fileprivate(set) var livePreview = ""
    @Published fileprivate(set) var lastMetrics = VoiceLatencyMetrics.empty
    @Published fileprivate(set) var lastMessage = ""
    @Published fileprivate(set) var hasLastTranscript = false
}

/// Internal (rather than file-private) so the headless regression suite can exercise early-drain
/// latching and final-mode delta gating without opening a real WebSocket.
final class VoiceRealtimeEventRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var deltaHandler: ((String) async -> Void)?
    private var previewHandler: ((String) async -> Void)?
    private var drainedHandler: (() async -> Void)?
    private var forwardAllDeltas = true
    private var forwardedFirstDelta = false
    private var isDrained = false

    func attach(onDelta: @escaping (String) async -> Void,
                onPreview: @escaping (String) async -> Void,
                onDrained: @escaping () async -> Void,
                forwardAllDeltas: Bool) -> Bool {
        lock.lock()
        deltaHandler = onDelta
        previewHandler = onPreview
        drainedHandler = onDrained
        self.forwardAllDeltas = forwardAllDeltas
        forwardedFirstDelta = false
        let alreadyDrained = isDrained
        lock.unlock()
        return alreadyDrained
    }

    func delta(_ value: String) async {
        if let handler = nextDeltaHandler() { await handler(value) }
    }

    func preview(_ value: String) async {
        if let handler = currentPreviewHandler() { await handler(value) }
    }

    func drained() async {
        let (wasFirstDrain, handler) = beginDrain()
        guard wasFirstDrain else { return }
        if let handler { await handler() }
    }

    private func beginDrain() -> (Bool, (() async -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        guard !isDrained else { return (false, nil) }
        isDrained = true
        return (true, drainedHandler)
    }

    private func nextDeltaHandler() -> ((String) async -> Void)? {
        lock.lock(); defer { lock.unlock() }
        guard forwardAllDeltas || !forwardedFirstDelta else { return nil }
        forwardedFirstDelta = true
        return deltaHandler
    }

    private func currentPreviewHandler() -> ((String) async -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return previewHandler
    }

}

@MainActor
final class VoiceDictationCoordinator {
    private final class PreparedRealtime {
        let id = UUID()
        let settings: Config.DictationSettings
        let router: VoiceRealtimeEventRouter
        let task: Task<VoiceRealtimeTranscriptionSession, Error>
        var keepaliveTask: Task<Void, Never>?

        init(settings: Config.DictationSettings,
             router: VoiceRealtimeEventRouter,
             task: Task<VoiceRealtimeTranscriptionSession, Error>) {
            self.settings = settings
            self.router = router
            self.task = task
        }
    }

    private final class Session {
        enum Purpose {
            case resolvingSelection
            case dictation
            /// `canReplace` is frozen at the press edge. A readable terminal/scrollback selection
            /// is still useful input to the edit model, but its result is clipboard-only.
            case selectionEdit(original: String, canReplace: Bool)
            case unsupportedSelection(message: String)

            var isSelectionEdit: Bool {
                if case .selectionEdit = self { return true }
                return false
            }

            var isDictation: Bool {
                if case .dictation = self { return true }
                return false
            }
        }

        let id: UUID
        let handled: Controller.HandledAction
        let settings: Config.DictationSettings
        let promptContext: VoicePromptContext?
        var target: VoiceTextTarget?
        var targetTask: Task<VoiceTextTarget, Never>?
        var purpose: Purpose
        var purposeApplied = false
        let pressNanoseconds: UInt64
        let capture: VoiceAudioCaptureSession

        var realtimeTask: Task<VoiceRealtimeTranscriptionSession, Error>?
        var pumpTask: Task<Void, Error>?
        var promoted = false
        var minimumDurationReached = false
        var releasedNanoseconds: UInt64?
        var insertedStreamingText = ""
        var pendingStreamingDelta = ""
        var hasFlushedStreamingDelta = false
        var deltaFlushWork: DispatchWorkItem?
        var streamingDeliveryTask: Task<Void, Never>?
        var streamingInsertionBlocked = false
        var realtimeEventsDrained = false
        var realtimeDrainContinuation: CheckedContinuation<Void, Never>?
        var metrics = VoiceLatencyMetrics.empty

        init(id: UUID, handled: Controller.HandledAction,
             settings: Config.DictationSettings, target: VoiceTextTarget?,
             promptContext: VoicePromptContext?, pressNanoseconds: UInt64,
             capture: VoiceAudioCaptureSession) {
            self.id = id
            self.handled = handled
            self.settings = settings
            self.target = target
            self.promptContext = promptContext
            self.purpose = settings.selectionEditingEnabled
                ? .resolvingSelection : .dictation
            self.pressNanoseconds = pressNanoseconds
            self.capture = capture
        }
    }

    let runtime: VoiceRuntimeModel

    var onMeteringChanged: ((Bool) -> Void)?
    var onListeningBegan: ((Controller.HandledAction) -> Void)?
    var onSelectionEditingBegan: ((_ characterCount: Int, _ applicationName: String) -> Void)?
    var onListeningEnded: ((String) -> Void)?
    /// Fires only after the stopped PCM buffer proves the turn was shorter than its configured
    /// minimum. Visual clients use this distinction to reverse the listening entrance rather than
    /// presenting a processing or failure state.
    var onShortCaptureDiscarded: (() -> Void)?
    /// Runs after the capture queue has accepted the physical release and closed the PCM stream.
    /// The paired stop sound is deliberately attached here so laptop-speaker feedback cannot be
    /// appended to the utterance it acknowledges.
    var onCaptureStopped: (() -> Void)?
    var onPhaseChanged: ((VoiceDictationPhase, String) -> Void)?

    private let transcription = VoiceTranscriptionClient()
    private let processor = VoiceTextProcessor()
    private let deliverer = VoiceTextDeliverer()
    private let correctionMonitor = VoiceCorrectionMonitor()
    private var active: Session?
    private var lastTranscript = ""
    /// Keep one prepared socket for each route the configured layers can actually select. There
    /// are only two output modes, so this removes the first-press-after-layer-switch handshake
    /// without allowing the number of warm connections to grow with the number of layers.
    private var configuredPrewarmSettings: [Config.DictationOutputMode: Config.DictationSettings] = [:]
    private var preparedRealtime: [Config.DictationOutputMode: PreparedRealtime] = [:]
    private var prewarmFailureCounts: [Config.DictationOutputMode: Int] = [:]
    private var blockedPrewarmModes = Set<Config.DictationOutputMode>()
    private var prewarmRetryWork: [Config.DictationOutputMode: DispatchWorkItem] = [:]
    private var historyAppProfiles: [String: String] = [:]

    init(runtime: VoiceRuntimeModel) {
        self.runtime = runtime
    }

    var isActive: Bool { active != nil }

    /// Uses only explicit bundle mappings. The config's "default" mode is routing fallback, not a
    /// shared writing-style group: otherwise every unmapped app would contaminate one history.
    func configureHistoryProfiles(_ appProfiles: [String: String]) {
        historyAppProfiles = appProfiles.filter { $0.key != "default" }
    }

    /// Keeps one no-audio transcription socket warm for every selectable output mode. This removes
    /// DNS/TLS/session setup from the physical press path even immediately after a Layer switch;
    /// 15-second pings keep the sockets alive without sending microphone data.
    func configure(_ settings: Config.DictationSettings,
                   prewarmModes: Set<Config.DictationOutputMode>? = nil,
                   forceReconnect: Bool = false) {
        let previous = configuredPrewarmSettings
        let desiredModes = settings.enabled
            ? (prewarmModes ?? Set([settings.outputMode])) : []
        let desired = Dictionary(uniqueKeysWithValues: desiredModes.map { mode in
            var resolved = settings
            resolved.outputMode = mode
            return (mode, resolved)
        })
        configuredPrewarmSettings = desired
        // Permanent failures stay quiet until the relevant credential/configuration changes.
        // Transient backoff likewise resets only for a meaningful session change, not every
        // unrelated slider tick or config hot reload.
        for mode in Set(previous.keys).union(desired.keys) {
            let changed = previous[mode].flatMap { old in
                desired[mode].map { !Self.realtimeCompatible(old, $0) }
            } ?? (previous[mode] == nil || desired[mode] == nil)
            if forceReconnect || changed { resetPrewarmRetryState(for: mode) }
        }
        if let finalSettings = configuredPrewarmSettings[.final],
           finalSettings.cleanupProvider != .none,
           Self.cleanupCredentialIsCached(finalSettings) {
            Task { [processor] in
                await processor.prewarm(finalSettings, force: forceReconnect)
            }
        }
        if let selectionSettings = desired.values.first,
           selectionSettings.selectionEditingEnabled,
           Self.selectionCredentialIsCached(selectionSettings) {
            Task { [processor] in
                await processor.prewarmSelectionEditing(selectionSettings,
                                                         force: forceReconnect)
            }
        }
        guard active == nil else { return }
        if configuredPrewarmSettings.isEmpty {
            discardAllPreparedRealtime()
            resetAllPrewarmRetryState()
            return
        }
        guard VoiceCredentialStore.cachedContains(.openAI) else {
            discardAllPreparedRealtime()
            resetAllPrewarmRetryState()
            return
        }
        if forceReconnect { discardAllPreparedRealtime() }
        startPrewarmIfNeeded()
    }

    /// Synchronous and intentionally tiny: capture only the frontmost PID, allocate the session and
    /// start queues. Cross-process AX, TLS, audio conversion and encoding happen away from main.
    /// Returning false lets the input handler keep a busy second press in its ordinary mapping path.
    func prime(_ handled: Controller.HandledAction,
               settings: Config.DictationSettings) -> VoiceDictationAdmission {
        // `contains` is an in-memory lookup after startup (20k reads benchmark below 1 ms). Reject
        // before opening audio when Voice cannot possibly establish its mandatory transcription
        // session, so a missing key never creates a phantom hold or microphone flash.
        guard active == nil else { return .busy }
        guard VoiceCredentialStore.cachedContains(.openAI) else { return .misconfigured }
        correctionMonitor.cancel()

        let pressedAt = DispatchTime.now().uptimeNanoseconds
        let targetSeed = deliverer.captureTargetSeed()
        let promptContext = targetSeed.map {
            VoicePromptContext.resolve(
                bundleIdentifier: $0.bundleIdentifier,
                applicationName: $0.applicationName,
                appProfiles: historyAppProfiles
            )
        }
        let id = UUID()
        let capture = VoiceAudioCaptureSession(
            minimumDuration: settings.minimumRecordingSeconds,
            maxDuration: settings.maxRecordingSeconds,
            onMinimumDurationReached: { [weak self] in
                Task { @MainActor in self?.markMinimumDurationReached(id: id) }
            },
            onMaximumDuration: { [weak self] in
                Task { @MainActor in self?.finishIfCurrent(id: id) }
            },
            onFirstAudioChunk: { [weak self] in
                let timestamp = DispatchTime.now().uptimeNanoseconds
                Task { @MainActor in self?.markFirstAudio(id: id, timestamp: timestamp) }
            }
        )
        let session = Session(id: id, handled: handled, settings: settings,
                              target: nil, promptContext: promptContext,
                              pressNanoseconds: pressedAt, capture: capture)
        // A temporarily unavailable frontmost target is not a reason to discard a whole Voice
        // turn. Final delivery already has a lossless no-target route: generate the text and copy
        // it. Selection detection, when possible, is resolved asynchronously below.
        if targetSeed == nil { session.purpose = .dictation }
        active = session
        // Start the pinned microphone demand and ring reader immediately. The feeder callback is
        // asynchronous, so CoreAudio wakes in parallel with target resolution and networking.
        // This is still visually silent until the existing 200 ms hold promotion.
        onMeteringChanged?(true)
        capture.start()
        if let targetSeed {
            let detectSelection = settings.selectionEditingEnabled
            let targetTask = Task { [deliverer] in
                await deliverer.resolveTargetForVoice(
                    targetSeed, detectSelection: detectSelection
                )
            }
            session.targetTask = targetTask
            Task { [weak self, weak session] in
                let target = await targetTask.value
                guard let self, let session, self.active?.id == session.id else { return }
                self.targetDidResolve(target, for: session)
            }
        }
        transition(.priming, message: L("Preparing voice input…"))
        return .accepted
    }

    /// Surface a configuration failure that prevented a Voice turn from being admitted. Keeping
    /// this on the coordinator's normal phase channel means the floating surfaces and the
    /// Settings "Last-run" row always report the same actionable message.
    func reportConfigurationError(_ message: String) {
        guard active == nil else { return }
        runtime.livePreview = ""
        transition(.error, message: message)
        scheduleIdle(after: 2.2)
    }

    /// Called at +200 ms only if the physical button is still down.
    func beginListening() {
        guard let session = active, !session.promoted else { return }
        session.promoted = true
        // Quick taps and accidental sub-minimum holds stay entirely inside the local capture ring.
        // Once enough real PCM exists, checkout remains constant-time and the unbounded stream
        // drains its buffered prefix into the already warm socket without losing the first word.
        if session.settings.feedbackSoundsEnabled {
            session.capture.excludeAcousticFeedback(
                for: VoiceFeedbackSound.acousticExclusionDuration
            )
        }
        transition(.listening, message: L("Listening · speak now"))
        onListeningBegan?(session.handled)
        applyResolvedPurpose(session)
    }

    private func targetDidResolve(_ target: VoiceTextTarget, for session: Session) {
        guard active?.id == session.id else { return }
        session.target = target
        guard session.settings.selectionEditingEnabled else {
            session.purpose = .dictation
            if session.promoted { applyResolvedPurpose(session) }
            return
        }
        switch target.selectionState {
        case .none:
            session.purpose = .dictation
        case .editable(let text):
            session.purpose = .selectionEdit(original: text, canReplace: true)
        case .readOnly(let text):
            if let text, !text.isEmpty {
                session.purpose = .selectionEdit(original: text, canReplace: false)
            } else {
                session.purpose = .unsupportedSelection(
                    message: L("This read-only editor does not expose selected text through Accessibility")
                )
            }
        case .secure:
            session.purpose = .unsupportedSelection(
                message: L("Secure fields cannot be read or changed")
            )
        }
        if session.promoted { applyResolvedPurpose(session) }
    }

    private func applyResolvedPurpose(_ session: Session) {
        guard active?.id == session.id, session.promoted else { return }
        if case .resolvingSelection = session.purpose { return }
        if session.purposeApplied {
            if session.minimumDurationReached { activateRealtime(session) }
            if session.purpose.isDictation, session.settings.outputMode == .streaming,
               !session.pendingStreamingDelta.isEmpty {
                flushStreamingDelta(session)
            }
            return
        }
        session.purposeApplied = true
        switch session.purpose {
        case .resolvingSelection:
            assertionFailure("resolved purpose cannot return to pending")
        case .unsupportedSelection(let message):
            rejectVisibleSession(session, message: message)
        case .dictation:
            if session.settings.outputMode == .final,
               session.settings.cleanupProvider != .none {
                Task { [processor] in await processor.prewarm(session.settings) }
            }
            if session.minimumDurationReached { activateRealtime(session) }
            if session.settings.outputMode == .streaming,
               !session.pendingStreamingDelta.isEmpty {
                flushStreamingDelta(session)
            }
        case .selectionEdit(let original, let canReplace):
            guard Self.selectionCredentialIsCached(session.settings) else {
                let message = session.settings.selectionEditProvider == .deepSeek
                    ? L("DeepSeek API Key is missing · add and test it in Settings → Voice")
                    : VoiceAPIError.missingOpenAIKeyMessage
                rejectVisibleSession(session, message: message)
                return
            }
            onSelectionEditingBegan?(original.count,
                                     session.target?.applicationName ?? L("Current App"))
            transition(
                .listening,
                message: canReplace && session.settings.autoInsert
                    ? L("Editing selection · speak an instruction")
                    : L("Read-only selection · the rewrite will be copied")
            )
            Task { [processor] in await processor.prewarmSelectionEditing(session.settings) }
            if session.minimumDurationReached { activateRealtime(session) }
        }
    }

    /// A promoted turn has already opened both Voice surfaces and played the start cue. Close that
    /// same turn as a paired failure, but never wait for key-up and never reinterpret it as dictation.
    private func rejectVisibleSession(_ session: Session, message: String) {
        guard active?.id == session.id else { return }
        active = nil
        releaseRealtimeDrainWaiter(session)
        session.deltaFlushWork?.cancel()
        session.targetTask?.cancel()
        session.streamingDeliveryTask?.cancel()
        session.realtimeTask?.cancel()
        session.pumpTask?.cancel()
        onMeteringChanged?(false)
        onListeningEnded?(session.handled.key)
        runtime.livePreview = ""
        transition(.error, message: message)
        scheduleIdle(after: 2.2)
        Task { [weak self] in
            _ = await session.capture.stop()
            if let live = try? await session.realtimeTask?.value { await live.cancel() }
            await MainActor.run { self?.onCaptureStopped?() }
        }
        startPrewarmIfNeeded()
    }

    private func activateRealtime(_ session: Session) {
        guard active?.id == session.id, session.realtimeTask == nil else { return }
        let settings = session.settings
        let id = session.id
        let router: VoiceRealtimeEventRouter
        let realtimeTask: Task<VoiceRealtimeTranscriptionSession, Error>
        if let prepared = preparedRealtime[settings.outputMode],
           Self.realtimeCompatible(prepared.settings, settings) {
            preparedRealtime.removeValue(forKey: settings.outputMode)
            prepared.keepaliveTask?.cancel()
            router = prepared.router
            realtimeTask = prepared.task
        } else {
            discardPreparedRealtime(for: settings.outputMode)
            router = VoiceRealtimeEventRouter()
            realtimeTask = makeRealtimeTask(settings: settings, router: router)
        }
        let realtimeAlreadyDrained = router.attach(
            onDelta: { [weak self] delta in
                await MainActor.run { self?.receiveDelta(delta, id: id) }
            },
            onPreview: { [weak self, weak session] preview in
                guard settings.outputMode == .streaming || session?.purpose.isSelectionEdit == true
                else { return }
                await MainActor.run { self?.receivePreview(preview, id: id) }
            },
            onDrained: { [weak self] in
                await MainActor.run { self?.markRealtimeEventsDrained(id: id) }
            },
            // Final mode needs the first delta only for latency diagnostics; it does not stream text
            // to the editor, so skipping later UI hops leaves the receive loop maximally responsive.
            forwardAllDeltas: settings.outputMode == .streaming || session.purpose.isSelectionEdit
        )
        if realtimeAlreadyDrained { markRealtimeEventsDrained(id: id) }
        session.realtimeTask = realtimeTask
        Task { [weak self] in
            do {
                _ = try await realtimeTask.value
                let ready = DispatchTime.now().uptimeNanoseconds
                await MainActor.run { self?.markSessionReady(id: id, timestamp: ready) }
            } catch { /* REST fallback owns the user-visible error after release. */ }
        }
        session.pumpTask = Task { [weak self, weak session] in
            guard let session else { throw VoiceTranscriptionError.cancelled }
            let live = try await realtimeTask.value
            for await chunk in session.capture.chunks {
                try Task.checkCancellation()
                try await live.append(chunk)
            }
            _ = self // retain coordinator only for this session's lifetime
        }
    }

    /// Raw release before +200 ms. Nothing was visible or inserted, so cancellation is silent.
    func cancelPrime() {
        guard let session = active, !session.promoted else { return }
        active = nil
        session.deltaFlushWork?.cancel()
        session.targetTask?.cancel()
        session.streamingDeliveryTask?.cancel()
        session.realtimeTask?.cancel()
        session.pumpTask?.cancel()
        Task {
            _ = await session.capture.stop()
            if let live = try? await session.realtimeTask?.value { await live.cancel() }
        }
        onMeteringChanged?(false)
        transition(.idle, message: "")
        startPrewarmIfNeeded()
    }

    /// Physical release after Voice opened. UI/mic demand end immediately; networking finishes in
    /// the background and the captured buffer provides a lossless REST fallback.
    func finishListening() {
        guard let session = active, session.promoted, session.releasedNanoseconds == nil else { return }
        session.releasedNanoseconds = DispatchTime.now().uptimeNanoseconds
        session.deltaFlushWork?.cancel()
        if session.settings.outputMode == .streaming, session.purpose.isDictation,
           session.minimumDurationReached {
            flushStreamingDelta(session)
        }
        onMeteringChanged?(false)
        onListeningEnded?(session.handled.key)
        if session.settings.outputMode == .streaming, session.purpose.isDictation,
           session.minimumDurationReached {
            // The editor already contains the live result. Return the compact widget straight to
            // its Layer while the authoritative suffix is reconciled invisibly in the background.
            // A sub-minimum turn stays visible for the distinct reverse-particle dismissal once
            // the stopped PCM buffer has confirmed that it is actually short.
            transition(.idle, message: "")
        }

        Task { [weak self, weak session] in
            guard let self, let session else { return }
            let audio = await session.capture.stop()
            await MainActor.run { [weak self] in self?.onCaptureStopped?() }
            await self.captureDidStop(session, audio: audio)
        }
    }

    @discardableResult
    func copyLastTranscript() -> Bool {
        guard !lastTranscript.isEmpty else {
            transition(.error, message: L("There is no previous dictation to copy."))
            return false
        }
        let result = deliverer.copy(lastTranscript)
        if result == .copied {
            transition(.copied, message: L("Previous dictation copied"))
            scheduleIdle(after: 0.9)
            return true
        }
        transition(.error, message: L("The previous dictation couldn't be copied."))
        return false
    }

    private func captureDidStop(_ session: Session, audio: VoiceCapturedAudio) async {
        guard active?.id == session.id else { return }
        session.metrics.audioSource = audio.source.rawValue
        session.metrics.audioDurationMilliseconds = audio.duration * 1_000
        guard Self.minimumDurationMet(audio.duration,
                                      minimum: session.settings.minimumRecordingSeconds) else {
            await discardShortCapture(session)
            return
        }
        session.minimumDurationReached = true
        if case .resolvingSelection = session.purpose,
           let targetTask = session.targetTask {
            targetDidResolve(await targetTask.value, for: session)
        }
        guard active?.id == session.id else { return }
        activateRealtime(session)
        if session.purpose.isSelectionEdit {
            transition(.transcribing, message: L("Understanding edit instruction…"))
        } else if session.settings.outputMode == .streaming {
            // A boundary release can stop the PCM queue just before its minimum-duration callback
            // reaches the main actor. Once the captured duration confirms validity, preserve the
            // normal Streaming behavior and close without showing a processing state.
            transition(.idle, message: "")
        } else if let phase = VoiceDictationPresentationPolicy.releasePhase(
            for: session.settings.outputMode
        ) {
            transition(phase, message: L("Finishing transcript…"))
        }
        await complete(session, audio: audio)
    }

    private func complete(_ session: Session, audio: VoiceCapturedAudio) async {
        guard active?.id == session.id else { return }

        let transcript: String
        do {
            transcript = try await realtimeResult(session, audio: audio)
        } catch {
            await fail(session, error: error)
            return
        }
        guard active?.id == session.id else { return }
        let transcriptReady = DispatchTime.now().uptimeNanoseconds
        if let release = session.releasedNanoseconds {
            session.metrics.releaseToTranscriptMilliseconds = Self.milliseconds(release, transcriptReady)
        }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await fail(session, error: VoiceTranscriptionError.invalidAudio)
            return
        }

        if case .selectionEdit(let original, let canReplace) = session.purpose {
            await completeSelectionEdit(session, selectedText: original,
                                        instruction: transcript, canReplace: canReplace)
            return
        }

        let finalText: String
        var warning: String?
        if session.settings.outputMode == .final {
            transition(.polishing, message: session.settings.cleanupProvider == .none
                       ? L("Applying dictionary…") : L("Polishing transcript…"))
            let cleanupStart = DispatchTime.now().uptimeNanoseconds
            let result = await processor.processFinal(
                transcript, settings: session.settings, context: session.promptContext
            )
            let cleanupEnd = DispatchTime.now().uptimeNanoseconds
            session.metrics.cleanupMilliseconds = Self.milliseconds(cleanupStart, cleanupEnd)
            finalText = result.text
            warning = result.warning
        } else {
            // Streaming's latency contract forbids a second LLM round-trip. Dictionary terms were
            // already supplied as transcription hints. Preserve the server's raw whitespace until
            // strict reconciliation is complete: deltas may already contain that same whitespace.
            finalText = transcript
        }

        let historyText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard active?.id == session.id, !historyText.isEmpty else { return }
        lastTranscript = historyText
        runtime.hasLastTranscript = true
        if VoiceDictationPresentationPolicy.showsInsertionProgress(
            for: session.settings.outputMode
        ) {
            transition(.inserting, message: L("Delivering text…"))
        }
        // Target resolution began on the physical press edge. Do not serialize it ahead of
        // transcription/cleanup; await it only at the last responsible moment before insertion.
        if session.target == nil, let targetTask = session.targetTask {
            session.target = await targetTask.value
        }
        guard active?.id == session.id else { return }
        let insertionStart = DispatchTime.now().uptimeNanoseconds
        let outcome: VoiceTextDeliveryOutcome
        if session.settings.outputMode == .streaming {
            outcome = await finishStreamingDelivery(finalText, session: session)
        } else {
            outcome = await deliverer.deliverFinal(finalText, to: session.target,
                                                   settings: session.settings)
        }
        let insertionEnd = DispatchTime.now().uptimeNanoseconds
        session.metrics.insertionMilliseconds = Self.milliseconds(insertionStart, insertionEnd)
        if outcome.wasDelivered {
            let recordID = processor.remember(
                sourceTranscript: transcript, finalText: historyText,
                context: session.promptContext
            )
            if outcome == .inserted, let recordID,
               let target = session.target, let context = session.promptContext {
                correctionMonitor.observe(target: target, insertedText: historyText) {
                    [processor] correctedText in
                    processor.learnCorrection(correctedText, recordID: recordID, context: context)
                }
            }
        }
        runtime.lastMetrics = session.metrics
        runtime.livePreview = ""
        active = nil

        let baseMessage: String
        switch outcome {
        case .inserted: baseMessage = L("Dictation inserted")
        case .copied: baseMessage = L("Insertion was unavailable · copied instead")
        case .focusChanged: baseMessage = L("Target changed before insertion")
        case .secureField: baseMessage = L("Secure fields are not modified")
        case .unavailable: baseMessage = L("Text could not be delivered")
        }
        if let phase = VoiceDictationPresentationPolicy.completionPhase(
            for: session.settings.outputMode, outcome: outcome
        ) {
            let message = warning.map { "\(baseMessage) · \($0)" } ?? baseMessage
            transition(phase, message: message)
            scheduleIdle(after: outcome.wasDelivered ? 1.0 : 2.2)
        }
        startPrewarmIfNeeded()
    }

    private func completeSelectionEdit(_ session: Session, selectedText: String,
                                       instruction: String, canReplace: Bool) async {
        guard active?.id == session.id, let target = session.target else { return }
        transition(.rewriting, message: L("Applying your instruction to the selection…"))
        let processingStart = DispatchTime.now().uptimeNanoseconds
        let replacement: String
        do {
            replacement = try await processor.rewriteSelection(
                selectedText, instruction: instruction, settings: session.settings
            )
        } catch {
            session.metrics.cleanupMilliseconds = Self.milliseconds(
                processingStart, DispatchTime.now().uptimeNanoseconds
            )
            await fail(session, error: error)
            return
        }
        session.metrics.cleanupMilliseconds = Self.milliseconds(
            processingStart, DispatchTime.now().uptimeNanoseconds
        )
        guard active?.id == session.id else { return }

        let insertionStart = DispatchTime.now().uptimeNanoseconds
        let outcome: VoiceSelectionReplacementOutcome?
        if session.settings.autoInsert, canReplace {
            outcome = await deliverer.replaceSelection(
                replacement, in: target,
                restoreClipboardAfterPaste: session.settings.restoreClipboardAfterInsert
            )
        } else {
            outcome = nil
        }
        session.metrics.insertionMilliseconds = Self.milliseconds(
            insertionStart, DispatchTime.now().uptimeNanoseconds
        )
        runtime.lastMetrics = session.metrics
        runtime.livePreview = ""
        active = nil

        let clean = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        lastTranscript = clean
        runtime.hasLastTranscript = !clean.isEmpty

        if outcome == .replaced {
            transition(.replaced, message: L("Selected text updated"))
            scheduleIdle(after: 1.0)
        } else {
            let reason: String
            if !session.settings.autoInsert {
                reason = L("Automatic insertion is off")
            } else if !canReplace {
                reason = L("The selected text is read-only")
            } else {
                switch outcome {
                case .focusChanged?: reason = L("Focus changed before replacement")
                case .selectionChanged?: reason = L("Selection changed while editing")
                case .readOnly?: reason = L("The selected text became read-only")
                case .secureField?: reason = L("The target became a secure field")
                case .accessibilityUnavailable?: reason = L("Accessibility replacement failed")
                case .replaced?, nil: reason = L("Selection replacement was unavailable")
                }
            }
            if deliverer.copy(replacement) == .copied {
                transition(.copied, message: L("%@ · rewrite copied", reason))
                scheduleIdle(after: 1.4)
            } else {
                transition(.error, message: L("%@ · clipboard copy failed", reason))
                scheduleIdle(after: 2.2)
            }
        }
        startPrewarmIfNeeded()
    }

    private func realtimeResult(_ session: Session, audio: VoiceCapturedAudio) async throws -> String {
        // Reject only actual emptiness. Quiet speech can have very low RMS and must reach the model.
        guard audio.frameCount >= VoiceAudioCaptureSession.outputSampleRate / 10,
              audio.meanSquare > 1e-12 else { throw VoiceTranscriptionError.invalidAudio }
        do {
            try await session.pumpTask?.value
            guard let live = try await session.realtimeTask?.value else {
                throw VoiceTranscriptionError.invalidResponse
            }
            let text = try await live.finish()
            // `finish()` observes the transcript state as soon as the completed WebSocket event is
            // decoded. Wait for that same receive loop to finish its ordered callbacks before any
            // streaming reconciliation can inspect the inserted prefix.
            await waitForRealtimeDrain(session)
            if !text.isEmpty { return text }
            throw VoiceTranscriptionError.invalidResponse
        } catch VoiceTranscriptionError.cancelled {
            throw VoiceTranscriptionError.cancelled
        } catch is CancellationError {
            throw VoiceTranscriptionError.cancelled
        } catch {
            // The complete PCM buffer is already in memory. REST fallback preserves the utterance
            // after a transient WebSocket failure rather than asking the user to repeat it. Start
            // the REST request immediately, cancel the live socket, and reconcile only after the
            // receive loop has drained every callback. Network latency and draining overlap.
            let fallback = Task { [transcription] in
                try await transcription.transcribeFinal(
                    audio,
                    model: session.settings.finalModel,
                    languageHints: session.settings.languageHints,
                    dictionary: session.settings.dictionary
                )
            }
            if let live = try? await session.realtimeTask?.value {
                await live.cancel()
            } else {
                session.realtimeTask?.cancel()
            }
            await waitForRealtimeDrain(session)
            return try await fallback.value
        }
    }

    private func finishStreamingDelivery(_ finalText: String,
                                         session: Session) async -> VoiceTextDeliveryOutcome {
        // The explicit WebSocket receive-loop drain guarantees that every delta is already on this
        // actor on both success and REST fallback. Cancel the coalescer, flush, then drain delivery.
        session.deltaFlushWork?.cancel()
        session.deltaFlushWork = nil
        if !session.pendingStreamingDelta.isEmpty { flushStreamingDelta(session) }
        if let delivery = session.streamingDeliveryTask { await delivery.value }
        guard session.settings.autoInsert, let target = session.target else {
            let clean = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            return deliverer.copy(clean)
        }
        guard !session.streamingInsertionBlocked else {
            let clean = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            return deliverer.copy(clean)
        }
        let alreadyInserted = session.insertedStreamingText
        if let suffix = VoiceStreamingReconciliation.missingSuffix(
            committed: finalText, inserted: alreadyInserted
        ) {
            if suffix.isEmpty { return .inserted }
            let outcome = await deliverer.insertStreamingDelta(suffix, into: target)
            if outcome == .inserted { session.insertedStreamingText += suffix }
            return outcome == .inserted ? .inserted
                : deliverer.copy(finalText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // A service-side revision cannot be safely patched over text that is already in the user's
        // editor. Put the authoritative committed turn on the clipboard instead of duplicating it.
        _ = await deliverer.targetRejection(target)
        return deliverer.copy(finalText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func receiveDelta(_ delta: String, id: UUID) {
        guard let session = active, session.id == id, !delta.isEmpty else { return }
        if session.metrics.pressToFirstDeltaMilliseconds == nil {
            session.metrics.pressToFirstDeltaMilliseconds = Self.milliseconds(
                session.pressNanoseconds, DispatchTime.now().uptimeNanoseconds
            )
        }
        runtime.livePreview += delta
        guard session.purpose.isDictation,
              session.settings.outputMode == .streaming,
              session.settings.autoInsert, !session.streamingInsertionBlocked else { return }
        session.pendingStreamingDelta += delta
        guard session.promoted, session.deltaFlushWork == nil else { return }
        if !session.hasFlushedStreamingDelta {
            // The first visible token is the perceptual latency boundary; deliver it in this runloop.
            flushStreamingDelta(session)
            return
        }
        // An 8 ms coalescing window is below a 120 Hz frame while avoiding one CGEvent pair per
        // tiny token fragment. The first partial still reaches the caret essentially immediately.
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            session.deltaFlushWork = nil
            self.flushStreamingDelta(session)
        }
        session.deltaFlushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.008, execute: work)
    }

    private func receivePreview(_ preview: String, id: UUID) {
        guard active?.id == id else { return }
        runtime.livePreview = preview
    }

    private func markRealtimeEventsDrained(id: UUID) {
        guard let session = active, session.id == id else { return }
        session.realtimeEventsDrained = true
        session.realtimeDrainContinuation?.resume()
        session.realtimeDrainContinuation = nil
    }

    private func waitForRealtimeDrain(_ session: Session) async {
        guard !session.realtimeEventsDrained else { return }
        await withCheckedContinuation { continuation in
            // MainActor isolation makes the check-and-store atomic with the drain callback.
            if session.realtimeEventsDrained {
                continuation.resume()
            } else {
                precondition(session.realtimeDrainContinuation == nil)
                session.realtimeDrainContinuation = continuation
            }
        }
    }

    private func releaseRealtimeDrainWaiter(_ session: Session) {
        session.realtimeDrainContinuation?.resume()
        session.realtimeDrainContinuation = nil
    }

    private func flushStreamingDelta(_ session: Session) {
        guard active?.id == session.id, session.promoted,
              session.minimumDurationReached,
              session.purpose.isDictation,
              !session.pendingStreamingDelta.isEmpty,
              session.settings.autoInsert,
              !session.streamingInsertionBlocked,
              let target = session.target else { return }
        let delta = session.pendingStreamingDelta
        session.pendingStreamingDelta = ""
        session.hasFlushedStreamingDelta = true
        let previous = session.streamingDeliveryTask
        session.streamingDeliveryTask = Task { @MainActor [weak self, weak session] in
            if let previous { await previous.value }
            guard let self, let session, self.active?.id == session.id,
                  !Task.isCancelled, !session.streamingInsertionBlocked else { return }
            let outcome = await self.deliverer.insertStreamingDelta(delta, into: target)
            guard self.active?.id == session.id, !Task.isCancelled else { return }
            if outcome == .inserted {
                session.insertedStreamingText += delta
            } else {
                session.streamingInsertionBlocked = true
            }
        }
    }

    private func markFirstAudio(id: UUID, timestamp: UInt64) {
        guard let session = active, session.id == id,
              session.metrics.pressToFirstAudioMilliseconds == nil else { return }
        session.metrics.pressToFirstAudioMilliseconds = Self.milliseconds(
            session.pressNanoseconds, timestamp
        )
    }

    private func markMinimumDurationReached(id: UUID) {
        guard let session = active, session.id == id,
              !session.minimumDurationReached else { return }
        session.minimumDurationReached = true
        guard session.promoted else { return }
        applyResolvedPurpose(session)
    }

    private func markSessionReady(id: UUID, timestamp: UInt64) {
        guard let session = active, session.id == id,
              session.metrics.pressToSessionReadyMilliseconds == nil else { return }
        session.metrics.pressToSessionReadyMilliseconds = Self.milliseconds(
            session.pressNanoseconds, timestamp
        )
    }

    private func finishIfCurrent(id: UUID) {
        guard active?.id == id else { return }
        finishListening()
    }

    private func fail(_ session: Session, error: Error) async {
        guard active?.id == session.id else { return }
        releaseRealtimeDrainWaiter(session)
        session.deltaFlushWork?.cancel()
        session.targetTask?.cancel()
        session.streamingDeliveryTask?.cancel()
        session.realtimeTask?.cancel()
        session.pumpTask?.cancel()
        if let live = try? await session.realtimeTask?.value { await live.cancel() }
        runtime.lastMetrics = session.metrics
        runtime.livePreview = ""
        active = nil
        onMeteringChanged?(false)
        transition(.error, message: VoiceAPIError.userFacingMessage(for: error))
        scheduleIdle(after: 2.2)
        startPrewarmIfNeeded()
    }

    private func discardShortCapture(_ session: Session) async {
        guard active?.id == session.id else { return }
        releaseRealtimeDrainWaiter(session)
        session.deltaFlushWork?.cancel()
        session.targetTask?.cancel()
        session.streamingDeliveryTask?.cancel()
        session.realtimeTask?.cancel()
        session.pumpTask?.cancel()
        if let live = try? await session.realtimeTask?.value { await live.cancel() }
        runtime.lastMetrics = session.metrics
        runtime.livePreview = ""
        active = nil
        onMeteringChanged?(false)
        onShortCaptureDiscarded?()
        transition(.idle, message: "")
        startPrewarmIfNeeded()
    }

    private func makeRealtimeTask(
        settings: Config.DictationSettings,
        router: VoiceRealtimeEventRouter
    ) -> Task<VoiceRealtimeTranscriptionSession, Error> {
        let model = settings.outputMode == .streaming
            ? settings.streamingModel : settings.finalModel
        return Task { [transcription] in
            try await transcription.openRealtime(
                model: model,
                minimalDelay: settings.outputMode == .streaming,
                languageHints: settings.languageHints,
                dictionary: settings.dictionary,
                onDelta: { await router.delta($0) },
                onPreview: { await router.preview($0) },
                onDrained: { await router.drained() }
            )
        }
    }

    private func startPrewarm(_ settings: Config.DictationSettings) {
        let mode = settings.outputMode
        guard preparedRealtime[mode] == nil, active == nil, settings.enabled,
              !blockedPrewarmModes.contains(mode) else { return }
        let router = VoiceRealtimeEventRouter()
        let task = makeRealtimeTask(settings: settings, router: router)
        let prepared = PreparedRealtime(settings: settings, router: router, task: task)
        preparedRealtime[mode] = prepared
        let preparedID = prepared.id
        prepared.keepaliveTask = Task { [weak self, weak prepared] in
            do {
                let live = try await task.value
                await MainActor.run { [weak self] in
                    self?.prewarmFailureCounts.removeValue(forKey: mode)
                    self?.blockedPrewarmModes.remove(mode)
                }
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    try Task.checkCancellation()
                    try await live.ping()
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard let self, self.preparedRealtime[mode]?.id == preparedID else { return }
                    self.preparedRealtime.removeValue(forKey: mode)
                    prepared?.keepaliveTask?.cancel()
                    if Self.isPermanentPrewarmFailure(error) {
                        self.blockedPrewarmModes.insert(mode)
                        self.prewarmFailureCounts.removeValue(forKey: mode)
                        NSLog("[HyperVibe Voice] %@ prewarm paused until settings change: %@",
                              mode.rawValue, error.localizedDescription)
                        return
                    }
                    let count = min(8, (self.prewarmFailureCounts[mode] ?? 0) + 1)
                    self.prewarmFailureCounts[mode] = count
                    let delay = Self.prewarmRetryDelay(
                        failureCount: count, jitter: Double.random(in: 0.85...1.15)
                    )
                    NSLog("[HyperVibe Voice] %@ prewarm failed; retry in %.1fs: %@",
                          mode.rawValue, delay, error.localizedDescription)
                    let work = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.prewarmRetryWork.removeValue(forKey: mode)
                        guard self.active == nil,
                              let desired = self.configuredPrewarmSettings[mode],
                              !self.blockedPrewarmModes.contains(mode) else { return }
                        self.startPrewarm(desired)
                    }
                    self.prewarmRetryWork[mode]?.cancel()
                    self.prewarmRetryWork[mode] = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                }
            }
        }
    }

    private func discardPreparedRealtime(for mode: Config.DictationOutputMode) {
        guard let prepared = preparedRealtime.removeValue(forKey: mode) else { return }
        prepared.keepaliveTask?.cancel()
        prepared.task.cancel()
        Task {
            if let live = try? await prepared.task.value { await live.cancel() }
        }
    }

    private func discardAllPreparedRealtime() {
        for mode in Array(preparedRealtime.keys) { discardPreparedRealtime(for: mode) }
    }

    private func startPrewarmIfNeeded() {
        guard active == nil else { return }
        guard !configuredPrewarmSettings.isEmpty,
              VoiceCredentialStore.cachedContains(.openAI) else {
            discardAllPreparedRealtime()
            return
        }
        for (mode, prepared) in Array(preparedRealtime) {
            guard let desired = configuredPrewarmSettings[mode],
                  Self.realtimeCompatible(prepared.settings, desired) else {
                discardPreparedRealtime(for: mode)
                continue
            }
        }
        for (mode, settings) in configuredPrewarmSettings
        where preparedRealtime[mode] == nil && prewarmRetryWork[mode] == nil
            && !blockedPrewarmModes.contains(mode) {
            startPrewarm(settings)
        }
    }

    private func resetPrewarmRetryState(for mode: Config.DictationOutputMode) {
        prewarmRetryWork.removeValue(forKey: mode)?.cancel()
        prewarmFailureCounts.removeValue(forKey: mode)
        blockedPrewarmModes.remove(mode)
    }

    private func resetAllPrewarmRetryState() {
        for work in prewarmRetryWork.values { work.cancel() }
        prewarmRetryWork.removeAll()
        prewarmFailureCounts.removeAll()
        blockedPrewarmModes.removeAll()
    }

    nonisolated static func prewarmRetryDelay(failureCount: Int,
                                               jitter: Double) -> TimeInterval {
        let exponent = max(0, min(6, failureCount - 1))
        let base = min(60, 3 * pow(2, Double(exponent)))
        return min(72, base * min(1.2, max(0.8, jitter)))
    }

    nonisolated static func minimumDurationMet(_ duration: TimeInterval,
                                                minimum: TimeInterval) -> Bool {
        duration.isFinite && minimum.isFinite && duration + 0.000_001 >= max(0, minimum)
    }

    private static func isPermanentPrewarmFailure(_ error: Error) -> Bool {
        guard let voiceError = error as? VoiceTranscriptionError else { return false }
        if case .missingCredential = voiceError { return true }
        guard case .service(let message) = voiceError else { return false }
        let value = message.lowercased()
        return ["http 401", "http 403", "invalid_api_key", "incorrect api key",
                "api key is invalid", "authentication", "unauthorized", "forbidden", "model_not_found",
                "unsupported model", "invalid model", "does not exist", "permission denied"]
            .contains { value.contains($0) }
    }

    private static func realtimeCompatible(_ lhs: Config.DictationSettings,
                                           _ rhs: Config.DictationSettings) -> Bool {
        lhs.outputMode == rhs.outputMode
            && lhs.finalModel == rhs.finalModel
            && lhs.streamingModel == rhs.streamingModel
            && lhs.languageHints == rhs.languageHints
            && lhs.dictionary == rhs.dictionary
    }

    private static func cleanupCredentialIsCached(_ settings: Config.DictationSettings) -> Bool {
        switch settings.cleanupProvider {
        case .none: return true
        case .openAI: return VoiceCredentialStore.cachedContains(.openAI)
        case .deepSeek: return VoiceCredentialStore.cachedContains(.deepSeek)
        }
    }

    private static func selectionCredentialIsCached(_ settings: Config.DictationSettings) -> Bool {
        switch settings.selectionEditProvider {
        case .openAI: return VoiceCredentialStore.cachedContains(.openAI)
        case .deepSeek: return VoiceCredentialStore.cachedContains(.deepSeek)
        }
    }

    private func transition(_ phase: VoiceDictationPhase, message: String) {
        runtime.phase = phase
        runtime.lastMessage = message
        onPhaseChanged?(phase, message)
    }

    private func scheduleIdle(after delay: TimeInterval) {
        let expected = runtime.phase
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.active == nil, self.runtime.phase == expected else { return }
            self.transition(.idle, message: "")
        }
    }

    private static func milliseconds(_ start: UInt64, _ end: UInt64) -> Double {
        guard end >= start else { return 0 }
        return Double(end - start) / 1_000_000
    }
}

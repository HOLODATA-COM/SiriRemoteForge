//
//  SettingsView.swift
//  HyperVibe (settings UI)
//
//  Minimal, Apple-style settings window. Every value applies live and persists.
//

import SwiftUI

private struct DictionaryEditorRequest: Identifiable {
    let id = UUID()
    let index: Int?
    let term: String
    let aliases: [String]
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// Owned by the model (see `SettingsModel.device`) so the window controller drives its polling.
    @ObservedObject var device: DeviceInfo
    @ObservedObject var voiceCredentials: VoiceCredentialModel
    @ObservedObject var voiceRuntime: VoiceRuntimeModel

    init(model: SettingsModel) {
        self.model = model
        self.device = model.device
        self.voiceCredentials = model.voiceCredentials
        self.voiceRuntime = model.voiceRuntime
    }

    @State private var saveErrorDetail: String?
    @State private var openAIKeyDraft = ""
    @State private var deepSeekKeyDraft = ""
    @State private var credentialError: String?
    @State private var dictionaryEditor: DictionaryEditorRequest?

    /// Drives live relocalization: changing the language republishes, re-running this view's body
    /// (so every `L(...)` in the Tuning tab re-evaluates) and re-`.id()`-ing the Layout subview.
    @ObservedObject private var loc = Loc.shared

    private enum Tab: String, CaseIterable {
        case tuning = "Tuning"
        case voice = "Voice"
        case layout = "Layout"
    }
    @State private var tab: Tab = .tuning

    private enum CurveTarget: Equatable { case pointer, circular }
    /// When the user closes the lock, the curve they touched most recently becomes the source.
    /// Starting with circular is intentional: existing installs already expose/tune that curve,
    /// while pointer curve shaping is new.
    @State private var lastEditedCurve: CurveTarget = .circular

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .tuning:
                tuningWorkspace
            case .voice:
                voiceWorkspace
            case .layout:
                if let config = model.config {
                    LayoutView(config: config, onSave: { newConfig in
                        // Atomic, validated write → hot-reloads → refreshes model.config. A failed
                        // write leaves the old file intact and is now visible in the shared header.
                        model.noteConfigSavePending(from: .layout)
                        do {
                            try ConfigStore.save(newConfig)
                            // Publish the exact written snapshot immediately instead of waiting for
                            // the file watcher. A pending debounced Tuning save will now merge onto
                            // this Layout edit and cannot accidentally restore the previous layout.
                            model.config = newConfig
                            model.noteConfigSaveSucceeded(from: .layout)
                        } catch {
                            model.noteConfigSaveFailed(error, from: .layout)
                            NSLog("[siriRemote] config save failed: \(error)")
                        }
                    })
                    // LayoutView is a separate view struct with unchanged inputs, so re-running this
                    // body would not re-run its body; keying it on the language forces relocalization.
                    .id(loc.language)
                } else {
                    Spacer()
                    Text(L("Loading config…")).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        // Flexible height (not fixed) so the window can be shrunk to fit smaller displays — the
        // inner ScrollView/Form then scroll instead of the content being clipped.
        .frame(width: tab == .layout ? 1100 : 1040)
        .frame(minHeight: 620, idealHeight: 780, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: tab)
        // Polling start/stop lives in SettingsWindowController — `.onDisappear` never fires for
        // this window (it is cached and only ordered out). Refresh device data on appear so a
        // reopened window never shows a stale battery or interface list.
        .onAppear {
            device.refresh()
        }
        // The remote can connect/disconnect while the window is open; refresh so battery and the
        // interface map do not go stale.
        .onChange(of: model.connected) { _ in device.refresh() }
        .alert(L("Couldn't save changes"), isPresented: Binding(
            get: { saveErrorDetail != nil },
            set: { if !$0 { saveErrorDetail = nil } }
        )) {
            Button("OK", role: .cancel) { saveErrorDetail = nil }
        } message: {
            Text(saveErrorDetail ?? "")
        }
        .alert(L("Credential error"), isPresented: Binding(
            get: { credentialError != nil },
            set: { if !$0 { credentialError = nil } }
        )) {
            Button("OK", role: .cancel) { credentialError = nil }
        } message: {
            Text(credentialError ?? "")
        }
        .sheet(item: $dictionaryEditor) { request in
            DictionaryTermEditor(
                request: request,
                existingTerms: model.tune.dictation.dictionary.enumerated().compactMap {
                    $0.offset == request.index ? nil : $0.element.term
                },
                onSave: { term, aliases in
                    saveDictionaryTerm(request.index, term: term, aliases: aliases)
                    dictionaryEditor = nil
                },
                onCancel: { dictionaryEditor = nil }
            )
        }
    }

    // MARK: - Desktop workspace

    private var tuningWorkspace: some View {
        // One document, one scroll position. The old split view forced people to remember which
        // column owned a setting and could leave two unrelated scroll positions on screen. Curve
        // ownership is now explicit and everything shared follows in a predictable vertical order.
        Form {
            curveRelationshipSection
            pointerMovementSection
            circularMovementSection
            generalSettingsIntro
            clickSection
            buttonsSection
            widgetSection
            startupSection
            updatesSection
            languageSection
            deviceSection
            footerSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Native Voice Input

    private var voiceWorkspace: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(LinearGradient(colors: [.red.opacity(0.92), .pink.opacity(0.72)],
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing))
                        Image(systemName: "waveform.and.mic")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Native Voice Input"))
                            .font(.system(size: 17, weight: .semibold))
                        Text(L("Hold the side button to dictate directly into the app you were using."))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $model.tune.dictation.enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.large)
                }
                .padding(.vertical, 5)
            } footer: {
                Text(L("Capture and the cloud connection are pre-warmed on the raw press edge. A quick tap cancels silently; Voice appears only after the existing 0.2-second hold threshold."))
            }

            Section {
                Picker(L("Voice mode"), selection: voiceModeBinding) {
                    Text(L("External")).tag(Config.DictationMode.external)
                    Text(L("Final · polished")).tag(Config.DictationMode.final)
                    Text(L("Live · fastest")).tag(Config.DictationMode.streaming)
                }
                .pickerStyle(.segmented)

                HStack(alignment: .top, spacing: 14) {
                    voiceModeCard(
                        selected: model.tune.dictation.activeMode == .external,
                        icon: "keyboard.badge.ellipsis", tint: .blue,
                        title: L("External Voice"),
                        detail: L("Uses your configured side-button action and does not open HyperVibe's Voice capsule."))
                    voiceModeCard(
                        selected: model.tune.dictation.activeMode == .final,
                        icon: "text.badge.checkmark", tint: .purple,
                        title: L("Final output"),
                        detail: L("Transcribes the complete turn, applies your dictionary, optionally polishes it, then inserts once."))
                    voiceModeCard(
                        selected: model.tune.dictation.activeMode == .streaming,
                        icon: "bolt.horizontal.circle.fill", tint: .orange,
                        title: L("Streaming output"),
                        detail: L("Sends true transcript deltas to the caret immediately. No cleanup-model round trip is added."))
                }

                if voiceUsesFinalMode {
                    Picker(L("Transcript cleanup"),
                           selection: $model.tune.dictation.cleanupProvider) {
                        Text(L("None · dictionary only"))
                            .tag(Config.DictationCleanupProvider.none)
                        Text("OpenAI").tag(Config.DictationCleanupProvider.openAI)
                        Text("DeepSeek").tag(Config.DictationCleanupProvider.deepSeek)
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text(L("Global Voice Mode"))
            } footer: {
                Text(L("The selected Voice mode is identical on every Layer. Hold Mute and tap the side button to cycle External, Final, and Live without changing Layer."))
            }
            .disabled(!model.tune.dictation.enabled)

            Section {
                Toggle(isOn: $model.tune.dictation.selectionEditingEnabled) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(LinearGradient(colors: [.indigo.opacity(0.92),
                                                              .purple.opacity(0.72)],
                                                     startPoint: .topLeading,
                                                     endPoint: .bottomTrailing))
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Rewrite selected text with Voice"))
                                .font(.system(size: 13, weight: .semibold))
                            Text(L("The selected text stays untouched until a verified replacement is ready."))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if model.tune.dictation.selectionEditingEnabled {
                    Picker(L("Selection edit model"),
                           selection: $model.tune.dictation.selectionEditProvider) {
                        Text("OpenAI").tag(Config.DictationSelectionEditProvider.openAI)
                        Text("DeepSeek").tag(Config.DictationSelectionEditProvider.deepSeek)
                    }
                    .pickerStyle(.menu)

                    HStack(spacing: 8) {
                        selectionEditStep("1", icon: "text.cursor",
                                          title: L("Select text"))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                        selectionEditStep("2", icon: "waveform",
                                          title: L("Speak instruction"))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                        selectionEditStep("3", icon: "checkmark.seal.fill",
                                          title: L("Release to replace"))
                    }
                    .padding(.vertical, 5)

                    Label(L("Accessibility is checked first. If a custom editor hides its selection, HyperVibe briefly probes Copy and restores your clipboard. Empty selections continue as ordinary dictation; read-only rewrites and failed replacements are copied."),
                          systemImage: "lock.shield.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(L("Selection Editing"))
            } footer: {
                Text(L("Select text, hold the side button, speak only the change you want, then release. Editable selections are replaced; readable read-only selections and failed replacements are copied. This works in Final and Live Voice without inserting the spoken instruction."))
            }
            .disabled(!model.tune.dictation.enabled)

            Section {
                credentialCard(
                    title: "OpenAI", subtitle: L("Required for transcription"),
                    icon: "waveform.badge.mic", tint: .green,
                    kind: .openAI, draft: $openAIKeyDraft,
                    hasKey: voiceCredentials.hasOpenAIKey,
                    state: voiceCredentials.openAIConnection
                )
                Divider()
                credentialCard(
                    title: "DeepSeek", subtitle: L("Used by DeepSeek text cleanup and selection editing"),
                    icon: "wand.and.stars", tint: .blue,
                    kind: .deepSeek, draft: $deepSeekKeyDraft,
                    hasKey: voiceCredentials.hasDeepSeekKey,
                    state: voiceCredentials.deepSeekConnection
                )
            } header: {
                Text(L("API Credentials"))
            } footer: {
                if voiceCredentials.storageBackend == .keychain {
                    Text(L("Keys are stored in the macOS Keychain with this-device-only protection. On first save, choose Always Allow once for HyperVibe's fixed credential helper; normal App updates will not ask again. Keys are never written to config.jsonc, logs, the app bundle, or Git."))
                } else if voiceCredentials.storageBackend == .localJSON {
                    Text(L("Keys are saved as plaintext in a current-user-only credentials.json file for this public beta. Only HyperVibe Settings provides a supported way to write it. Keys are never written to config.jsonc, logs, the app bundle, or Git."))
                } else {
                    Text(L("Checking local credential storage…"))
                }
            }

            Section {
                Toggle(isOn: $model.tune.dictation.autoInsert) {
                    rowLabel(L("Insert at the captured caret"), "text.cursor")
                }
                HStack(spacing: 10) {
                    rowLabel(L("Clipboard recovery after failed delivery"),
                             "doc.on.doc.fill")
                    Spacer()
                    Text(L("Always on"))
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.blue.opacity(0.11), in: Capsule())
                }
                Toggle(isOn: $model.tune.dictation.restoreClipboardAfterInsert) {
                    rowLabel(L("Restore clipboard after compatibility paste"), "clipboard")
                }
                Toggle(isOn: $model.tune.dictation.copyLastOnSideButtonDouble) {
                    rowLabel(L("Double-click side button to copy previous dictation"),
                             "rectangle.on.rectangle.angled")
                }
            } header: {
                Text(L("Delivery"))
            } footer: {
                Text(L("HyperVibe captures the frontmost app and focused editor before showing its HUD. It never types into a changed or secure target. Whenever generated text cannot be inserted or replaced, the complete result is placed on the clipboard."))
            }

            Section {
                Toggle(isOn: $model.tune.dictation.pipelineOverlayEnabled) {
                    rowLabel(L("Voice pipeline floating capsule"),
                             "waveform.path.ecg.rectangle.fill")
                }
            } header: {
                Text(L("Voice Presentation"))
            } footer: {
                Text(L("Final and Live show a temporary draggable capsule for audio and processing. External never opens the Voice capsule. Every native Voice turn begins at the lower centre of the display containing the pointer."))
            }

            Section {
                Toggle(isOn: $model.tune.dictation.feedbackSoundsEnabled) {
                    rowLabel(L("Voice start and stop sounds"), "speaker.wave.2.fill")
                }
                if model.tune.dictation.feedbackSoundsEnabled {
                    slider(icon: "speaker.wave.2.fill", title: L("Feedback volume"),
                           value: $model.tune.dictation.feedbackSoundVolume,
                           range: 0...1, minIcon: "speaker.wave.1", maxIcon: "speaker.wave.3",
                           display: { String(format: "%.0f%%", $0 * 100) })
                }
            } header: {
                Text(L("Voice Feedback"))
            } footer: {
                Text(L("The paired cues play only when native Voice actually opens and after audio capture has closed. Mode switching itself is always silent, and External keeps its configured feedback behavior."))
            }

            Section {
                if model.tune.dictation.dictionary.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "text.book.closed")
                            .foregroundStyle(.secondary)
                        Text(L("No custom terms yet"))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(model.tune.dictation.dictionary.indices, id: \.self) { index in
                        HStack(spacing: 13) {
                            Image(systemName: "text.book.closed.fill")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.tint)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Color.accentColor.opacity(0.10)))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.tune.dictation.dictionary[index].term)
                                    .font(.system(size: 13, weight: .semibold))
                                    .textSelection(.enabled)
                                Text(dictionaryAliasSummary(index))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 18)
                            Button(L("Edit")) { editDictionaryTerm(index) }
                                .buttonStyle(.borderless)
                            Button(role: .destructive) {
                                removeDictionaryTerm(index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help(L("Remove dictionary term"))
                        }
                        .padding(.vertical, 4)
                    }
                }
                Button {
                    dictionaryEditor = .init(index: nil, term: "", aliases: [])
                } label: {
                    Label(L("Add dictionary term"), systemImage: "plus")
                }
                .disabled(model.tune.dictation.dictionary.count >= 500)
            } header: {
                Text(L("Personal Dictionary"))
            } footer: {
                Text(L("Canonical spellings are sent as transcription hints. Aliases are also corrected locally in Final mode, longest match first."))
            }

            Section {
                TextField(L("Language hints (comma separated)"), text: languageHintsBinding)
                    .textFieldStyle(.roundedBorder)
                slider(icon: "timer.circle", title: L("Minimum recording"),
                       value: $model.tune.dictation.minimumRecordingSeconds,
                       range: 0...5, minIcon: "xmark.circle", maxIcon: "5.circle",
                       display: { $0 < 0.05 ? L("Off") : String(format: "%.1fs", $0) })
                slider(icon: "timer", title: L("Maximum recording"),
                       value: $model.tune.dictation.maxRecordingSeconds,
                       range: 15...600, minIcon: "15.circle", maxIcon: "10.circle",
                       display: { String(format: "%.0fs", $0) })

                DisclosureGroup(L("Model settings")) {
                    VStack(spacing: 10) {
                        LabeledContent(L("Final transcription")) {
                            TextField("gpt-transcribe",
                                      text: $model.tune.dictation.finalModel)
                                .textFieldStyle(.roundedBorder).frame(width: 280)
                        }
                        LabeledContent(L("Streaming transcription")) {
                            TextField("gpt-live-transcribe",
                                      text: $model.tune.dictation.streamingModel)
                                .textFieldStyle(.roundedBorder).frame(width: 280)
                        }
                        LabeledContent(L("OpenAI text processing")) {
                            TextField("gpt-5.6-luna",
                                      text: $model.tune.dictation.openAICleanupModel)
                                .textFieldStyle(.roundedBorder).frame(width: 280)
                        }
                        LabeledContent(L("DeepSeek text processing")) {
                            TextField("deepseek-v4-flash",
                                      text: $model.tune.dictation.deepSeekCleanupModel)
                                .textFieldStyle(.roundedBorder).frame(width: 280)
                        }
                    }
                    .padding(.top, 8)
                }
            } header: {
                Text(L("Advanced"))
            } footer: {
                Text(L("Turns shorter than the minimum stay on this Mac, produce no transcript, and close immediately. Live output begins only after the gate is reached."))
            }

            Section {
                HStack(spacing: 9) {
                    Circle()
                        .fill(voicePhaseColor)
                        .frame(width: 8, height: 8)
                    Text(voiceRuntime.lastMessage.isEmpty
                         ? L("Ready") : voiceRuntime.lastMessage)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(voiceRuntime.phase.rawValue.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                latencyGrid(voiceRuntime.lastMetrics)
            } header: {
                Text(L("Last-run Latency"))
            } footer: {
                Text(L("Measurements are kept in memory only and reset when HyperVibe quits. Transcript text is never shown in diagnostics."))
            }
        }
        .formStyle(.grouped)
        .animation(.easeInOut(duration: 0.18), value: model.tune.dictation.activeMode)
    }

    private var voiceUsesFinalMode: Bool {
        model.tune.dictation.activeMode == .final
    }

    private var voiceModeBinding: Binding<Config.DictationMode> {
        Binding(
            get: { model.tune.dictation.activeMode },
            set: { value in
                var tune = model.tune
                tune.dictation.selectMode(value)
                model.tune = tune
            }
        )
    }

    private func voiceModeCard(selected: Bool, icon: String, tint: Color,
                               title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(selected ? tint.opacity(0.10) : Color.secondary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(selected ? tint.opacity(0.30) : Color.clear, lineWidth: 1))
    }

    private func selectionEditStep(_ number: String, icon: String,
                                   title: String) -> some View {
        HStack(spacing: 7) {
            Text(number)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.indigo))
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.indigo)
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.indigo.opacity(0.07)))
    }

    private func credentialCard(title: String, subtitle: String, icon: String, tint: Color,
                                kind: VoiceCredentialKind, draft: Binding<String>,
                                hasKey: Bool, state: VoiceCredentialConnectionState) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(tint).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                credentialStateLabel(hasKey: hasKey, state: state)
            }
            HStack(spacing: 8) {
                SecureField(hasKey ? L("Enter a replacement key") : L("Paste API key"),
                            text: draft)
                    .textFieldStyle(.roundedBorder)
                Button(L("Save")) {
                    voiceCredentials.save(draft.wrappedValue, kind: kind) { error in
                        if let error { credentialError = error }
                        else { draft.wrappedValue = "" }
                    }
                }
                .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || state == .loading || state == .saving || state == .testing)
                Button(L("Test")) { voiceCredentials.test(kind) }
                    .disabled(!hasKey || state == .loading || state == .saving || state == .testing)
                if hasKey {
                    Button(role: .destructive) {
                        voiceCredentials.remove(kind) { error in
                            if let error { credentialError = error }
                        }
                    } label: { Image(systemName: "trash") }
                    .disabled(state == .loading || state == .saving || state == .testing)
                }
            }
            if case .invalid(let message) = state {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(message)
                        .font(.system(size: 10.5, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.red)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 5)
    }

    private func credentialStateLabel(hasKey: Bool,
                                      state: VoiceCredentialConnectionState) -> some View {
        let value: (String, String, Color)
        switch state {
        case .loading:
            value = ("arrow.triangle.2.circlepath", L("Loading…"), .secondary)
        case .saving:
            value = ("key.fill", L("Saving…"), .orange)
        case .idle:
            value = hasKey ? ("checkmark.seal.fill", L("Saved"), .green)
                           : ("key.slash", L("Not saved"), .secondary)
        case .testing:
            value = ("arrow.triangle.2.circlepath", L("Testing…"), .orange)
        case .valid:
            value = ("checkmark.circle.fill", L("Connected"), .green)
        case .invalid:
            value = ("exclamationmark.triangle.fill", L("Test failed"), .red)
        }
        return Label(value.1, systemImage: value.0)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(value.2)
    }

    private var voicePhaseColor: Color {
        switch voiceRuntime.phase {
        case .idle, .inserted, .replaced: return .green
        case .priming, .transcribing, .polishing, .rewriting, .inserting: return .orange
        case .listening: return .red
        case .copied: return .blue
        case .error: return .red
        }
    }

    private func latencyGrid(_ metrics: VoiceLatencyMetrics) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 6) {
            GridRow {
                latencyCell(L("First audio"), metrics.pressToFirstAudioMilliseconds)
                latencyCell(L("Session ready"), metrics.pressToSessionReadyMilliseconds)
                latencyCell(L("First live text"), metrics.pressToFirstDeltaMilliseconds)
            }
            GridRow {
                latencyCell(L("Release → transcript"), metrics.releaseToTranscriptMilliseconds)
                latencyCell(L("Cleanup"), metrics.cleanupMilliseconds)
                latencyCell(L("Insertion"), metrics.insertionMilliseconds)
            }
        }
        .padding(.vertical, 5)
    }

    private func latencyCell(_ title: String, _ milliseconds: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(milliseconds.map { String(format: "%.0f ms", $0) } ?? "—")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var languageHintsBinding: Binding<String> {
        Binding(
            get: { model.tune.dictation.languageHints.joined(separator: ", ") },
            set: { value in
                var tune = model.tune
                var seen = Set<String>()
                tune.dictation.languageHints = value.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }.filter { !$0.isEmpty && seen.insert($0).inserted }
                model.tune = tune
            }
        )
    }

    private func dictionaryAliasSummary(_ index: Int) -> String {
        guard model.tune.dictation.dictionary.indices.contains(index) else { return "" }
        let aliases = model.tune.dictation.dictionary[index].aliases
        return aliases.isEmpty ? L("No spoken aliases") : aliases.joined(separator: "  ·  ")
    }

    private func editDictionaryTerm(_ index: Int) {
        guard model.tune.dictation.dictionary.indices.contains(index) else { return }
        let entry = model.tune.dictation.dictionary[index]
        dictionaryEditor = .init(index: index, term: entry.term, aliases: entry.aliases)
    }

    private func saveDictionaryTerm(_ index: Int?, term: String, aliases: [String]) {
        var tune = model.tune
        let entry = Config.DictationTerm(term: term, aliases: aliases)
        if let index {
            guard tune.dictation.dictionary.indices.contains(index) else { return }
            tune.dictation.dictionary[index] = entry
        } else {
            guard tune.dictation.dictionary.count < 500 else { return }
            tune.dictation.dictionary.append(entry)
        }
        model.tune = tune
    }

    private func removeDictionaryTerm(_ index: Int) {
        guard model.tune.dictation.dictionary.indices.contains(index) else { return }
        var tune = model.tune
        tune.dictation.dictionary.remove(at: index)
        model.tune = tune
    }

    private var curveRelationshipSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.accentColor.opacity(0.11)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Acceleration Curves"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(model.tune.accelerationCurvesLinked
                         ? L("Pointer and ring share the same curve shape.")
                         : L("Pointer and ring are tuned independently."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                shapeLockButton
            }
            .padding(.vertical, 5)
        } footer: {
            Text(L("Each graph is a complete editor. Drag either endpoint to set its slow and fast range; drag the middle point to shape the acceleration."))
        }
    }

    private var pointerMovementSection: some View {
        Section {
            curvePanel(title: L("Pointer Movement"),
                       subtitle: L("Finger velocity → pointer gain"),
                       icon: "cursorarrow.motionlines",
                       accent: .blue,
                       target: .pointer)

            DisclosureGroup {
                VStack(spacing: 13) {
                    slider(icon: "cursorarrow.motionlines", title: L("Base speed"),
                           value: $model.tune.cursorSpeed, range: 0.1...3.0,
                           minIcon: "tortoise.fill", maxIcon: "hare.fill",
                           display: { String(format: "%.2f×", $0) })
                    slider(icon: "hand.raised.fill", title: L("Steadiness"),
                           value: $model.tune.cursorDeadzone, range: 0.0...0.02,
                           minIcon: "scribble.variable", maxIcon: "hand.raised.fill",
                           display: { String(format: "%.0f", $0 * 1000) })
                    slider(icon: "tortoise.fill", title: L("Slow-move gain"),
                           value: $model.tune.accelMin, range: 0.05...2.0,
                           minIcon: "tortoise.fill", maxIcon: "cursorarrow.motionlines",
                           display: { String(format: "%.2f×", $0) })
                    slider(icon: "hare.fill", title: L("Fast-move gain"),
                           value: $model.tune.accelMax, range: 0.5...8.0,
                           minIcon: "cursorarrow.motionlines", maxIcon: "hare.fill",
                           display: { String(format: "%.2f×", $0) })
                    slider(icon: "arrow.down.forward", title: L("Slow threshold"),
                           value: $model.tune.accelLowSpeed, range: 0.001...0.05,
                           minIcon: "tortoise.fill", maxIcon: "hare.fill",
                           display: { String(format: "%.0f", $0 * 1000) })
                    slider(icon: "arrow.up.forward", title: L("Fast threshold"),
                           value: $model.tune.accelHighSpeed, range: 0.01...0.14,
                           minIcon: "tortoise.fill", maxIcon: "hare.fill",
                           display: { String(format: "%.0f", $0 * 1000) })
                    slider(icon: "point.topleft.down.curvedto.point.bottomright.up",
                           title: L("Curve shape"), value: curveBinding(for: .pointer),
                           range: 0.35...4.0, minIcon: "arrow.up.right",
                           maxIcon: "arrow.turn.up.right",
                           display: { String(format: "%.2f", $0) })

                    Divider()
                    Toggle(isOn: $model.tune.findCursorEnabled) {
                        rowLabel(L("Find cursor on shake"), "cursorarrow.rays")
                    }
                    Toggle(isOn: $model.tune.focusFollowsCursor) {
                        rowLabel(L("Focus app under cursor"), "macwindow.on.rectangle")
                    }
                }
                .padding(.top, 9)
            } label: {
                Label(L("Pointer fine tuning"), systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium))
            }
        } header: {
            Text(L("Pointer Movement"))
        } footer: {
            Text(L("Only these controls affect pointer movement. Changes apply live while you drag the graph or a slider."))
        }
    }

    private var circularMovementSection: some View {
        Section {
            Toggle(isOn: $model.tune.circularEnabled) {
                rowLabel(L("Enable ring scrolling"), "arrow.clockwise")
            }

            if model.tune.circularEnabled {
                curvePanel(title: L("Ring Scrolling"),
                           subtitle: L("Ring rotation → scroll gain"),
                           icon: "arrow.clockwise",
                           accent: .orange,
                           target: .circular)

                DisclosureGroup {
                    VStack(spacing: 13) {
                        slider(icon: "circle.dashed", title: L("Outer ring only"),
                               value: $model.tune.circularMinRadius, range: 0.15...0.45,
                               minIcon: "smallcircle.filled.circle.fill", maxIcon: "circle",
                               display: { String(format: "%.0f%%", $0 * 100) })
                        slider(icon: "timer", title: L("Start resistance"),
                               value: $model.tune.circularStartThreshold, range: 0.1...1.5,
                               minIcon: "hare.fill", maxIcon: "tortoise.fill",
                               display: { String(format: "%.0f°", $0 * 180 / .pi) })
                        slider(icon: "speedometer", title: L("Base scroll speed"),
                               value: $model.tune.circularPixelsPerRadian, range: 40...600,
                               minIcon: "tortoise.fill", maxIcon: "hare.fill",
                               display: { String(format: "%.0f", $0) })
                        slider(icon: "wind", title: L("Smoothness"),
                               value: $model.tune.circularScrollEase, range: 0.1...0.6,
                               minIcon: "tortoise.fill", maxIcon: "hare.fill",
                               display: { String(format: "%.2f", $0) })
                        slider(icon: "tortoise.fill", title: L("Slow-scroll gain"),
                               value: $model.tune.circularAccelMin, range: 0.05...2.0,
                               minIcon: "minus", maxIcon: "plus",
                               display: { String(format: "%.2f×", $0) })
                        slider(icon: "hare.fill", title: L("Fast-scroll gain"),
                               value: $model.tune.circularAccelMax, range: 0.5...6.0,
                               minIcon: "minus", maxIcon: "plus",
                               display: { String(format: "%.2f×", $0) })
                        slider(icon: "arrow.down.forward", title: L("Slow threshold"),
                               value: $model.tune.circularAccelLowSpeed, range: 0.001...0.05,
                               minIcon: "tortoise.fill", maxIcon: "hare.fill",
                               display: { String(format: "%.0f", $0 * 1000) })
                        slider(icon: "arrow.up.forward", title: L("Fast threshold"),
                               value: $model.tune.circularAccelHighSpeed, range: 0.01...0.16,
                               minIcon: "tortoise.fill", maxIcon: "hare.fill",
                               display: { String(format: "%.0f", $0 * 1000) })
                        slider(icon: "point.topleft.down.curvedto.point.bottomright.up",
                               title: L("Curve shape"), value: curveBinding(for: .circular),
                               range: 0.35...4.0, minIcon: "arrow.up.right",
                               maxIcon: "arrow.turn.up.right",
                               display: { String(format: "%.2f", $0) })

                        Divider()
                        Toggle(isOn: $model.tune.circularInvert) {
                            rowLabel(L("Reverse direction"), "arrow.left.arrow.right")
                        }
                    }
                    .padding(.top, 9)
                } label: {
                    Label(L("Ring fine tuning"), systemImage: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                }
            }
        } header: {
            Text(L("Ring Scrolling"))
        } footer: {
            Text(L("Only these controls affect rotation around the outer ring. Pointer movement keeps its own independent curve above."))
        }
        .animation(.easeInOut(duration: 0.18), value: model.tune.circularEnabled)
    }

    private var generalSettingsIntro: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("General Settings"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(L("Click, button timing, on-screen feedback, startup and device information."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func curvePanel(title: String, subtitle: String, icon: String,
                            accent: Color, target: CurveTarget) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(target == .pointer ? L("POINTER") : L("SCROLL"))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(accent.opacity(0.12)))
            }

            if target == .pointer {
                AccelCurveView(
                    accelMin: $model.tune.accelMin,
                    accelMax: $model.tune.accelMax,
                    lowSpeed: $model.tune.accelLowSpeed,
                    highSpeed: $model.tune.accelHighSpeed,
                    curve: curveBinding(for: .pointer),
                    limits: .pointer,
                    accent: accent,
                    slowLabel: L("slow pointer"),
                    fastLabel: L("fast pointer"),
                    formatSpeed: { String(format: "%.0f", $0 * 1000) },
                    shapeLinked: model.tune.accelerationCurvesLinked,
                    onInteraction: { lastEditedCurve = .pointer })
            } else {
                AccelCurveView(
                    accelMin: $model.tune.circularAccelMin,
                    accelMax: $model.tune.circularAccelMax,
                    lowSpeed: $model.tune.circularAccelLowSpeed,
                    highSpeed: $model.tune.circularAccelHighSpeed,
                    curve: curveBinding(for: .circular),
                    limits: .circular,
                    accent: accent,
                    slowLabel: L("slow scroll"),
                    fastLabel: L("fast scroll"),
                    formatSpeed: { String(format: "%.0f", $0 * 1000) },
                    shapeLinked: model.tune.accelerationCurvesLinked,
                    onInteraction: { lastEditedCurve = .circular })
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(accent.opacity(0.16), lineWidth: 1)
        )
    }

    // MARK: - Tab switcher

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(Tab.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 330)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.68)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 50, height: 50)
                .overlay(
                    Image(systemName: "appletvremote.gen4.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                )
                .shadow(color: Color.accentColor.opacity(0.35), radius: 7, y: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text("siriRemote").font(.system(size: 19, weight: .semibold))
                Text(L("Touch & gesture tuning"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            tabPicker
            Spacer()
            saveStatusPill
            statusPill
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(.bar)
    }

    private var saveStatusPill: some View {
        let appearance: (icon: String, label: String, color: Color, error: String?)
        switch model.configSaveState {
        case .saving:
            appearance = ("arrow.triangle.2.circlepath", L("Saving…"), .secondary, nil)
        case .saved:
            appearance = ("checkmark.circle.fill", L("Auto-saved"), .green, nil)
        case .failed(let message):
            appearance = ("exclamationmark.triangle.fill", L("Save failed"), .red, message)
        }

        return Button {
            if let message = appearance.error { saveErrorDetail = message }
        } label: {
            HStack(spacing: 6) {
                if model.configSaveState == .saving {
                    ProgressView().controlSize(.mini).frame(width: 11, height: 11)
                } else {
                    Image(systemName: appearance.icon)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(appearance.color)
                }
                Text(appearance.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(appearance.error == nil ? .secondary : appearance.color)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(
                appearance.error == nil ? Color.secondary.opacity(0.10) : Color.red.opacity(0.10)
            ))
        }
        .buttonStyle(.plain)
        .help(appearance.error ?? L("GUI changes are saved automatically to config.jsonc."))
        .animation(.easeInOut(duration: 0.2), value: model.configSaveState)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.connected ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 7, height: 7)
            Text(model.connected ? L("Connected") : L("Waiting"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            if model.connected, let pct = device.battery {
                Divider().frame(height: 9)
                Image(systemName: batterySymbol(pct))
                    .font(.system(size: 11))
                    .foregroundStyle(batteryTint(pct))
                Text("\(pct)%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(.quaternary))
        .animation(.easeInOut(duration: 0.2), value: device.battery)
    }

    private func batterySymbol(_ pct: Int) -> String {
        switch pct {
        case ..<13:  return "battery.0percent"
        case ..<38:  return "battery.25percent"
        case ..<63:  return "battery.50percent"
        case ..<88:  return "battery.75percent"
        default:     return "battery.100percent"
        }
    }

    private func batteryTint(_ pct: Int) -> Color {
        pct < 20 ? .red : (pct < 40 ? .orange : .secondary)
    }

    // MARK: - Device

    private var deviceSection: some View {
        Section {
            if model.connected {
                if let pct = device.battery {
                    LabeledContent {
                        HStack(spacing: 6) {
                            Image(systemName: batterySymbol(pct)).foregroundStyle(batteryTint(pct))
                            Text("\(pct)%").monospacedDigit()
                        }
                    } label: { rowLabel(L("Battery"), "bolt.fill") }
                }
                if let fw = device.firmware {
                    LabeledContent {
                        Text(fw).monospacedDigit().foregroundStyle(.secondary)
                    } label: { rowLabel(L("Firmware"), "cpu") }
                }
                if let addr = device.address {
                    LabeledContent {
                        Text(addr)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } label: { rowLabel(L("Bluetooth address"), "dot.radiowaves.left.and.right") }
                }
                if let name = device.name {
                    LabeledContent {
                        Text(name)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } label: { rowLabel(L("Serial"), "number") }
                }
                if let vid = device.vendorID, let pid = device.productID {
                    LabeledContent {
                        Text("\(vid) / \(pid)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } label: { rowLabel(L("Vendor / Product"), "tag") }
                }
                if !device.interfaces.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(device.interfaces) { i in
                                HStack(spacing: 8) {
                                    Text(i.usageDescription)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 92, alignment: .leading)
                                    Text(i.label).font(.system(size: 11))
                                    Spacer()
                                    Text(L("in %d · feat %d", i.maxInput, i.maxFeature))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        rowLabel(L("HID interfaces (%d)", device.interfaces.count), "list.bullet.indent")
                    }
                }
            } else {
                Text(L("Remote not connected"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text(L("Device"))
                Spacer()
                Button {
                    device.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .disabled(device.refreshing)
                .help(L("Refresh device information"))
            }
        } footer: {
            Text(device.updatedAt == nil
                 ? L("The remote's microphone is not readable on macOS — see %@", "docs/mic-reverse-engineering.md")
                 : L("Battery and firmware come from the system Bluetooth stack. The microphone is not readable on macOS."))
                .font(.system(size: 11))
        }
    }

    // MARK: - Sections

    private var clickSection: some View {
        Section {
            slider(icon: "hand.tap.fill", title: L("Press sensitivity"),
                   value: $model.tune.clickRiseThreshold, range: 0.04...0.25,
                   minIcon: "hare.fill", maxIcon: "tortoise.fill",
                   display: { String(format: "%.2f", $0) })
            slider(icon: "arrow.up.and.down.and.arrow.left.and.right", title: L("Move tolerance"),
                   value: $model.tune.pressMoveMax, range: 0.01...0.06,
                   minIcon: "smallcircle.filled.circle.fill", maxIcon: "circle",
                   display: { String(format: "%.3f", $0) })
        } header: {
            Text(L("Click"))
        } footer: {
            Text(L("Pressing to click freezes the cursor so it doesn't drift. Lower sensitivity freezes more readily; higher move tolerance keeps it from feeling stuck."))
        }
    }

    private var buttonsSection: some View {
        Section {
            slider(icon: "clock", title: L("Long-press time"),
                   value: $model.tune.holdThreshold, range: 0.2...1.2,
                   minIcon: "hare.fill", maxIcon: "tortoise.fill",
                   display: { String(format: "%.1fs", $0) })
            slider(icon: "hand.tap.fill", title: L("Double-tap speed"),
                   value: $model.tune.doubleTapWindow, range: 0.15...0.6,
                   minIcon: "hare.fill", maxIcon: "tortoise.fill",
                   display: { String(format: "%.2fs", $0) })
            slider(icon: "rectangle.on.rectangle", title: L("Spaces Mode timeout"),
                   value: $model.tune.spacesModeWindow, range: 2.0...15.0,
                   minIcon: "hare.fill", maxIcon: "tortoise.fill",
                   display: { String(format: "%.0fs", $0) })
        } header: {
            Text(L("Buttons"))
        } footer: {
            Text(L("Long-press time: how long to hold a button before its \u{201C}.hold\u{201D} fires. Double-tap speed: the window for a second tap to trigger a \u{201C}.double\u{201D} binding instead of a second single press. Spaces Mode timeout: after long-pressing ring-up to arm desktop switching, how long without a left/right switch before it disarms."))
        }
    }

    /// Shape is the dimensionless exponent only. End gains, thresholds, and the two base-speed
    /// controls never cross the link because pointer delta/frame and ring radians/frame are not
    /// interchangeable units.
    private func curveBinding(for target: CurveTarget) -> Binding<Double> {
        Binding(
            get: {
                switch target {
                case .pointer: return model.tune.accelCurve
                case .circular: return model.tune.circularAccelCurve
                }
            },
            set: { newValue in
                lastEditedCurve = target
                var tune = model.tune
                switch target {
                case .pointer: tune.accelCurve = newValue
                case .circular: tune.circularAccelCurve = newValue
                }
                if tune.accelerationCurvesLinked {
                    tune.accelCurve = newValue
                    tune.circularAccelCurve = newValue
                }
                model.tune = tune
            }
        )
    }

    private var shapeLockButton: some View {
        Button {
            var tune = model.tune
            let shouldLink = !tune.accelerationCurvesLinked
            if shouldLink {
                // Closing the lock uses the last graph the user touched as the source, so enabling
                // it never unexpectedly destroys the curve they just finished shaping.
                let source = lastEditedCurve == .pointer ? tune.accelCurve : tune.circularAccelCurve
                tune.accelCurve = source
                tune.circularAccelCurve = source
            }
            tune.accelerationCurvesLinked = shouldLink
            model.tune = tune
        } label: {
            Label(model.tune.accelerationCurvesLinked ? L("Locked") : L("Independent"),
                  systemImage: model.tune.accelerationCurvesLinked ? "lock.fill" : "lock.open")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(model.tune.accelerationCurvesLinked ? .accentColor : .secondary)
        .help(model.tune.accelerationCurvesLinked
              ? L("Pointer and scroll use the same normalised curve shape. Click to edit independently.")
              : L("Click to lock both normalised curve shapes. Numeric speed and gain ranges stay independent."))
    }

    private var startupSection: some View {
        Section {
            Toggle(isOn: $model.tune.launchAtLoginEnabled) {
                rowLabel(L("Start at login"), "arrow.up.forward.app")
            }
            .disabled(LaunchAtLogin.state == .unavailable)
            Toggle(isOn: $model.tune.showSetupWizardOnFirstLaunch) {
                rowLabel(L("Show setup guide on first launch"), "checklist")
            }
            Button {
                NotificationCenter.default.post(name: .hyperVibeOpenSystemCheck, object: nil)
            } label: {
                HStack {
                    rowLabel(L("Open System Check…"), "checkmark.shield")
                    Spacer()
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text(L("Startup"))
        } footer: {
            Text(model.launchAtLoginError.map { L("Couldn't change it: %@", $0) }
                 ?? LaunchAtLogin.note
                 ?? L("Startup choices are stored in config.jsonc. Launch at login is also listed under System Settings → General → Login Items."))
                .font(.system(size: 11))
                .foregroundStyle(model.launchAtLoginError == nil ? Color.secondary : Color.red)
        }
    }

    private var widgetSection: some View {
        Section {
            Toggle(isOn: $model.tune.menuBarIconEnabled) {
                rowLabel(L("Menu bar icon"), "menubar.rectangle")
            }
            Toggle(isOn: $model.tune.statusWidgetEnabled) {
                rowLabel(L("Always-on status widget"), "rectangle.on.rectangle")
            }
            Toggle(isOn: $model.tune.demoRemoteEnabled) {
                rowLabel(L("Floating demo remote"), "appletvremote.gen4.fill")
            }
            Toggle(isOn: $model.tune.layerHUDEnabled) {
                rowLabel(L("Layer and connection HUD"), "square.stack.3d.up")
            }
            Toggle(isOn: $model.tune.holdHUDEnabled) {
                rowLabel(L("Long-press progress HUD"), "wave.3.right.circle.fill")
            }
            Toggle(isOn: $model.tune.dragIndicatorEnabled) {
                rowLabel(L("Sticky-drag indicator"), "hand.draw.fill")
            }
        } header: {
            Text(L("On-screen Status"))
        } footer: {
            Text(L("Every persistent or transient status surface can be enabled independently here or in config.jsonc."))
        }
    }

    private var updatesSection: some View {
        Section {
            Toggle(isOn: $model.tune.automaticUpdateChecksEnabled) {
                rowLabel(L("Automatically check for updates"), "arrow.triangle.2.circlepath")
            }
            Toggle(isOn: $model.tune.automaticallyDownloadUpdatesEnabled) {
                rowLabel(L("Automatically download updates"), "arrow.down.circle")
            }
            .disabled(!model.tune.automaticUpdateChecksEnabled)
            Button {
                model.onCheckForUpdates?()
            } label: {
                HStack {
                    rowLabel(
                        model.availableUpdateVersion.map { L("Update %@ Available…", $0) }
                            ?? L("Check for Updates…"),
                        model.availableUpdateVersion == nil ? "sparkles" : "arrow.down.circle.fill"
                    )
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tint(model.availableUpdateVersion == nil ? .accentColor : .green)
        } header: {
            Text(L("Software Updates"))
        } footer: {
            Text(L("Verified Full Setup updates download in the background. macOS asks for administrator approval only when an update installs system components."))
                .font(.system(size: 11))
        }
    }

    private var languageSection: some View {
        Section {
            Picker(selection: Binding(
                get: { AppLanguage(rawValue: model.tune.interfaceLanguage) ?? .english },
                set: { model.tune.interfaceLanguage = $0.rawValue }
            )) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            } label: {
                rowLabel(L("Interface language"), "globe")
            }
            .pickerStyle(.menu)
        } header: {
            Text(L("Language"))
        } footer: {
            Text(L("The whole app switches immediately — no relaunch needed."))
                .font(.system(size: 11))
        }
    }

    private var footerSection: some View {
        Section {
            Button(role: .destructive) {
                withAnimation { model.resetToDefaults() }
            } label: {
                rowLabel(L("Reset to defaults"), "arrow.counterclockwise")
            }
        } footer: {
            Text(L("Button, ring, and swipe mappings live in %@", "~/.config/siriremote/config.jsonc"))
                .font(.system(size: 11))
        }
    }

    // MARK: - Reusable rows

    private func rowLabel(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 18)
            Text(title).font(.system(size: 13))
        }
    }

    private func slider(icon: String, title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, minIcon: String, maxIcon: String,
                        display: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                rowLabel(title, icon)
                Spacer()
                Text(display(value.wrappedValue))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 9) {
                Image(systemName: minIcon).font(.system(size: 11)).foregroundStyle(.tertiary)
                Slider(value: value, in: range)
                Image(systemName: maxIcon).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

/// A draft-first editor keeps partially typed text out of the live JSON. The previous inline fields
/// saved on every keystroke, so an empty intermediate value or a duplicated placeholder could make
/// an otherwise healthy config temporarily invalid. Save now performs one normalized transaction.
private struct DictionaryTermEditor: View {
    let request: DictionaryEditorRequest
    let existingTerms: [String]
    let onSave: (String, [String]) -> Void
    let onCancel: () -> Void

    @State private var term: String
    @State private var aliasesText: String
    @FocusState private var termFocused: Bool

    init(request: DictionaryEditorRequest, existingTerms: [String],
         onSave: @escaping (String, [String]) -> Void, onCancel: @escaping () -> Void) {
        self.request = request
        self.existingTerms = existingTerms
        self.onSave = onSave
        self.onCancel = onCancel
        _term = State(initialValue: request.term)
        _aliasesText = State(initialValue: request.aliases.joined(separator: ", "))
    }

    private var canonicalTerm: String {
        term.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicate: Bool {
        existingTerms.contains { $0.caseInsensitiveCompare(canonicalTerm) == .orderedSame }
    }

    private var aliases: [String] {
        var seen = Set<String>()
        return aliasesText.split(whereSeparator: { character in
            character == "," || character == "，" || character == ";"
                || character == "；" || character.isNewline
        }).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter {
            !$0.isEmpty
                && $0.caseInsensitiveCompare(canonicalTerm) != .orderedSame
                && seen.insert($0.lowercased()).inserted
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "text.book.closed.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.accentColor.opacity(0.11)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(request.index == nil ? "Add dictionary term" : "Edit dictionary term"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(L("Teach Voice the exact spelling of names and specialist terms."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(22)

            Divider()

            Form {
                LabeledContent(L("Canonical spelling")) {
                    TextField("SIGMOD", text: $term)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 340)
                        .focused($termFocused)
                }
                LabeledContent(L("Spoken aliases")) {
                    TextField(L("Optional; separate with commas or new lines"), text: $aliasesText,
                              axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        .frame(width: 340)
                }
                if isDuplicate {
                    Label(L("That canonical spelling is already in your dictionary."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Text(L("Saved automatically to config.jsonc"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(L(request.index == nil ? "Add" : "Save")) {
                    onSave(canonicalTerm, aliases)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(canonicalTerm.isEmpty || canonicalTerm.contains("\n")
                          || canonicalTerm.contains("\r") || isDuplicate)
            }
            .padding(18)
        }
        .frame(width: 620, height: 410)
        .onAppear { termFocused = true }
    }
}

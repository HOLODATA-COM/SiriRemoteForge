//
//  main.swift
//  HyperVibe
//
//  Application entry point
//

import AppKit

// Explicit maintenance command for merging personal recognition terms through ConfigStore's
// validated, atomic writer. It preserves every unrelated setting/binding and creates the normal
// one-level .bak before changing the user's config.
if let index = CommandLine.arguments.firstIndex(of: "--add-voice-dictionary-terms") {
    let requested = CommandLine.arguments.dropFirst(index + 1).map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    guard !requested.isEmpty else {
        print("VOICE_DICTIONARY_UPDATE FAIL no terms supplied")
        exit(2)
    }
    let current = ConfigStore.loadConfig()
    var added: [String] = []
    let updated = current.withSettingsUpdated { settings in
        var known = Set(settings.dictation.dictionary.map { $0.term.lowercased() })
        for term in requested where known.insert(term.lowercased()).inserted {
            settings.dictation.dictionary.append(Config.DictationTerm(term: term))
            added.append(term)
        }
    }
    do {
        if updated != current { try ConfigStore.save(updated) }
        print("VOICE_DICTIONARY_UPDATE PASS added=\(added.joined(separator: ","))")
        exit(0)
    } catch {
        print("VOICE_DICTIONARY_UPDATE FAIL \(error.localizedDescription)")
        exit(1)
    }
}

// Local verification executes beside the one production UI process and never starts the delegate,
// remote seizure, input hooks or TCC checks. It creates a prohibited NSApplication only because the
// icon audit intentionally resolves AppKit SF Symbols; AppKit aborts if that catalog is touched
// before application registration. Credential/API-only commands remain below NSApplication.
if CommandLine.arguments.contains("--test-voice-input") {
    let testApplication = NSApplication.shared
    testApplication.setActivationPolicy(.prohibited)
    Task { @MainActor in exit(await VoiceInputSelfTest.runLocal() ? 0 : 1) }
    dispatchMain()
}
if CommandLine.arguments.contains("--check-voice-keys") {
    exit(VoiceInputSelfTest.checkCredentialAvailability() ? 0 : 1)
}
if let index = CommandLine.arguments.firstIndex(of: "--test-voice-api"),
   index + 2 < CommandLine.arguments.count {
    let path = CommandLine.arguments[index + 1]
    let mode = CommandLine.arguments[index + 2]
    Task { exit(await VoiceInputSelfTest.runAPI(wavPath: path, mode: mode) ? 0 : 1) }
    dispatchMain()
}

// Create the application instance
let app = NSApplication.shared

// Create and set the delegate
let delegate = AppDelegate()
app.delegate = delegate

// Run the application
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)

//
//  main.swift
//  HyperVibe
//
//  Application entry point
//

import AppKit

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

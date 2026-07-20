//
//  AppWatcher.swift
//  HyperVibe (config engine integration)
//
//  Tracks the frontmost application and reports its bundle identifier so the
//  config engine can switch modes per-app.
//

import AppKit

final class AppWatcher {
    private let onChange: (String) -> Void
    private var token: NSObjectProtocol?

    init(onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            onChange(id)
        }
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let id = app?.bundleIdentifier { self?.onChange(id) }
        }
    }

    deinit {
        if let token = token {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }
}

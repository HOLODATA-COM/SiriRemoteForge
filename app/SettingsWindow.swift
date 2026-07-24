//
//  SettingsWindow.swift
//  HyperVibe (settings UI)
//
//  Hosts the SwiftUI SettingsView in a clean, borderless-title window from the menu-bar app.
//

import AppKit
import SwiftUI

final class SettingsWindowController {
    private var window: NSWindow?
    private let model: SettingsModel
    private var closeObserver: NSObjectProtocol?

    init(model: SettingsModel) { self.model = model }

    deinit {
        if let obs = closeObserver { NotificationCenter.default.removeObserver(obs) }
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            // Track the SwiftUI content's fitting size so the window grows/shrinks when the
            // Layout tab (wider) is selected vs. the Tuning tab.
            hosting.sizingOptions = [.preferredContentSize]
            let win = NSWindow(contentViewController: hosting)
            win.title = "siriRemote Settings"
            win.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.isMovableByWindowBackground = true
            win.isReleasedWhenClosed = false
            win.contentMinSize = NSSize(width: 452, height: 480)
            win.center()
            // Don't open taller than the screen (a 13" display has ~900pt usable).
            if let vis = win.screen?.visibleFrame ?? NSScreen.main?.visibleFrame,
               win.frame.height > vis.height {
                win.setContentSize(NSSize(width: win.frame.width, height: vis.height - 40))
                win.center()
            }
            // Stop the device polling when the window closes. The window is cached
            // (`isReleasedWhenClosed = false`), so closing only orders it out and SwiftUI's
            // `.onDisappear` does not run — without this the 60s `system_profiler` poll would keep
            // going for the rest of the app's uptime with nothing on screen to show it.
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: win, queue: .main
            ) { [weak self] _ in
                self?.model.device.stop()
            }

            window = win
        }
        model.device.start()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

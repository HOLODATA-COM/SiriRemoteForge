//
//  MenuBarManager.swift
//  siriRemote
//
//  The menu-bar status item: a drawn walkie-talkie icon, a connection-status line, and
//  Settings… / Quit. All button / ring / gesture mapping lives in Settings → Layout, driven by
//  the config engine — there are no mapping submenus here.
//

import AppKit

/// Trackpad two-finger scroll speed → pixels-per-unit scale (used by TouchHandler).
enum ScrollSpeed: String, CaseIterable {
    case slow = "Slow"
    case medium = "Medium"
    case fast = "Fast"

    var scale: CGFloat {
        switch self {
        case .slow:   return 150.0
        case .medium: return 300.0
        case .fast:   return 500.0
        }
    }
}

final class MenuBarManager {

    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let statusMenuItem: NSMenuItem

    /// Two-finger scroll scale (see `ScrollSpeed`).
    private(set) var scrollSpeed: ScrollSpeed = .medium

    /// Set by the AppDelegate to open the SwiftUI settings window.
    var onOpenSettings: (() -> Void)?

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        self.menu = NSMenu()
        self.statusMenuItem = NSMenuItem(title: "Status: Disconnected", action: nil, keyEquivalent: "")
        setupMenuBar()
    }

    // MARK: - Icon

    /// Procedurally draw the menu-bar icon — a walkie-talkie glyph (antenna + body with a display
    /// slot and a speaker hole, punched via even-odd fill). Template image, so it tints correctly.
    private static func makeWaveIcon() -> NSImage {
        let pt: CGFloat = 18
        let image = NSImage(size: NSSize(width: pt, height: pt), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width

            ctx.translateBy(x: s / 2, y: s / 2)
            ctx.scaleBy(x: 2, y: 2)
            ctx.translateBy(x: -s / 2, y: -s / 2)

            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

            let antenna = CGRect(x: 0.5260 * s, y: 0.1944 * s, width: 0.0638 * s, height: 0.1594 * s)
            let body    = CGRect(x: 0.3348 * s, y: 0.3538 * s, width: 0.3187 * s, height: 0.4462 * s)
            let display = CGRect(x: 0.3986 * s, y: 0.6406 * s, width: 0.1911 * s, height: 0.0956 * s)
            let speakerR: CGFloat = 0.0956 * s
            let speaker = CGRect(x: 0.4942 * s - speakerR, y: 0.5131 * s - speakerR,
                                 width: 2 * speakerR, height: 2 * speakerR)

            let path = CGMutablePath()
            path.addPath(CGPath(roundedRect: antenna, cornerWidth: 0.0278 * s, cornerHeight: 0.0278 * s, transform: nil))
            path.addPath(CGPath(roundedRect: body,    cornerWidth: 0.0556 * s, cornerHeight: 0.0556 * s, transform: nil))
            path.addPath(CGPath(roundedRect: display, cornerWidth: 0.0278 * s, cornerHeight: 0.0278 * s, transform: nil))
            path.addEllipse(in: speaker)

            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Menu

    private func setupMenuBar() {
        guard let button = statusItem.button else { return }
        button.image = Self.makeWaveIcon()
        button.title = ""
        rebuildMenu()
        statusItem.menu = menu
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let titleItem = NSMenuItem(title: "siriRemote", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(.separator())
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func openSettings() { onOpenSettings?() }

    func updateConnectionStatus(connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusMenuItem.title = connected ? "Status: Connected ✓" : "Status: Disconnected"
            self.statusItem.button?.appearsDisabled = !connected
        }
    }

    @objc private func quitApp() {
        NSStatusBar.system.removeStatusItem(statusItem)
        NSApp.terminate(nil)
    }
}

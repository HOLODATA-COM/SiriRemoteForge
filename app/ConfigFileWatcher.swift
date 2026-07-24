//
//  ConfigFileWatcher.swift
//  HyperVibe (config engine integration)
//
//  Watches the config file and fires onChange when it is written/replaced, so the
//  engine can hot-reload. Re-arms after atomic saves (rename/delete).
//

import Foundation

final class ConfigFileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let url: URL
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
    }

    /// Debounces reloads so a half-written save is never parsed.
    private var pendingReload: DispatchWorkItem?

    private func start() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("[siriRemote] cannot watch \(url.path)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Re-arm immediately — atomic saves replace the inode, so the old descriptor is dead.
            self.source?.cancel()
            self.start()

            // Debounce the reload. The source fires on the FIRST write of a save, and editors that
            // write in place (several write() calls) or rename-then-recreate deliver an event while
            // the file is half-written or briefly missing. Parsing that yields the fallback config,
            // which has none of the user's modes — and the consumer reacts by clearing the active
            // sticky layer, leaving every binding dead until it is toggled again. Waiting for the
            // writes to settle means we only ever parse a complete file.
            self.pendingReload?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.pendingReload = nil
                self?.onChange()
            }
            self.pendingReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    deinit {
        pendingReload?.cancel()
        source?.cancel()
    }
}

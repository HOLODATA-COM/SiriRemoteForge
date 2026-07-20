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
            self.onChange()
            // Atomic saves replace the inode; cancel and re-arm on the new file.
            self.source?.cancel()
            self.start()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    deinit { source?.cancel() }
}

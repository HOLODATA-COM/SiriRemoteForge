//
//  PacketLoggerDropTarget.swift
//  HyperVibe
//
//  Narrow AppKit bridge for reliable Finder/Disk Image .app bundle drops.
//

import AppKit
import SwiftUI

struct PacketLoggerDropTarget: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onDrop: (URL) -> Void

    func makeNSView(context: Context) -> DropReceiverView {
        let view = DropReceiverView()
        view.onTargetChange = { targeted in
            DispatchQueue.main.async { isTargeted = targeted }
        }
        view.onDrop = { url in
            DispatchQueue.main.async { onDrop(url) }
        }
        return view
    }

    func updateNSView(_ nsView: DropReceiverView, context: Context) {
        nsView.onTargetChange = { targeted in
            DispatchQueue.main.async { isTargeted = targeted }
        }
        nsView.onDrop = { url in
            DispatchQueue.main.async { onDrop(url) }
        }
    }
}

final class DropReceiverView: NSView {
    var onTargetChange: ((Bool) -> Void)?
    var onDrop: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard firstFileURL(from: sender) != nil else { return [] }
        onTargetChange?(true)
        // Accept the drop first, then give a precise in-app explanation if the file is not
        // PacketLogger.app. Silently showing a forbidden cursor teaches the user nothing.
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        firstFileURL(from: sender) == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetChange?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargetChange?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { onTargetChange?(false) }
        guard let url = firstFileURL(from: sender) else { return false }
        onDrop?(url)
        return true
    }

    private func firstFileURL(from sender: NSDraggingInfo) -> URL? {
        guard let value = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )?.first as? URL else {
            return nil
        }
        return value
    }
}

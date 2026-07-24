import AppKit
import SystemExtensions

private let driverIdentifier = "com.hypervibe.SiriRemoteMicDriver"

final class DriverHostController: NSObject, NSApplicationDelegate, OSSystemExtensionRequestDelegate {
    private var window: NSWindow?
    private let statusLabel = NSTextField(wrappingLabelWithString: "Ready. No request has been submitted.")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 260),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Siri Remote Microphone Driver"
        window.center()

        let title = NSTextField(labelWithString: "Siri Remote microphone DriverKit host")
        title.font = .systemFont(ofSize: 18, weight: .semibold)

        let explanation = NSTextField(wrappingLabelWithString:
            "This host only submits a request after you press a button. Activation registers the " +
            "experimental DEXT; provider recreation or rematching may still be required before it " +
            "owns the audio interface. Deactivation may be deferred until restart."
        )
        explanation.textColor = .secondaryLabelColor

        let activateButton = NSButton(
            title: "Activate Driver",
            target: self,
            action: #selector(activateDriver)
        )
        activateButton.bezelStyle = .rounded

        let deactivateButton = NSButton(
            title: "Deactivate Driver",
            target: self,
            action: #selector(deactivateDriver)
        )
        deactivateButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [activateButton, deactivateButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        statusLabel.maximumNumberOfLines = 4
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.textColor = .labelColor

        let content = NSStackView(views: [title, explanation, buttons, statusLabel])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        content.translatesAutoresizingMaskIntoConstraints = false

        guard let contentView = window.contentView else {
            NSApp.terminate(nil)
            return
        }
        contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentView.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            explanation.widthAnchor.constraint(equalTo: content.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let embeddedDriver = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions")
            .appendingPathComponent("\(driverIdentifier).dext")
        if FileManager.default.fileExists(atPath: embeddedDriver.path) {
            updateStatus("Embedded DEXT found. Waiting for an explicit Activate or Deactivate click.")
        } else {
            updateStatus("Embedded DEXT is missing at \(embeddedDriver.path)")
        }

        let arguments = Set(CommandLine.arguments.dropFirst())
        if arguments.contains("--activate") && arguments.contains("--deactivate") {
            updateStatus("Choose only one automatic operation: --activate or --deactivate.")
        } else if arguments.contains("--activate") {
            DispatchQueue.main.async { [weak self] in self?.activateDriver() }
        } else if arguments.contains("--deactivate") {
            DispatchQueue.main.async { [weak self] in self?.deactivateDriver() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func activateDriver() {
        submit(
            OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: driverIdentifier,
                queue: .main
            ),
            operation: "activation"
        )
    }

    @objc private func deactivateDriver() {
        submit(
            OSSystemExtensionRequest.deactivationRequest(
                forExtensionWithIdentifier: driverIdentifier,
                queue: .main
            ),
            operation: "deactivation"
        )
    }

    private func submit(_ request: OSSystemExtensionRequest, operation: String) {
        request.delegate = self
        updateStatus("Submitting \(operation) request for \(driverIdentifier)…")
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension newExtension: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        updateStatus(
            "Replacing installed version \(existing.bundleVersion) with \(newExtension.bundleVersion)."
        )
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        updateStatus(
            "macOS requires approval in System Settings → General → " +
            "Login Items & Extensions → Drivers."
        )
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        switch result {
        case .completed:
            updateStatus("System-extension request completed.")
        case .willCompleteAfterReboot:
            updateStatus("System-extension request accepted and will complete after reboot.")
        @unknown default:
            updateStatus("System-extension request returned an unknown result: \(result.rawValue).")
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let diagnostic = error as NSError
        updateStatus(
            "System-extension request failed: domain=\(diagnostic.domain) " +
            "code=\(diagnostic.code) description=\(diagnostic.localizedDescription)"
        )
    }

    private func updateStatus(_ message: String) {
        statusLabel.stringValue = message
        NSLog("SiriRemoteMicHost: %@", message)
    }
}

let application = NSApplication.shared
let controller = DriverHostController()
application.setActivationPolicy(.regular)
application.delegate = controller
application.run()

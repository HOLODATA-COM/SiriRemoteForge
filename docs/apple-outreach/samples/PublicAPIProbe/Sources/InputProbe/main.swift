import Foundation
import GameController

private struct Options {
    var seconds: TimeInterval = 30
    var discover = false

    init(arguments: [String]) {
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--discover":
                discover = true
            case "--seconds" where index + 1 < arguments.count:
                index += 1
                if let value = Double(arguments[index]), value > 0, value <= 300 {
                    seconds = value
                }
            case "--help", "-h":
                print("Usage: InputProbe [--discover] [--seconds 1...300]")
                exit(EXIT_SUCCESS)
            default:
                fputs("InputProbe: unknown argument: \(arguments[index])\n", stderr)
                exit(EXIT_FAILURE)
            }
            index += 1
        }
    }
}

private let options = Options(arguments: CommandLine.arguments)
private var attachedControllers: [ObjectIdentifier: GCController] = [:]

private func timestamp() -> String {
    String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
}

private func elementName(_ element: GCControllerElement) -> String {
    if let name = element.localizedName, !name.isEmpty {
        return name
    }
    let aliases = element.aliases.sorted()
    return aliases.first ?? String(describing: type(of: element))
}

private func elementState(_ element: GCControllerElement) -> String {
    if let button = element as? GCControllerButtonInput {
        return String(format: "button value=%.4f pressed=%@", button.value, button.isPressed.description)
    }
    if let dpad = element as? GCControllerDirectionPad {
        return String(format: "dpad x=%.4f y=%.4f", dpad.xAxis.value, dpad.yAxis.value)
    }
    if let axis = element as? GCControllerAxisInput {
        return String(format: "axis value=%.4f", axis.value)
    }
    return "element changed"
}

private func attach(_ controller: GCController) {
    let identifier = ObjectIdentifier(controller)
    guard attachedControllers[identifier] == nil else { return }
    attachedControllers[identifier] = controller

    let vendor = controller.vendorName ?? "(no vendor name)"
    let profile = controller.physicalInputProfile
    print("[\(timestamp())] CONNECT vendor=\(vendor) category=\(controller.productCategory)")
    print("  microGamepad=\(controller.microGamepad != nil) elementCount=\(profile.elements.count)")

    for key in profile.elements.keys.sorted() {
        guard let element = profile.elements[key] else { continue }
        let aliases = element.aliases.sorted().joined(separator: ", ")
        print("  element key=\(key) type=\(type(of: element)) analog=\(element.isAnalog) aliases=[\(aliases)]")
    }

    profile.valueDidChangeHandler = { profile, element in
        let elapsed = profile.lastEventTimestamp
        print("[\(timestamp())] EVENT profileTime=\(String(format: "%.6f", elapsed)) name=\(elementName(element)) \(elementState(element))")
    }
}

private func scanControllers() {
    let current = GCController.controllers()
    let currentIDs = Set(current.map(ObjectIdentifier.init))

    for controller in current {
        attach(controller)
    }

    for identifier in attachedControllers.keys where !currentIDs.contains(identifier) {
        if let controller = attachedControllers.removeValue(forKey: identifier) {
            print("[\(timestamp())] DISCONNECT vendor=\(controller.vendorName ?? "(no vendor name)") category=\(controller.productCategory)")
        }
    }
}

print("HyperVibe InputProbe")
print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("duration=\(String(format: "%.1f", options.seconds))s discovery=\(options.discover)")

scanControllers()
let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
    scanControllers()
}

if options.discover {
    GCController.startWirelessControllerDiscovery {
        print("[\(timestamp())] Game Controller discovery callback completed")
        scanControllers()
    }
}

RunLoop.main.run(until: Date().addingTimeInterval(options.seconds))
timer.invalidate()
if options.discover {
    GCController.stopWirelessControllerDiscovery()
}
print("InputProbe complete; observedControllers=\(attachedControllers.count)")

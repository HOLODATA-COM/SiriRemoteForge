//
//  RemoteDetector.swift
//  HyperVibe
//
//  Detects Siri Remote via IOKit HID
//

import Foundation
import IOKit
import IOKit.hid

/// Append diagnostic line to /tmp/hypervibe.log (unified-log redacts NSLog under hardened runtime).
func rmDebug(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    if let data = line.data(using: .utf8) {
        let path = "/tmp/hypervibe.log"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// Tracks HID interfaces by their actual IOHID identity. One physical Siri Remote publishes
/// several interfaces, and two same-model remotes publish the same vendor/product pair, so neither
/// product IDs nor a single `currentDevice` can represent connection lifetime correctly.
struct RemoteInterfaceRegistry<Key: Hashable> {
    private(set) var interfaces: Set<Key> = []

    var count: Int { interfaces.count }
    var isConnected: Bool { !interfaces.isEmpty }

    @discardableResult
    mutating func add(_ key: Key) -> Bool {
        interfaces.insert(key).inserted
    }

    @discardableResult
    mutating func remove(_ key: Key) -> Bool {
        interfaces.remove(key) != nil
    }

    mutating func removeAll() {
        interfaces.removeAll()
    }
}

enum RemoteDeviceEvent {
    case added(IOHIDDevice, connectedInterfaceCount: Int)
    case removed(IOHIDDevice, remainingInterfaceCount: Int)
    case reset

    var isConnected: Bool {
        switch self {
        case .added: return true
        case let .removed(_, remainingInterfaceCount): return remainingInterfaceCount > 0
        case .reset: return false
        }
    }
}

class RemoteDetector {
    private var manager: IOHIDManager?
    private var deviceCallback: ((RemoteDeviceEvent) -> Void)?
    private var interfaceRegistry = RemoteInterfaceRegistry<IOHIDDevice>()
    
    private let appleVendorID: Int = 0x004C
    
    // Known Siri Remote / Apple TV Remote product IDs
    private let knownProductIDs: [Int] = [
        0x0221, 0x0255, 0x0266, 0x0267, 0x0269,
        0x0C4E, 0x0C4F, 0x030D, 0x030E,
        0x0315  // 3rd-gen Siri Remote (A2843, USB-C). HID name is the serial number,
                // not "Siri Remote", so it must be matched by product ID here.
    ]
    
    init(deviceCallback: @escaping (RemoteDeviceEvent) -> Void) {
        self.deviceCallback = deviceCallback
    }
    
    func startDetection() {
        rmDebug(String(format: "🛰 starting HID detection (vendor=0x%X)", appleVendorID))
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = manager else {
            rmDebug("⚠️ IOHIDManagerCreate returned nil")
            return
        }

        // SiriMote uses IOHIDManagerSetDeviceMatchingMultiple with per-interface dicts.
        // The Siri Remote A1513 exposes 3 HID interfaces (consumer, game controls, vendor),
        // and the singular variant with vendor-only matching does not enumerate them on
        // recent macOS BLE HID stacks.
        let matchingDicts: [[String: Any]] = [
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x0C],   // Consumer Page
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x0D],   // Digitizer / Game Controls
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0xFF00], // Apple vendor-defined
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x01],   // Generic Desktop (kept for keyboards/trackpads)
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x20],   // Gen-3 IR/radio + mic enable
        ]
        // Gen-3 exposes two additional HID-over-GATT report characteristics as usage-page 0x20
        // interfaces (AppleEmbeddedBluetoothInfrared / AppleEmbeddedBluetoothRadio). Native Voice
        // needs to retain them in normal operation because the gen-3 protocol requires the 0xAF
        // input-enable byte on every writable non-Input report. They remain non-exclusive in
        // RemoteInputHandler, so retaining them does not occupy the IR/radio services.
        //
        // Seizing them in normal mode was tried as a way to stop macOS seeing the Power button and
        // did NOT work — loginwindow still received it — so it is not worth occupying the IR/radio
        // interfaces. The power-button sleep is handled by the loginwindow preference instead.
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingDicts as CFArray)

        IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceAddedCallback, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemovedCallback, Unmanaged.passUnretained(self).toOpaque())

        // Startup is passive: never surprise the user with a TCC prompt before the setup screen has
        // explained why access is needed. The explicit request lives in SystemReadiness. Once the
        // user grants it, AppDelegate recreates this manager immediately — no relaunch required.
        if #available(macOS 10.15, *) {
            let granted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
                == kIOHIDAccessTypeGranted
            rmDebug("🔐 Input Monitoring access: " + (granted
                ? "granted"
                : "NOT granted — use HyperVibe → System Check to enable it"))
            guard granted else { return }
        }

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            rmDebug(String(format: "⚠️ IOHIDManagerOpen failed (IOReturn=0x%X) — likely Input Monitoring not granted", openResult))
            return
        }
        rmDebug("🛰 IOHIDManagerOpen success")

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.enumerateAllDevices()
        }
    }
    
    func stopDetection() {
        if let manager = manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
        }
        interfaceRegistry.removeAll()
        deviceCallback?(.reset)
    }
    
    private func enumerateAllDevices() {
        guard let manager = manager,
              let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            rmDebug("🛰 IOHIDManagerCopyDevices returned nil/empty (TCC block or matching mismatch)")
            return
        }
        rmDebug("🛰 enumeration found \(deviceSet.count) HID device(s) matching filter")
        for device in deviceSet {
            let v = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? -1
            let p = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? -1
            let n = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
            let pup = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
            let pu  = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
            rmDebug(String(format: "🛰 candidate vendor=0x%X product=0x%X usagePage=0x%X usage=0x%X name=%@",
                           v, p, pup, pu, n))
            if isSiriRemote(device) {
                handleDeviceAdded(device)
            }
        }
    }
    
    private func isSiriRemote(_ device: IOHIDDevice) -> Bool {
        guard let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int,
              vendorID == appleVendorID else { return false }
        
        if let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int,
           knownProductIDs.contains(productID) {
            return true
        }
        
        if let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String {
            let name = productName.lowercased()
            return name.contains("remote") || name.contains("siri") || name.contains("apple tv")
        }
        
        return false
    }
    
    func handleDeviceAdded(_ device: IOHIDDevice) {
        guard isSiriRemote(device) else { return }

        // IOHIDManager is scheduled on the main run loop, but keep the mutation explicitly on main
        // for callers such as tests/enumeration that may invoke this method from another thread.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.manager != nil,
                  self.interfaceRegistry.add(device) else { return }
            let vendorID = IOHIDDeviceGetProperty(
                device, kIOHIDVendorIDKey as CFString
            ) as? Int ?? 0
            let productID = IOHIDDeviceGetProperty(
                device, kIOHIDProductIDKey as CFString
            ) as? Int ?? 0
            let productName = IOHIDDeviceGetProperty(
                device, kIOHIDProductKey as CFString
            ) as? String ?? "Unknown"
            if self.interfaceRegistry.count == 1 {
                print("✅ Siri Remote connected: \(productName) (Vendor: 0x\(String(vendorID, radix: 16, uppercase: true)), Product: 0x\(String(productID, radix: 16, uppercase: true)))")
            }
            rmDebug("🛰 interface connected name=\(productName) activeInterfaces=\(self.interfaceRegistry.count)")
            self.deviceCallback?(.added(
                device, connectedInterfaceCount: self.interfaceRegistry.count
            ))
        }
    }
    
    func handleDeviceRemoved(_ device: IOHIDDevice) {
        guard isSiriRemote(device) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.interfaceRegistry.remove(device) else { return }
            let remaining = self.interfaceRegistry.count
            let productName = IOHIDDeviceGetProperty(
                device, kIOHIDProductKey as CFString
            ) as? String ?? "Unknown"
            rmDebug("🛰 interface disconnected name=\(productName) activeInterfaces=\(remaining)")
            self.deviceCallback?(.removed(device, remainingInterfaceCount: remaining))
            if remaining == 0 {
                print("❌ Siri Remote disconnected: \(productName)")
            }
        }
    }
}

// C callbacks
private func deviceAddedCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    guard let context = context else { return }
    let detector = Unmanaged<RemoteDetector>.fromOpaque(context).takeUnretainedValue()
    detector.handleDeviceAdded(device)
}

private func deviceRemovedCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    guard let context = context else { return }
    let detector = Unmanaged<RemoteDetector>.fromOpaque(context).takeUnretainedValue()
    detector.handleDeviceRemoved(device)
}

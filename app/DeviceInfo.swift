//
//  DeviceInfo.swift
//  HyperVibe (settings UI)
//
//  Everything macOS will tell us about the paired remote: battery, firmware, address and the
//  HID interface map. Battery/firmware/address come from `system_profiler -json SPBluetoothDataType`
//  (~0.15 s, so it runs off the main thread); the interface map comes straight from IOHIDManager.
//
//  Note: the remote's battery is NOT published as an IORegistry `BatteryPercent` property the way
//  Magic Trackpad/Keyboard are, so system_profiler is the only source for it.
//

import Foundation
import Combine
import IOKit
import IOKit.hid

final class DeviceInfo: ObservableObject {

    struct Interface: Identifiable, Hashable {
        let id = UUID()
        let transport: String
        let usagePage: Int
        let usage: Int
        let maxInput: Int
        let maxFeature: Int

        /// Human label for the usage pairs this remote actually exposes.
        var label: String {
            switch (usagePage, usage) {
            case (0x0C, 0x01):  return "Consumer control"
            case (0x0C, 0x04):  return "Audio (mic channel)"
            case (0x0C, 0x109): return "Consumer 0x109"
            case (0x0D, 0x01):  return "Digitizer / trackpad"
            case (0x20, 0x42):  return "Sensor 0x42"
            case (0x20, 0xE0):  return "Sensor 0xE0"
            case (0xFF00, 0x0B): return "Apple device management"
            default:            return "—"
            }
        }

        var usageDescription: String {
            String(format: "0x%04X / 0x%02X", usagePage, usage)
        }

        static func == (a: Interface, b: Interface) -> Bool {
            a.transport == b.transport && a.usagePage == b.usagePage && a.usage == b.usage
                && a.maxInput == b.maxInput && a.maxFeature == b.maxFeature
        }
        func hash(into h: inout Hasher) {
            h.combine(transport); h.combine(usagePage); h.combine(usage)
            h.combine(maxInput); h.combine(maxFeature)
        }
    }

    @Published private(set) var battery: Int?
    @Published private(set) var firmware: String?
    @Published private(set) var address: String?
    @Published private(set) var vendorID: String?
    @Published private(set) var productID: String?
    @Published private(set) var name: String?
    @Published private(set) var interfaces: [Interface] = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var refreshing: Bool = false

    /// Apple vendor / 3rd-gen Siri Remote product.
    private static let vendor = 0x004C
    private static let product = 0x0315

    private var timer: Timer?

    deinit { stop() }

    /// Begin periodic refresh. Cheap enough to poll, but battery only moves slowly.
    func start(interval: TimeInterval = 60) {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let ifaces = Self.readInterfaces()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let bt = Self.readBluetooth()
            DispatchQueue.main.async {
                guard let self else { return }
                self.interfaces = ifaces
                self.name       = bt?.name
                self.battery    = bt?.battery
                self.firmware   = bt?.firmware
                self.address    = bt?.address
                self.vendorID   = bt?.vendorID
                self.productID  = bt?.productID
                self.updatedAt  = Date()
                self.refreshing = false
            }
        }
    }

    // MARK: - Sources

    private struct BTInfo {
        var name: String?
        var battery: Int?
        var firmware: String?
        var address: String?
        var vendorID: String?
        var productID: String?
    }

    /// Parse `system_profiler -json SPBluetoothDataType`, locating the remote by product ID so a
    /// renamed or different-serial unit still resolves.
    private static func readBluetooth() -> BTInfo? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["-json", "SPBluetoothDataType"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sections = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return nil }

        let wantProduct = String(format: "0x%04X", product).lowercased()

        for section in sections {
            // Connected devices are grouped under `device_connected` (and, when idle, other keys).
            for (_, value) in section {
                guard let groups = value as? [[String: Any]] else { continue }
                for group in groups {
                    for (deviceName, raw) in group {
                        guard let d = raw as? [String: Any] else { continue }
                        let pid = (d["device_productID"] as? String)?.lowercased()
                        guard pid == wantProduct else { continue }
                        var info = BTInfo()
                        info.name = deviceName
                        if let b = d["device_batteryLevelMain"] as? String {
                            info.battery = Int(b.replacingOccurrences(of: "%", with: ""))
                        }
                        info.firmware  = d["device_firmwareVersion"] as? String
                        info.address   = d["device_address"] as? String
                        info.vendorID  = d["device_vendorID"] as? String
                        info.productID = d["device_productID"] as? String
                        return info
                    }
                }
            }
        }
        return nil
    }

    /// Enumerate the remote's HID interfaces directly (no subprocess).
    private static func readInterfaces() -> [Interface] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: vendor,
            kIOHIDProductIDKey: product
        ] as CFDictionary)

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }

        func int(_ d: IOHIDDevice, _ key: String) -> Int? {
            (IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue
        }

        var seen = Set<Interface>()
        for d in devices {
            guard
                let up = int(d, kIOHIDPrimaryUsagePageKey),
                let u  = int(d, kIOHIDPrimaryUsageKey)
            else { continue }
            let transport = (IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String) ?? "—"
            seen.insert(Interface(transport: transport,
                                  usagePage: up,
                                  usage: u,
                                  maxInput: int(d, kIOHIDMaxInputReportSizeKey) ?? 0,
                                  maxFeature: int(d, kIOHIDMaxFeatureReportSizeKey) ?? 0))
        }
        return seen.sorted {
            ($0.transport, $0.usagePage, $0.usage) < ($1.transport, $1.usagePage, $1.usage)
        }
    }
}

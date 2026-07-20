//
//  NativePushToTalk.swift
//  HyperVibe
//
//  Calls the AppleBluetoothRemote driver's own PushToTalk property path. Reverse-engineering the
//  matching macOS driver shows that, for product IDs 788/789, this sends one byte through hidden
//  Feature report 0x99. This is intentionally diagnostic-only and is always disabled on cleanup.
//

import Foundation
import IOKit

enum NativePushToTalk {
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> IOReturn {
        guard let matching = IOServiceMatching("AppleEmbeddedBluetoothDeviceManagement") else {
            rmDebug("🗣 native-ptt: IOServiceMatching returned nil")
            return kIOReturnNotFound
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else {
            rmDebug("🗣 native-ptt: AppleEmbeddedBluetoothDeviceManagement not found")
            return kIOReturnNotFound
        }
        defer { IOObjectRelease(service) }

        // Use UInt8 deliberately: the driver casts this dictionary value to OSNumber, not OSBoolean.
        let properties = ["PushToTalk": NSNumber(value: UInt8(enabled ? 1 : 0))] as CFDictionary
        let result = IORegistryEntrySetCFProperties(service, properties)
        rmDebug(String(format: "🗣 native-ptt: PushToTalk=%d → 0x%X%@",
                       enabled ? 1 : 0, result, result == kIOReturnSuccess ? " ✅" : ""))
        return result
    }
}

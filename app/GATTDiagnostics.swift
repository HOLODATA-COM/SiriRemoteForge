//
//  GATTDiagnostics.swift
//  HyperVibe
//
//  Read-only CoreBluetooth inventory for mapping the Siri Remote's HID-over-GATT reports.
//  Enabled only with `--dump-gatt <remote-name>`.
//

import CoreBluetooth
import Foundation

final class GATTDiagnostics: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let targetName: String
    private var central: CBCentralManager?
    private var retainedPeripherals: [UUID: CBPeripheral] = [:]
    private var characteristicNumbers: [ObjectIdentifier: Int] = [:]
    private var nextCharacteristicNumber = 1

    init(targetName: String) {
        self.targetName = targetName
        super.init()
    }

    func start() {
        rmDebug("🧬 GATT: starting read-only inventory for target name \(targetName)")
        central = CBCentralManager(delegate: self, queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            rmDebug("🧬 GATT: diagnostic window complete")
            exit(0)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        rmDebug("🧬 GATT: central state=\(stateName(central.state)) authorization=\(authorizationName(CBManager.authorization))")
        guard central.state == .poweredOn else { return }

        // Try the system's already-connected HID peripheral first. If macOS does not expose the
        // reserved HID service through this API, scan without a service filter but ignore and avoid
        // logging every device except the explicitly named remote.
        let connected = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: "1812")])
        if let target = connected.first(where: { $0.name == targetName }) {
            rmDebug("🧬 GATT: retrieved connected target \(target.identifier.uuidString)")
            inspect(target, with: central)
            return
        }

        rmDebug("🧬 GATT: connected HID lookup did not expose target; scanning by exact name")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripheral.name == targetName else { return }
        rmDebug("🧬 GATT: discovered target \(peripheral.identifier.uuidString) rssi=\(RSSI)")
        central.stopScan()
        inspect(peripheral, with: central)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        rmDebug("🧬 GATT: connected; discovering all services")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        rmDebug("🧬 GATT: connect failed: \(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        rmDebug("🧬 GATT: disconnected reconnecting=\(isReconnecting) error=\(error?.localizedDescription ?? "none")")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            rmDebug("🧬 GATT: service discovery failed: \(error.localizedDescription)")
            return
        }
        let services = peripheral.services ?? []
        rmDebug("🧬 GATT: discovered \(services.count) services")
        for service in services {
            rmDebug("🧬 GATT: service uuid=\(service.uuid.uuidString) primary=\(service.isPrimary)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            rmDebug("🧬 GATT: characteristic discovery failed service=\(service.uuid.uuidString): \(error.localizedDescription)")
            return
        }
        let characteristics = service.characteristics ?? []
        rmDebug("🧬 GATT: service=\(service.uuid.uuidString) characteristics=\(characteristics.count)")
        for characteristic in characteristics {
            let number = number(for: characteristic)
            rmDebug("🧬 GATT: char#\(number) uuid=\(characteristic.uuid.uuidString) properties=\(propertyNames(characteristic.properties))")
            peripheral.discoverDescriptors(for: characteristic)
            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic,
                    error: Error?) {
        let number = number(for: characteristic)
        if let error {
            rmDebug("🧬 GATT: descriptor discovery failed char#\(number): \(error.localizedDescription)")
            return
        }
        let descriptors = characteristic.descriptors ?? []
        rmDebug("🧬 GATT: char#\(number) descriptors=\(descriptors.map { $0.uuid.uuidString }.joined(separator: ","))")
        for descriptor in descriptors {
            peripheral.readValue(for: descriptor)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        let number = number(for: characteristic)
        if let error {
            rmDebug("🧬 GATT: char#\(number) read failed: \(error.localizedDescription)")
            return
        }
        rmDebug("🧬 GATT: char#\(number) value=\(hex(characteristic.value))")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor,
                    error: Error?) {
        let characteristicNumber = descriptor.characteristic.map { self.number(for: $0) } ?? -1
        if let error {
            rmDebug("🧬 GATT: char#\(characteristicNumber) descriptor=\(descriptor.uuid.uuidString) read failed: \(error.localizedDescription)")
            return
        }
        rmDebug("🧬 GATT: char#\(characteristicNumber) descriptor=\(descriptor.uuid.uuidString) value=\(descriptorValue(descriptor.value))")
    }

    private func inspect(_ peripheral: CBPeripheral, with central: CBCentralManager) {
        retainedPeripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        if peripheral.state == .connected {
            rmDebug("🧬 GATT: target already connected; discovering all services")
            peripheral.discoverServices(nil)
        } else {
            rmDebug("🧬 GATT: requesting shared CoreBluetooth connection")
            central.connect(peripheral)
        }
    }

    private func number(for characteristic: CBCharacteristic) -> Int {
        let key = ObjectIdentifier(characteristic)
        if let existing = characteristicNumbers[key] { return existing }
        let assigned = nextCharacteristicNumber
        nextCharacteristicNumber += 1
        characteristicNumbers[key] = assigned
        return assigned
    }

    private func hex(_ data: Data?) -> String {
        guard let data else { return "<nil>" }
        return data.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
            + (data.count > 64 ? " … (\(data.count) bytes)" : " (\(data.count) bytes)")
    }

    private func descriptorValue(_ value: Any?) -> String {
        if let data = value as? Data { return hex(data) }
        if let value { return String(describing: value) }
        return "<nil>"
    }

    private func propertyNames(_ properties: CBCharacteristicProperties) -> String {
        var names: [String] = []
        if properties.contains(.broadcast) { names.append("broadcast") }
        if properties.contains(.read) { names.append("read") }
        if properties.contains(.writeWithoutResponse) { names.append("writeWithoutResponse") }
        if properties.contains(.write) { names.append("write") }
        if properties.contains(.notify) { names.append("notify") }
        if properties.contains(.indicate) { names.append("indicate") }
        if properties.contains(.authenticatedSignedWrites) { names.append("authenticatedSignedWrites") }
        if properties.contains(.extendedProperties) { names.append("extendedProperties") }
        if properties.contains(.notifyEncryptionRequired) { names.append("notifyEncryptionRequired") }
        if properties.contains(.indicateEncryptionRequired) { names.append("indicateEncryptionRequired") }
        return names.joined(separator: "|")
    }

    private func stateName(_ state: CBManagerState) -> String {
        switch state {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        @unknown default: return "future(\(state.rawValue))"
        }
    }

    private func authorizationName(_ authorization: CBManagerAuthorization) -> String {
        switch authorization {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .allowedAlways: return "allowedAlways"
        @unknown default: return "future(\(authorization.rawValue))"
        }
    }
}

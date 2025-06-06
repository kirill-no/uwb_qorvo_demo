//
//  SimpleBLENIManager.swift
//  uwb_qorvo_demo
//
//  Created by ChatGPT on 06/03/2025.
//
import CoreBluetooth
import NearbyInteraction

protocol SimpleBLENIManagerDelegate: AnyObject {
    func didReceiveAccessoryData(_ data: Data, from peripheral: CBPeripheral)
    func didConnectToPeripheral(_ peripheral: CBPeripheral)
    func didDisconnectPeripheral(_ peripheral: CBPeripheral)
}

class SimpleBLENIManager: NSObject {
    weak var delegate: SimpleBLENIManagerDelegate?

    private var centralManager: CBCentralManager!
    private let targetUUIDs: [UUID]
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    // Temporarily store RX and TX until notification is confirmed
    private var pendingRxCharacteristic: CBCharacteristic?
    private var pendingTxCharacteristic: CBCharacteristic?

    init(targetUUIDs: [UUID]) {
        self.targetUUIDs = targetUUIDs
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }
}

extension SimpleBLENIManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: [QorvoNIService.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        print("🔄 SimpleBLENI: Scanning for Qorvo NI")
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        guard targetUUIDs.contains(id) else { return }
        if discoveredPeripherals[id] == nil {
            discoveredPeripherals[id] = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        delegate?.didConnectToPeripheral(peripheral)
        peripheral.discoverServices([QorvoNIService.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        delegate?.didDisconnectPeripheral(peripheral)
    }
}

extension SimpleBLENIManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }
        let uuids = services.map { $0.uuid.uuidString }.joined(separator: ", ")
        print("🔍 SimpleBLENI: didDiscoverServices for \(peripheral.identifier): [\(uuids)]")

        // Otherwise, handle QNIS (foreground mode)
        if let qnisService = services.first(where: { $0.uuid == QorvoNIService.serviceUUID }) {
            peripheral.discoverCharacteristics(
                [QorvoNIService.rxCharacteristicUUID, QorvoNIService.txCharacteristicUUID],
                for: qnisService
            )
            return
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil, let characteristics = service.characteristics else { return }
        let uuids = characteristics.map { $0.uuid.uuidString }.joined(separator: ", ")
        print("🔍 SimpleBLENI: didDiscoverCharacteristicsFor \(peripheral.identifier) – service \(service.uuid.uuidString): [\(uuids)]")

        // Otherwise, QNIS path (foreground mode)
        for c in characteristics {
            // Log each characteristic’s properties
            print("🔍 SimpleBLENI: Char \(c.uuid.uuidString) properties: \(c.properties)")
            if c.uuid == QorvoNIService.rxCharacteristicUUID {
                pendingRxCharacteristic = c
            } else if c.uuid == QorvoNIService.txCharacteristicUUID {
                pendingTxCharacteristic = c
                peripheral.setNotifyValue(true, for: c)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            print("❌ SimpleBLENI: Failed to enable notifications for \(characteristic.uuid): \(error)")
            return
        }
        // Once TX notifications are active, send init command on RX
        if characteristic.uuid == QorvoNIService.txCharacteristicUUID && characteristic.isNotifying {
            print("🔔 SimpleBLENI: Notifications enabled for TX on \(peripheral.identifier)")
            if let rxChar = pendingRxCharacteristic {
                let initByte: UInt8 = 0x0A
                DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) {
                    peripheral.writeValue(Data([initByte]), for: rxChar, type: .withResponse)
                    print("✉️ SimpleBLENI: Sent MessageId_init (0x0A) to \(peripheral.identifier) after notification enabled")
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        if characteristic.uuid == QorvoNIService.txCharacteristicUUID {
            let hex = data.map { String(format: "%02x", $0) }.joined()
            print("📨 SimpleBLENI: TX notification from \(peripheral.identifier): [\(hex)]")
            let messageId = data[0]
            if messageId == 0x01 {
                let accessoryData = data.advanced(by: 1)
                delegate?.didReceiveAccessoryData(accessoryData, from: peripheral)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            print("❌ SimpleBLENI: Error writing to \(characteristic.uuid) on \(peripheral.identifier): \(error)")
        } else {
            print("✉️ SimpleBLENI: Write to \(characteristic.uuid) succeeded for \(peripheral.identifier)")
        }
    }

    /// Write the iOS shareable NI configuration back to the accessory.
    func sendShareableConfiguration(_ data: Data, to peripheral: CBPeripheral) {
        guard let rxChar = pendingRxCharacteristic else {
            print("⚠️ SimpleBLENI: No RX characteristic available for sending shareable config")
            return
        }
        peripheral.writeValue(data, for: rxChar, type: .withResponse)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        print("✉️ SimpleBLENI: Sent shareable configuration to \(peripheral.identifier): [\(hex)]")
    }
}

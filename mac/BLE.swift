// Link por Bluetooth LE: o iPhone anuncia um serviço GATT e o Mac assina a característica de comandos.
// A característica exige criptografia, então na primeira vez o macOS e o iOS pedem para parear.

import Foundation
import CoreBluetooth

let BLE_SERVICE = CBUUID(string: "6E7A0001-5C3B-4A8E-9F2D-7A1C0DE5A001")
let BLE_COMMANDS = CBUUID(string: "6E7A0002-5C3B-4A8E-9F2D-7A1C0DE5A001")
let BLE_REPLIES = CBUUID(string: "6E7A0003-5C3B-4A8E-9F2D-7A1C0DE5A001")

final class BLELink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    /// Nome do iPhone conectado, ou nil.
    var onStatus: (String?) -> Void = { _ in }
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var buffer = ""
    private var replies: CBCharacteristic?

    func start() { central = CBCentralManager(delegate: self, queue: .main) }

    private func scan() {
        guard central.state == .poweredOn, peripheral == nil else { return }
        if let p = central.retrieveConnectedPeripherals(withServices: [BLE_SERVICE]).first { return connect(p) }
        central.scanForPeripherals(withServices: [BLE_SERVICE])
    }

    private func connect(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        central.connect(p)
    }

    private func reset() {
        if peripheral != nil { input.release() }
        Hub.shared.drop(owner: "ble")
        peripheral = nil
        replies = nil
        buffer = ""
        onStatus(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in scan() }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn { scan() } else { peripheral = nil; onStatus(nil) }
        if c.state == .unauthorized { print("⚠️  Bluetooth não autorizado para o TracePad (Ajustes › Privacidade › Bluetooth)") }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        if peripheral == nil { connect(p) }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices([BLE_SERVICE]) }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { reset() }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        print("○ Bluetooth desconectado")
        reset()
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == BLE_SERVICE }) else { return central.cancelPeripheralConnection(p) }
        p.discoverCharacteristics([BLE_COMMANDS, BLE_REPLIES], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        replies = s.characteristics?.first { $0.uuid == BLE_REPLIES }
        guard let ch = s.characteristics?.first(where: { $0.uuid == BLE_COMMANDS }) else { return central.cancelPeripheralConnection(p) }
        p.setNotifyValue(true, for: ch)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        if ch.isNotifying {
            print("● Bluetooth conectado: \(p.name ?? "iPhone")")
            onStatus(p.name ?? "iPhone")
        } else if error != nil {
            central.cancelPeripheralConnection(p)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value, let s = String(data: d, encoding: .utf8) else { return }
        buffer += s
        while let i = buffer.firstIndex(of: "\n") {
            handle(String(buffer[..<i]), owner: "ble") { [weak self] r in
                guard let self, let ch = self.replies, self.peripheral === p else { return }
                let data = Data((r + "\n").utf8)
                let max = p.maximumWriteValueLength(for: .withResponse)
                var off = 0
                while off < data.count {
                    p.writeValue(data.subdata(in: off..<min(off + max, data.count)), for: ch, type: .withResponse)
                    off += max
                }
            }
            buffer.removeSubrange(...i)
        }
    }
}

// Transporte até o Mac.
//  • USB: escuta em localhost:2345; o app do Mac chega aqui pelo cabo via usbmuxd (~1 ms).
//  • Bluetooth: anuncia um serviço GATT e envia comandos por notify (~15 ms, sem precisar de Wi-Fi).
// Os comandos são as mesmas linhas de texto do PWA (ver mac/Input.swift). USB tem prioridade.

import Foundation
import Network
import CoreBluetooth
import Combine

enum Transport: String { case none = "Desconectado", usb = "USB", ble = "Bluetooth" }

final class Link: NSObject, ObservableObject {
    static let shared = Link()
    static let port: UInt16 = 2345
    static let service = CBUUID(string: "6E7A0001-5C3B-4A8E-9F2D-7A1C0DE5A001")
    static let commands = CBUUID(string: "6E7A0002-5C3B-4A8E-9F2D-7A1C0DE5A001")
    static let replies = CBUUID(string: "6E7A0003-5C3B-4A8E-9F2D-7A1C0DE5A001")

    @Published private(set) var transport: Transport = .none
    @Published private(set) var bluetoothOff = false
    /// Estado do Mac (nil = indisponível ou ainda não recebido)
    @Published private(set) var volume: Double?
    @Published private(set) var brightness: Double?
    @Published private(set) var muted = false
    private var inbox = ""

    private var listener: NWListener?
    private var usb: NWConnection?

    private var pm: CBPeripheralManager!
    private var characteristic: CBMutableCharacteristic?
    private var subscribers = [CBCentral]()
    private var queue = [Cmd]()

    private enum Cmd {
        case move(Double, Double)
        case line(String)
        var text: String {
            switch self {
            case .move(let x, let y): String(format: "m %.2f %.2f", x, y)
            case .line(let s): s
            }
        }
    }

    func start() {
        startUSB()
        pm = CBPeripheralManager(delegate: self, queue: .main)
    }

    /// Ao voltar para o primeiro plano: o iOS pode ter derrubado o listener.
    func resume() {
        if listener == nil || listener?.state != .ready { startUSB() }
        if pm?.state == .poweredOn, !pm.isAdvertising { advertise() }
    }

    // MARK: envio

    func move(_ dx: Double, _ dy: Double) { emit(.move(dx, dy)) }

    func send(_ s: String) {
        // textos longos em pedaços, para caber em uma notificação BLE
        if s.hasPrefix("t "), s.utf8.count > 120 {
            var rest = Substring(s.dropFirst(2))
            while !rest.isEmpty {
                let chunk = rest.prefix(40)
                emit(.line("t " + chunk))
                rest = rest.dropFirst(chunk.count)
            }
        } else {
            emit(.line(s))
        }
    }

    private func emit(_ c: Cmd) {
        if let usb, usb.state == .ready {
            usb.send(content: Data((c.text + "\n").utf8), completion: .idempotent)
            return
        }
        guard characteristic != nil, !subscribers.isEmpty else { return }
        // com a fila congestionada, movimentos consecutivos viram um só (e volume/brilho, só o último valor)
        if case .move(let x, let y) = c, case .move(let px, let py)? = queue.last {
            queue[queue.count - 1] = .move(px + x, py + y)
        } else if case .line(let s) = c, s.hasPrefix("v ") || s.hasPrefix("b "),
                  case .line(let last)? = queue.last, last.prefix(2) == s.prefix(2) {
            queue[queue.count - 1] = c
        } else {
            queue.append(c)
        }
        pump()
    }

    private func pump() {
        guard let ch = characteristic else { return }
        let maxLen = subscribers.map(\.maximumUpdateValueLength).min() ?? 20
        while !queue.isEmpty {
            var packet = ""
            var n = 0
            for c in queue {
                let t = c.text + "\n"
                if n > 0, packet.utf8.count + t.utf8.count > maxLen { break }
                packet += t
                n += 1
            }
            guard pm.updateValue(Data(packet.utf8), for: ch, onSubscribedCentrals: nil) else { return }
            queue.removeFirst(n)
        }
    }

    private func update() {
        let t: Transport = usb?.state == .ready ? .usb : subscribers.isEmpty ? .none : .ble
        if t != transport { transport = t }
        if t != .ble { queue.removeAll() }
    }

    // MARK: USB

    private func startUSB() {
        listener?.cancel()
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let p = NWParameters(tls: nil, tcp: tcp)
        p.requiredInterfaceType = .loopback
        p.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: p, on: NWEndpoint.Port(rawValue: Link.port)!) else { return }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self, weak l] st in
            guard case .failed = st else { return }
            l?.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.startUSB() }
        }
        l.start(queue: .main)
        listener = l
    }

    private func accept(_ c: NWConnection) {
        usb?.cancel()
        usb = c
        c.stateUpdateHandler = { [weak self, weak c] st in
            guard let self, let c, self.usb === c else { return }
            switch st {
            case .ready: self.update()
            case .failed, .cancelled: self.usb = nil; self.update()
            default: break
            }
        }
        c.start(queue: .main)
        drain(c)
    }

    /// Respostas do Mac (estado de volume/brilho) e detecção do fechamento do túnel.
    private func drain(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, err in
            if let data { self?.received(data) }
            if done || err != nil { c.cancel(); return }
            self?.drain(c)
        }
    }

    private func received(_ data: Data) {
        inbox += String(decoding: data, as: UTF8.self)
        while let i = inbox.firstIndex(of: "\n") {
            let line = inbox[..<i]
            inbox.removeSubrange(...i)
            let a = line.split(separator: " ")
            guard a.first == "S", a.count >= 4 else { continue }
            let v = Double(a[1]) ?? -1, b = Double(a[2]) ?? -1
            volume = v < 0 ? nil : v
            brightness = b < 0 ? nil : b
            muted = a[3] == "1"
        }
    }
}

// MARK: Bluetooth

extension Link: CBPeripheralManagerDelegate {
    private func advertise() {
        pm.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Link.service], CBAdvertisementDataLocalNameKey: "TracePad"])
    }

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        bluetoothOff = p.state != .poweredOn
        guard p.state == .poweredOn else {
            characteristic = nil
            subscribers.removeAll()
            update()
            return
        }
        let ch = CBMutableCharacteristic(type: Link.commands, properties: [.notifyEncryptionRequired],
                                         value: nil, permissions: [.readEncryptionRequired])
        let rep = CBMutableCharacteristic(type: Link.replies, properties: [.write], value: nil, permissions: [.writeEncryptionRequired])
        let s = CBMutableService(type: Link.service, primary: true)
        s.characteristics = [ch, rep]
        p.removeAllServices()
        p.add(s)
        characteristic = ch
    }

    func peripheralManager(_ p: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if error == nil { advertise() }
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didSubscribeTo ch: CBCharacteristic) {
        if !subscribers.contains(where: { $0.identifier == central.identifier }) { subscribers.append(central) }
        p.setDesiredConnectionLatency(.low, for: central)
        update()
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom ch: CBCharacteristic) {
        subscribers.removeAll { $0.identifier == central.identifier }
        update()
    }

    func peripheralManagerIsReady(toUpdateSubscribers p: CBPeripheralManager) { pump() }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests { if let v = r.value { received(v) } }
        if let first = requests.first { p.respond(to: first, withResult: .success) }
    }
}

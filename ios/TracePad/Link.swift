// Transporte até o Mac.
//  • USB: escuta em localhost:2345; o app do Mac chega aqui pelo cabo via usbmuxd (~1 ms).
//  • Bluetooth: anuncia um serviço GATT e envia comandos por notify (~15 ms, sem precisar de Wi-Fi).
// Os comandos são as mesmas linhas de texto do PWA (ver mac/Input.swift). USB tem prioridade.

import Foundation
import Network
import CoreBluetooth
import Combine
import UIKit

enum Transport: String { case none = "Desconectado", usb = "USB", ble = "Bluetooth" }

struct MacStats {
    var cpu: Double, gpu: Double?, memUsed: Double, memTotal: Double
    var netIn: Double, netOut: Double, diskUsed: Double, diskTotal: Double
    var battery: Double?, charging: Bool, cores: Int
}

struct MacProcess: Identifiable {
    let id: Int
    let name: String, cpu: Double, mem: Double
}

struct MacApp: Identifiable {
    var id: Int { pid }
    let pid: Int, active: Bool, hidden: Bool, name: String, key: String, windows: Int
}

struct InstalledApp: Identifiable {
    let id: Int // índice na lista do Mac
    let name: String, running: Bool
}

struct MacWindow: Identifiable {
    let id: Int // índice
    let title: String, minimized: Bool
}

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
    @Published private(set) var stats: MacStats?
    @Published private(set) var cpuHistory = [Double]()
    @Published private(set) var processes = [MacProcess]()
    @Published private(set) var apps = [MacApp]()
    @Published private(set) var icons = [String: UIImage]()
    /// apps instalados no Mac ("L"); ícones por nome, pedidos sob demanda
    @Published private(set) var installed = [InstalledApp]()
    @Published private(set) var installedIcons = [String: UIImage]()
    private var installedRequested = Set<String>()
    /// janelas do app pedido por último ("W pid")
    @Published private(set) var windows: (pid: Int, list: [MacWindow])?
    private var iconRequested = Set<String>()
    /// dados contínuos assinados no Mac ("s" monitor, "a" apps, "0" nada); reenviado a cada reconexão
    private var subscription: Character = "0"
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
        #if DEBUG
        if let mode = ProcessInfo.processInfo.environment["TP_DEMO"] { return demo(mode) }
        #endif
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

    func subscribe(_ kind: Character) {
        subscription = kind
        send("w \(kind)")
    }

    private func update() {
        let t: Transport = usb?.state == .ready ? .usb : subscribers.isEmpty ? .none : .ble
        if t != transport {
            transport = t
            if t == .none { iconRequested.removeAll(); installedRequested.removeAll() }
            if t != .none, subscription != "0" { DispatchQueue.main.async { self.send("w \(self.subscription)") } }
        }
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
            guard let op = line.first else { continue }
            let body = line.dropFirst(2)
            switch op {
            case "S": parseState(body)
            case "T": parseStats(body)
            case "P": parseProcesses(body)
            case "A": parseApps(body)
            case "I": parseIcon(body)
            case "W": parseWindows(body)
            case "L": parseInstalled(body)
            case "J": parseInstalledIcon(body)
            default: break
            }
        }
    }

    private func parseState(_ body: Substring) {
        let a = body.split(separator: " ")
        guard a.count >= 3 else { return }
        let v = Double(a[0]) ?? -1, b = Double(a[1]) ?? -1
        volume = v < 0 ? nil : v
        brightness = b < 0 ? nil : b
        muted = a[2] == "1"
    }

    private func parseStats(_ body: Substring) {
        let a = body.split(separator: " ").map { Double($0) ?? -1 }
        guard a.count >= 11 else { return }
        stats = MacStats(cpu: a[0], gpu: a[1] < 0 ? nil : a[1], memUsed: a[2], memTotal: a[3], netIn: a[4], netOut: a[5],
                         diskUsed: a[6], diskTotal: a[7], battery: a[8] < 0 ? nil : a[8], charging: a[9] == 1, cores: Int(a[10]))
        cpuHistory.append(a[0])
        if cpuHistory.count > 60 { cpuHistory.removeFirst(cpuHistory.count - 60) }
    }

    private func parseProcesses(_ body: Substring) {
        processes = body.split(separator: "\t").enumerated().compactMap { i, row in
            let f = row.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard f.count >= 3 else { return nil }
            return MacProcess(id: i, name: String(f[0]), cpu: Double(f[1]) ?? 0, mem: Double(f[2]) ?? 0)
        }
    }

    private func parseApps(_ body: Substring) {
        apps = body.split(separator: "\t").compactMap { row in
            let f = row.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard f.count >= 5, let pid = Int(f[0]) else { return nil }
            return MacApp(pid: pid, active: f[1] == "1", hidden: f[2] == "1", name: String(f[3]), key: String(f[4]),
                          windows: f.count > 5 ? Int(f[5]) ?? 0 : 0)
        }
        // ícones: pede só os que faltam, uma vez por sessão
        for app in apps where icons[app.key] == nil && !iconRequested.contains(app.key) {
            iconRequested.insert(app.key)
            send("i \(app.pid)")
        }
    }

    private func parseWindows(_ body: Substring) {
        let a = body.split(separator: " ", maxSplits: 1)
        guard let pid = a.first.flatMap({ Int($0) }) else { return }
        let rows = a.count > 1 ? a[1].split(separator: "\t") : []
        windows = (pid, rows.compactMap { row in
            let f = row.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard f.count >= 3, let i = Int(f[0]) else { return nil }
            return MacWindow(id: i, title: String(f[1]), minimized: f[2] == "1")
        })
    }

    func clearWindows() { windows = nil }

    private func parseInstalled(_ body: Substring) {
        installed = body.split(separator: "\t").compactMap { row in
            let f = row.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard f.count >= 3, let i = Int(f[0]) else { return nil }
            return InstalledApp(id: i, name: String(f[1]), running: f[2] == "1")
        }
    }

    private func parseInstalledIcon(_ body: Substring) {
        let a = body.split(separator: " ", maxSplits: 1)
        guard a.count == 2, let i = Int(a[0]), let app = installed.first(where: { $0.id == i }),
              let data = Data(base64Encoded: String(a[1])), let img = UIImage(data: data) else { return }
        installedIcons[app.name] = img
    }

    /// Pede o ícone quando o app aparece na tela (lazy), uma vez por nome.
    func requestIcon(_ app: InstalledApp) {
        guard installedIcons[app.name] == nil, installedRequested.insert(app.name).inserted else { return }
        send("j \(app.id)")
    }

    private func parseIcon(_ body: Substring) {
        let a = body.split(separator: " ", maxSplits: 1)
        guard a.count == 2, let data = Data(base64Encoded: String(a[1])), let img = UIImage(data: data) else { return }
        icons[String(a[0])] = img
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

#if DEBUG
extension Link {
    /// Dados fictícios para conferir os modos no simulador: TP_DEMO=1
    fileprivate func demo(_: String) {
        transport = .usb
        let u = "\u{1f}"
        received(Data(("S 0.58 0.5 0\n" +
            "A 1\(u)1\(u)0\(u)Safari\(u)a\(u)1\t2\(u)0\(u)0\(u)Xcode\(u)b\(u)3\t3\(u)0\(u)0\(u)Finder\(u)c\t4\(u)0\(u)1\(u)Spotify\(u)d\t5\(u)0\(u)0\(u)Slack\(u)e\t6\(u)0\(u)0\(u)Terminal\(u)f\n").utf8))
        var t = 0.0
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            t += 1
            let cpu = 0.35 + 0.25 * sin(t / 3)
            self?.received(Data(("T \(cpu) 0.37 13540360192 17179869184 2933800 176030 454083641280 494384795648 0.82 1 10\n" +
                "P Xcode\(u)1.2\(u)2100000000\tSafari\(u)0.4\(u)900000000\tSlack Helper (Renderer)\(u)0.18\(u)705187104\tWindowServer\(u)0.15\(u)300000000\tSpotify\(u)0.06\(u)400000000\n").utf8))
        }
    }
}
#endif

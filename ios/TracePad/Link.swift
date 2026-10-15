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

/// Computador conectado por Bluetooth (vários podem estar assinados; só o escolhido recebe os comandos).
struct Peer: Identifiable {
    let id: UUID
    var os: String?
    var name: String?
    var label: String { name ?? osName(os) ?? "Computador" }
}

/// Nome do sistema anunciado pelo host ("H so nome").
func osName(_ os: String?) -> String? {
    switch os {
    case "mac": "Mac"
    case "linux": "Linux"
    case "windows": "Windows"
    default: nil
    }
}

/// "N …": o que está tocando no computador. A posição avança sozinha a partir de `at`.
struct NowPlayingInfo: Equatable {
    var playing: Bool
    var duration: Double?, position: Double?
    var title: String, artist: String, album: String, app: String
    var at: Date

    func elapsed(_ now: Date) -> Double? {
        guard let position else { return nil }
        let p = position + (playing ? now.timeIntervalSince(at) : 0)
        return duration.map { min(p, $0) } ?? p
    }
}

/// Computador conhecido, para acordar pela rede (Wake-on-LAN) a partir de outro que esteja ligado.
struct KnownHost: Codable, Identifiable, Equatable {
    var id: String { mac }
    var mac: String, broadcast: String, name: String, os: String?
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
    /// ações de shell definidas no computador ("C"), chamadas pelo nome
    @Published private(set) var commands = [String]()
    /// computadores no Bluetooth, na ordem em que conectaram
    @Published private(set) var peers = [Peer]()
    /// sistema ("mac"/"linux") e nome do computador ativo, anunciados por ele ("H so nome")
    @Published private(set) var hostOS: String?
    @Published private(set) var hostName: String?
    /// central do Bluetooth que recebe os comandos (nil fora do Bluetooth)
    @Published private(set) var activePeer: UUID?
    @Published private(set) var nowPlaying: NowPlayingInfo?
    @Published private(set) var artwork: UIImage?
    /// progresso do envio de arquivo (nil = nenhum)
    @Published private(set) var transferProgress: Double?
    /// aviso rápido no topo da tela (área de transferência, arquivo salvo…)
    @Published private(set) var notice: String?
    @Published private(set) var knownHosts: [KnownHost] = UserDefaults.standard.data(forKey: "hosts")
        .flatMap { try? JSONDecoder().decode([KnownHost].self, from: $0) } ?? [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(knownHosts), forKey: "hosts") }
    }
    private var noticeTimer: Timer?
    private var transfer: (data: Data, offset: Int, name: String)?
    private var peerInfo = [UUID: (os: String, name: String)]()
    private var usbHost: (os: String, name: String)?
    /// computador escolhido para o Bluetooth (lembrado entre aberturas)
    private var preferred = UserDefaults.standard.string(forKey: "peer").flatMap(UUID.init)
    /// "usb" ou o UUID da central ativa; mudou = outro computador, dados dele são recarregados
    private var activeKey: String?
    private var inboxes = [String: String]()
    private var iconRequested = Set<String>()
    /// dados contínuos assinados no Mac ("s" monitor, "a" apps, "0" nada); reenviado a cada reconexão
    private var subscription: Character = "0"

    private var listener: NWListener?
    private var usb: NWConnection?

    private var pm: CBPeripheralManager!
    private var characteristic: CBMutableCharacteristic?
    private var subscribers = [CBCentral]()
    private var queue = [Cmd]()

    private enum Cmd {
        case move(Double, Double)
        case line(String)
        /// resto de uma linha longa que não coube no pacote anterior (já com o "\n")
        case raw(Data)
        var data: Data {
            switch self {
            case .move(let x, let y): Data(String(format: "m %.2f %.2f\n", x, y).utf8)
            case .line(let s): Data((s + "\n").utf8)
            case .raw(let d): d
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
            usb.send(content: c.data, completion: .idempotent)
            return
        }
        guard characteristic != nil, activeCentral != nil else { return }
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
        guard let ch = characteristic, let central = activeCentral else { return }
        let maxLen = central.maximumUpdateValueLength
        while true {
            if queue.isEmpty, !feedBLE(maxLen) { return } // fila vazia: vez do arquivo sendo enviado
            var packet = Data()
            var n = 0
            var rest: Data?
            for c in queue {
                let d = c.data
                if packet.count + d.count > maxLen {
                    if n == 0 { // linha maior que o pacote: vai em pedaços (o computador junta até o "\n")
                        var cut = maxLen
                        while cut > 1, d[d.startIndex + cut] & 0xC0 == 0x80 { cut -= 1 } // não parte um caractere UTF-8
                        packet = d.prefix(cut)
                        rest = d.dropFirst(cut)
                    }
                    break
                }
                packet += d
                n += 1
            }
            guard pm.updateValue(packet, for: ch, onSubscribedCentrals: [central]) else { return }
            if let rest { queue[0] = .raw(Data(rest)) } else { queue.removeFirst(n) }
        }
    }

    // MARK: arquivos, área de transferência, Wake-on-LAN

    /// Manda um arquivo para a pasta Downloads do computador ("F nome", "D base64"…, "E").
    func sendFile(name: String, data: Data) {
        guard transport != .none else { return show("Sem conexão com o computador") }
        guard transfer == nil else { return show("Já tem um envio em andamento") }
        transfer = (data, 0, name)
        transferProgress = 0
        send("F " + name.replacingOccurrences(of: "\n", with: " "))
        if transport == .usb { feedUSB() } else { pump() }
    }

    func cancelTransfer() {
        guard transfer != nil else { return }
        transfer = nil
        transferProgress = nil
        send("E") // o computador fecha o arquivo; o "E ok" que volta é ignorado
        show("Envio cancelado")
    }

    private func nextChunk(_ size: Int) -> String? {
        guard var t = transfer else { return nil }
        guard t.offset < t.data.count else {
            transfer = nil
            transferProgress = 1
            return "E"
        }
        let end = min(t.offset + size, t.data.count)
        let line = "D " + t.data.subdata(in: t.offset..<end).base64EncodedString()
        t.offset = end
        transfer = t
        let p = Double(end) / Double(t.data.count)
        if p - (transferProgress ?? 0) >= 0.01 || end == t.data.count { transferProgress = p }
        return line
    }

    /// USB: um pedaço grande por vez, o próximo quando o anterior saiu.
    private func feedUSB() {
        guard let usb, usb.state == .ready, let line = nextChunk(48 * 1024) else { return }
        usb.send(content: Data((line + "\n").utf8), completion: .contentProcessed { [weak self] err in
            DispatchQueue.main.async { if err == nil { self?.feedUSB() } }
        })
    }

    /// Bluetooth: só quando a fila de gestos está vazia, em linhas do tamanho de um pacote.
    private func feedBLE(_ maxLen: Int) -> Bool {
        guard transfer != nil else { return false }
        for _ in 0..<8 {
            guard let line = nextChunk(max(30, (maxLen - 3) / 4 * 3)) else { break }
            queue.append(.line(line))
        }
        return !queue.isEmpty
    }

    /// Pega o texto copiado no computador e coloca na área de transferência do iPhone.
    func pullClipboard() { send("y") }

    /// Manda o texto copiado no iPhone para a área de transferência do computador.
    func pushClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return show("Nada copiado no iPhone") }
        send("Y " + Data(text.utf8).base64EncodedString())
        show("Enviado para o computador")
    }

    /// Acorda outro computador: o pacote mágico sai do computador conectado (o iOS não deixa apps
    /// gratuitos mandarem broadcast na rede).
    func wake(_ h: KnownHost) {
        guard transport != .none else { return show("Conecte a um computador ligado para acordar os outros") }
        send("R \(h.mac) \(h.broadcast)")
        show("Acordando \(h.name)…")
    }

    func forget(_ h: KnownHost) { knownHosts.removeAll { $0 == h } }

    func show(_ text: String) {
        notice = text
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in self?.notice = nil }
    }

    func subscribe(_ kind: Character) {
        subscription = kind
        send("w \(kind)")
    }

    private var activeCentral: CBCentral? {
        subscribers.first { $0.identifier == preferred } ?? subscribers.first
    }

    /// Escolhe o computador do Bluetooth.
    func select(_ id: UUID) {
        guard id != activeCentral?.identifier, subscribers.contains(where: { $0.identifier == id }) else { return }
        preferred = id
        UserDefaults.standard.set(id.uuidString, forKey: "peer")
        queue.removeAll()
        update()
    }

    /// Manda direto para uma central específica (fora da fila do computador ativo).
    private func direct(_ s: String, to c: CBCentral) {
        guard let ch = characteristic else { return }
        pm.updateValue(Data(s.utf8), for: ch, onSubscribedCentrals: [c])
    }

    private func update() {
        let central = activeCentral
        let t: Transport = usb?.state == .ready ? .usb : central == nil ? .none : .ble
        if t != transport { transport = t }
        let key = t == .usb ? "usb" : central?.identifier.uuidString
        let host = t == .usb ? usbHost : central.flatMap { peerInfo[$0.identifier] }
        if hostOS != host?.os { hostOS = host?.os }
        if hostName != host?.name { hostName = host?.name }
        let ap = t == .ble ? central?.identifier : nil
        if activePeer != ap { activePeer = ap }
        peers = subscribers.map { Peer(id: $0.identifier, os: peerInfo[$0.identifier]?.os, name: peerInfo[$0.identifier]?.name) }
        if key != activeKey {
            // o computador que deixou de ser o ativo (e continua no Bluetooth) solta o arrasto e para de mandar dados
            if let old = activeKey, let c = subscribers.first(where: { $0.identifier.uuidString == old }) { direct("u\nw 0\n", to: c) }
            activeKey = key
            resetHostData()
            if transfer != nil { transfer = nil; transferProgress = nil; show("Envio interrompido") }
            if key != nil {
                DispatchQueue.main.async {
                    self.send("?") // pede "H so nome" (hosts antigos ignoram)
                    if self.subscription != "0" { self.send("w \(self.subscription)") }
                    self.send("C")
                    self.send("K") // MAC deste computador, para acordá-lo depois
                }
            }
        }
        if t != .ble { queue.removeAll() }
    }

    /// Outro computador: nada do anterior vale (apps, ícones, monitor, comandos).
    private func resetHostData() {
        stats = nil
        cpuHistory = []
        processes = []
        apps = []
        icons = [:]
        installed = []
        installedIcons = [:]
        windows = nil
        commands = []
        nowPlaying = nil
        artwork = nil
        iconRequested.removeAll()
        installedRequested.removeAll()
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
            case .failed, .cancelled: self.usb = nil; self.usbHost = nil; self.inboxes["usb"] = nil; self.update()
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

    /// src: "usb" ou o UUID da central. Só o computador ativo é ouvido (fora o "H" de apresentação).
    private func received(_ data: Data, from src: String = "usb") {
        var inbox = inboxes[src, default: ""] + String(decoding: data, as: UTF8.self)
        defer { inboxes[src] = inbox }
        while let i = inbox.firstIndex(of: "\n") {
            let line = inbox[..<i]
            inbox.removeSubrange(...i)
            if line.hasPrefix("H ") { hello(line.dropFirst(2), from: src); continue }
            guard src == activeKey, let op = line.first else { continue }
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
            case "C": commands = body.split(separator: "\t").map(String.init)
            case "N": parseNowPlaying(body)
            case "M": artwork = Data(base64Encoded: String(body)).flatMap(UIImage.init(data:))
            case "Y": receiveClipboard(body)
            case "E": transferDone(body)
            case "K": rememberHost(body)
            default: break
            }
        }
    }

    /// "H so nome"
    private func hello(_ body: Substring, from src: String) {
        let a = body.split(separator: " ", maxSplits: 1)
        guard let os = a.first else { return }
        let info = (os: String(os), name: a.count > 1 ? String(a[1]) : "")
        if src == "usb" { usbHost = info } else if let id = UUID(uuidString: src) { peerInfo[id] = info }
        update()
    }

    private func parseNowPlaying(_ body: Substring) {
        let f = body.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 7, f[0] != "stopped" else { nowPlaying = nil; return }
        let num = { (s: String) in Double(s).flatMap { $0 >= 0 ? $0 : nil } }
        nowPlaying = NowPlayingInfo(playing: f[0] == "playing", duration: num(f[1]), position: num(f[2]),
                                    title: f[3], artist: f[4], album: f[5], app: f[6], at: Date())
    }

    private func receiveClipboard(_ body: Substring) {
        guard let d = Data(base64Encoded: String(body)) else { return }
        let text = String(decoding: d, as: UTF8.self)
        guard !text.isEmpty else { return show("Nada copiado no computador") }
        UIPasteboard.general.string = text
        show("Copiado do computador")
    }

    private func transferDone(_ body: Substring) {
        guard transferProgress != nil else { return }
        transferProgress = nil
        if body.hasPrefix("ok ") {
            show("Salvo em " + ((String(body.dropFirst(3)) as NSString).deletingLastPathComponent as NSString).lastPathComponent)
        } else {
            show("Erro: " + body.dropFirst(5))
        }
    }

    /// "K mac broadcast": guarda (ou atualiza) este computador na lista do Wake-on-LAN.
    private func rememberHost(_ body: Substring) {
        let a = body.split(separator: " ")
        guard a.count >= 1 else { return }
        let h = KnownHost(mac: String(a[0]), broadcast: a.count > 1 ? String(a[1]) : "255.255.255.255",
                          name: hostName.flatMap { $0.isEmpty ? nil : $0 } ?? osName(hostOS) ?? "Computador", os: hostOS)
        if let i = knownHosts.firstIndex(where: { $0.mac == h.mac }) {
            if knownHosts[i] != h { knownHosts[i] = h }
        } else {
            knownHosts.append(h)
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
        direct("?\n", to: central) // quem é você? (vale também para os que não estão ativos)
        update()
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom ch: CBCharacteristic) {
        subscribers.removeAll { $0.identifier == central.identifier }
        peerInfo[central.identifier] = nil
        inboxes[central.identifier.uuidString] = nil
        update()
    }

    func peripheralManagerIsReady(toUpdateSubscribers p: CBPeripheralManager) { pump() }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests { if let v = r.value { received(v, from: r.central.identifier.uuidString) } }
        if let first = requests.first { p.respond(to: first, withResult: .success) }
    }
}

#if DEBUG
extension Link {
    /// Dados fictícios para conferir os modos no simulador: TP_DEMO=1
    fileprivate func demo(_: String) {
        transport = .usb
        activeKey = "usb"
        let u = "\u{1f}"
        received(Data(("S 0.58 0.5 0\n" + "N playing\t215.0\t42\tGangsta Gangsta\tN.W.A.\tStraight Outta Compton\tSpotify\n" +
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

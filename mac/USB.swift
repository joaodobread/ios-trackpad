// Link por USB via usbmuxd (o mesmo daemon que o Finder/Xcode usam para falar com o iPhone).
// O app do iPhone escuta em localhost:2345; o usbmuxd faz o túnel do cabo até essa porta.
// Protocolo do usbmuxd: cabeçalho de 16 bytes (len, versão 1, tipo 8 = plist, tag) + plist XML.

import Foundation

let USB_DEVICE_PORT: UInt16 = 2345

private enum Mux {
    static func open() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array("/var/run/usbmuxd".utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            path.withUnsafeBytes { dst.copyBytes(from: $0.prefix(dst.count)) }
        }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if r != 0 { close(fd); return nil }
        return fd
    }

    static func send(_ fd: Int32, _ dict: [String: Any]) -> Bool {
        var msg = dict
        msg["ClientVersionString"] = "TracePad"
        msg["ProgName"] = "TracePad"
        guard let body = try? PropertyListSerialization.data(fromPropertyList: msg, format: .xml, options: 0) else { return false }
        var d = Data()
        for v in [UInt32(16 + body.count), 1, 8, 1] { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(body)
        return writeAll(fd, d)
    }

    static func read(_ fd: Int32) -> [String: Any]? {
        guard let h = readExactly(fd, 16) else { return nil }
        let len = Int(h.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard len >= 16, len < 1 << 20, let body = readExactly(fd, len - 16) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: body, format: nil)) as? [String: Any]
    }

    static func readExactly(_ fd: Int32, _ n: Int) -> Data? {
        var d = Data(count: n)
        var off = 0
        while off < n {
            let r = d.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + off, n - off) }
            if r <= 0 { return nil }
            off += r
        }
        return d
    }

    static func writeAll(_ fd: Int32, _ d: Data) -> Bool {
        var off = 0
        while off < d.count {
            let r = d.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + off, d.count - off) }
            if r <= 0 { return false }
            off += r
        }
        return true
    }
}

final class USBLink {
    /// Chamado na main queue: true quando algum iPhone está com o app aberto e conectado pelo cabo.
    var onStatus: (Bool) -> Void = { _ in }
    private let lock = NSLock()
    private var attached = Set<Int>()
    private var connected = Set<Int>()

    func start() {
        Thread { [self] in listenLoop() }.start()
    }

    private func listenLoop() {
        while true {
            if let fd = Mux.open() {
                if Mux.send(fd, ["MessageType": "Listen", "kLibUSBMuxVersion": 3]) {
                    while let msg = Mux.read(fd) {
                        let id = msg["DeviceID"] as? Int ?? -1
                        switch msg["MessageType"] as? String {
                        case "Attached":
                            let props = msg["Properties"] as? [String: Any]
                            if props?["ConnectionType"] as? String == "USB" { attach(id) }
                        case "Detached":
                            _ = locked { attached.remove(id) }
                        default: break
                        }
                    }
                }
                close(fd)
            }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    private func attach(_ id: Int) {
        guard locked({ attached.insert(id).inserted }) else { return }
        print("🔌 iPhone no USB (id \(id))")
        Thread { [self] in deviceLoop(id) }.start()
    }

    /// Enquanto o aparelho estiver plugado, tenta abrir o túnel até a porta do app (que pode ainda não estar aberto).
    private func deviceLoop(_ id: Int) {
        while locked({ attached.contains(id) }) {
            if let fd = Mux.open() {
                if Mux.send(fd, ["MessageType": "Connect", "DeviceID": id, "PortNumber": Int(USB_DEVICE_PORT.bigEndian)]),
                   let r = Mux.read(fd), r["Number"] as? Int == 0 {
                    setConnected(id, true)
                    _ = Mux.writeAll(fd, Data((hostHello + "\n").utf8))
                    let owner = "usb-\(id)-\(UUID().uuidString)"
                    readLines(fd, owner: owner)
                    DispatchQueue.main.sync { Hub.shared.drop(owner: owner) } // antes de fechar o fd
                    setConnected(id, false)
                }
                close(fd)
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func setConnected(_ id: Int, _ on: Bool) {
        let any = locked { () -> Bool in
            if on { connected.insert(id) } else { connected.remove(id) }
            return !connected.isEmpty
        }
        print(on ? "● USB conectado" : "○ USB desconectado")
        DispatchQueue.main.async { [self] in
            if !on { input.release() }
            onStatus(any)
        }
    }

    private func readLines(_ fd: Int32, owner: String) {
        var buf = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buf.append(contentsOf: chunk[0..<n])
            var lines = [String]()
            while let i = buf.firstIndex(of: 10) {
                lines.append(String(decoding: buf[0..<i], as: UTF8.self))
                buf.removeSubrange(0...i)
            }
            if !lines.isEmpty {
                DispatchQueue.main.async {
                    for l in lines { handle(l, owner: owner) { _ = Mux.writeAll(fd, Data(($0 + "\n").utf8)) } }
                }
            }
        }
    }
}

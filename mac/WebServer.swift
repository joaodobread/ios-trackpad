// PWA por Wi-Fi: HTTP estático (:8787) + WebSocket (:8788) autenticado por PIN.

import Foundation
import Network
import CoreImage
import SystemConfiguration

let HTTP_PORT: UInt16 = 8787
let WS_PORT: UInt16 = 8788

let pinURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tracepad-pin")
let PIN: String = {
    if let s = try? String(contentsOf: pinURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), s.count == 6 { return s }
    let s = String(format: "%06d", Int.random(in: 0..<1_000_000))
    try? s.write(to: pinURL, atomically: true, encoding: .utf8)
    return s
}()

final class WebServer {
    var onClientsChanged: (Int) -> Void = { _ in }
    let webDir: URL
    private var listeners = [NWListener]()
    fileprivate var clients = [ObjectIdentifier: WSClient]()

    init(webDir: URL) { self.webDir = webDir.standardizedFileURL }

    func start() {
        listen(.tcp, HTTP_PORT) { [unowned self] in serveHTTP($0) }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let ws = NWParameters(tls: nil, tcp: tcp)
        let wsOpts = NWProtocolWebSocket.Options()
        wsOpts.autoReplyPing = true
        ws.defaultProtocolStack.applicationProtocols.insert(wsOpts, at: 0)
        listen(ws, WS_PORT) { [unowned self] in WSClient($0, server: self).start() }
    }

    fileprivate func changed() { onClientsChanged(clients.values.filter(\.authed).count) }

    private func listen(_ params: NWParameters, _ port: UInt16, _ handler: @escaping (NWConnection) -> Void) {
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else {
            print("✗ porta \(port) indisponível")
            return
        }
        l.newConnectionHandler = handler
        l.stateUpdateHandler = { if case .failed(let e) = $0 { print("✗ porta \(port): \(e)") } }
        l.start(queue: .main)
        listeners.append(l)
    }

    private func serveHTTP(_ c: NWConnection) {
        c.start(queue: .main)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [webDir] data, _, _, _ in
            guard let data, let req = String(data: data, encoding: .utf8),
                  let line = req.split(separator: "\r\n").first else { c.cancel(); return }
            let parts = line.split(separator: " ")
            var path = parts.count > 1 ? String(parts[1]) : "/"
            if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
            path = path.removingPercentEncoding ?? path
            if path.hasSuffix("/") { path += "index.html" }
            let file = webDir.appendingPathComponent(path).standardizedFileURL
            var status = "200 OK"
            var body: Data
            if file.path.hasPrefix(webDir.path + "/"), let d = try? Data(contentsOf: file) {
                body = d
            } else {
                status = "404 Not Found"
                body = Data("not found".utf8)
            }
            let head = "HTTP/1.1 \(status)\r\nContent-Type: \(mime(file.pathExtension))\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
            c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
        }
    }
}

private func mime(_ ext: String) -> String {
    switch ext {
    case "html": "text/html; charset=utf-8"
    case "js": "text/javascript; charset=utf-8"
    case "css": "text/css; charset=utf-8"
    case "json", "webmanifest": "application/manifest+json"
    case "png": "image/png"
    case "svg": "image/svg+xml"
    default: "application/octet-stream"
    }
}

fileprivate final class WSClient {
    let conn: NWConnection
    unowned let server: WebServer
    var authed = false
    let name: String

    init(_ c: NWConnection, server: WebServer) {
        conn = c
        self.server = server
        name = "\(c.endpoint)"
    }

    func start() {
        server.clients[ObjectIdentifier(self)] = self
        conn.stateUpdateHandler = { [self] st in
            switch st {
            case .failed, .cancelled: close()
            default: break
            }
        }
        conn.start(queue: .main)
        receive()
    }

    func close() {
        guard server.clients.removeValue(forKey: ObjectIdentifier(self)) != nil else { return }
        if authed { input.release(); print("○ PWA desconectado: \(name)"); server.changed() }
        conn.cancel()
    }

    func send(_ s: String, then: (() -> Void)? = nil) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "msg", metadata: [meta])
        conn.send(content: Data(s.utf8), contentContext: ctx, isComplete: true,
                  completion: then.map { f in .contentProcessed { _ in f() } } ?? .idempotent)
    }

    func receive() {
        conn.receiveMessage { [self] data, ctx, _, error in
            if error != nil || (data == nil && ctx == nil) { close(); return }
            if let data, let msg = String(data: data, encoding: .utf8) {
                if authed {
                    handle(msg) { send($0) }
                } else if msg == "a \(PIN)" {
                    authed = true
                    send("ok")
                    print("● PWA conectado: \(name)")
                    server.changed()
                } else {
                    print("✗ PIN incorreto: \(name)")
                    send("bad") { [self] in close() }
                    return
                }
            }
            receive()
        }
    }
}

// MARK: - Utilidades

func lanIPs() -> [String] {
    var res = [String]()
    var ifa: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifa) == 0 else { return [] }
    var p = ifa
    while let i = p {
        p = i.pointee.ifa_next
        let name = String(cString: i.pointee.ifa_name)
        guard let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET), name.hasPrefix("en") else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        res.append(String(cString: host))
    }
    freeifaddrs(ifa)
    return res
}

var localHostName: String? { (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" } }

/// QR code nítido (módulos ampliados sem interpolação).
func qrImage(_ text: String, scale: CGFloat) -> CGImage? {
    guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    f.setValue(Data(text.utf8), forKey: "inputMessage")
    f.setValue("L", forKey: "inputCorrectionLevel")
    guard let img = f.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
    return CIContext().createCGImage(img, from: img.extent)
}

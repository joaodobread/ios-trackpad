// Tocando agora, área de transferência, arquivos vindos do iPhone e Wake-on-LAN.

import AppKit

// MARK: - Tocando agora
// MediaRemote (framework privado) cobre qualquer player, mas no macOS 15.4+ só responde a apps da Apple;
// aí cai para AppleScript no Música e no Spotify (o macOS pede permissão de Automação na primeira vez).

final class NowPlaying {
    struct Info: Equatable {
        var state = "stopped", duration = -1.0, position = -1.0
        var title = "", artist = "", album = "", app = ""
        var artKey: String { title + "\u{1f}" + artist + "\u{1f}" + album }
    }

    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private static let mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
    private static let getInfo: GetInfoFn? = dlsym(mr, "MRMediaRemoteGetNowPlayingInfo").map { unsafeBitCast($0, to: GetInfoFn.self) }

    private var lastLine = ""
    private var lastArt: String?

    /// Lê o estado e manda "N …" (só quando mudou) e "M base64" (quando a faixa muda).
    func push(_ reply: @escaping (String) -> Void) {
        let fallback = { [self] in send(appleScript(), art: { self.scriptArtwork() }, reply) }
        guard let getInfo = NowPlaying.getInfo else { return fallback() }
        getInfo(.main) { [self] dict in
            guard let d = dict as? [String: Any], let title = d["kMRMediaRemoteNowPlayingInfoTitle"] as? String, !title.isEmpty else { return fallback() }
            let rate = d["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
            var pos = d["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? -1
            if pos >= 0, rate > 0, let ts = d["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date { pos += Date().timeIntervalSince(ts) * rate }
            let info = Info(state: rate > 0 ? "playing" : "paused", duration: d["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? -1,
                            position: pos, title: title, artist: d["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? "",
                            album: d["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? "", app: "")
            let art = d["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
            send(info, art: { art }, reply)
        }
    }

    func reset() { lastLine = ""; lastArt = nil }

    private func send(_ info: Info, art: () -> Data?, _ reply: (String) -> Void) {
        let line = info.state == "stopped" ? "N stopped" : String(format: "N %@\t%.1f\t%.0f\t%@\t%@\t%@\t%@", info.state, info.duration,
            info.position, clean(info.title), clean(info.artist), clean(info.album), clean(info.app))
        if line != lastLine { lastLine = line; reply(line) }
        let key = info.state == "stopped" ? "" : info.artKey
        if key != lastArt {
            lastArt = key
            reply("M " + (key.isEmpty ? "" : art().flatMap(thumbnail) ?? ""))
        }
    }

    private func running(_ id: String) -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }

    private var scriptApp: String?

    /// Spotify ou Música, o que estiver tocando (ou pausado) — sem abrir nenhum dos dois.
    private func appleScript() -> Info {
        for (id, app) in [("com.spotify.client", "Spotify"), ("com.apple.Music", "Music")] where running(id) {
            let durExpr = app == "Spotify" ? "(duration of current track) / 1000" : "duration of current track"
            let src = """
            tell application "\(app)"
              if player state is stopped then return "stopped"
              set t to current track
              return (player state as string) & tab & (\(durExpr)) & tab & player position & tab & (name of t) & tab & (artist of t) & tab & (album of t)
            end tell
            """
            guard let s = NSAppleScript(source: src)?.executeAndReturnError(nil).stringValue, s != "stopped" else { continue }
            let f = s.components(separatedBy: "\t")
            guard f.count >= 6 else { continue }
            let num = { (x: String) in Double(x.replacingOccurrences(of: ",", with: ".")) ?? -1 }
            scriptApp = app
            return Info(state: f[0] == "playing" ? "playing" : "paused", duration: num(f[1]), position: num(f[2]),
                        title: f[3], artist: f[4], album: f[5], app: app == "Music" ? "Música" : app)
        }
        scriptApp = nil
        return Info()
    }

    private func scriptArtwork() -> Data? {
        switch scriptApp {
        case "Music":
            return NSAppleScript(source: "tell application \"Music\" to get raw data of artwork 1 of current track")?
                .executeAndReturnError(nil).data
        case "Spotify":
            guard let u = NSAppleScript(source: "tell application \"Spotify\" to get artwork url of current track")?
                .executeAndReturnError(nil).stringValue, let url = URL(string: u) else { return nil }
            return try? Data(contentsOf: url) // pequena (i.scdn.co), e só quando a faixa muda
        default: return nil
        }
    }

    /// Capa reduzida (cabe rápido no Bluetooth).
    private func thumbnail(_ data: Data) -> String? {
        guard let img = NSImage(data: data) else { return nil }
        let side = 240.0
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75])?.base64EncodedString()
    }
}

// MARK: - Área de transferência ("y" pede, "Y base64" define)

enum Clipboard {
    static var line: String {
        "Y " + Data((NSPasteboard.general.string(forType: .string) ?? "").utf8).base64EncodedString()
    }

    static func set(_ b64: Substring) {
        guard let d = Data(base64Encoded: String(b64)) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(decoding: d, as: UTF8.self), forType: .string)
        print("📋 área de transferência recebida do iPhone")
    }
}

// MARK: - Arquivos ("F nome", "D base64"…, "E" → "E ok caminho" | "E erro mensagem")

final class FileReceiver {
    static let shared = FileReceiver()
    private var open = [String: (handle: FileHandle, url: URL)]()

    func begin(_ name: String, owner: String) {
        cancel(owner: owner)
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let url = uniqueURL(dir, safeName(name))
        guard FileManager.default.createFile(atPath: url.path, contents: nil), let h = try? FileHandle(forWritingTo: url) else { return }
        open[owner] = (h, url)
    }

    func data(_ b64: Substring, owner: String) {
        guard let f = open[owner], let d = Data(base64Encoded: String(b64)) else { return }
        f.handle.write(d)
    }

    func end(owner: String, reply: (String) -> Void) {
        guard let f = open.removeValue(forKey: owner) else { return reply("E erro transferência não iniciada") }
        try? f.handle.close()
        print("📥 arquivo recebido: \(f.url.path)")
        reply("E ok " + f.url.path)
    }

    /// Conexão caiu no meio: apaga o arquivo pela metade.
    func cancel(owner: String) {
        guard let f = open.removeValue(forKey: owner) else { return }
        try? f.handle.close()
        try? FileManager.default.removeItem(at: f.url)
    }
}

func safeName(_ s: String) -> String {
    let n = s.components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: "_").trimmingCharacters(in: .whitespaces)
    return n.isEmpty || n.hasPrefix(".") ? "arquivo" + n : n
}

func uniqueURL(_ dir: URL, _ name: String) -> URL {
    let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
    var url = dir.appendingPathComponent(name)
    var i = 1
    while FileManager.default.fileExists(atPath: url.path) {
        url = dir.appendingPathComponent("\(base) (\(i))" + (ext.isEmpty ? "" : "." + ext))
        i += 1
    }
    return url
}

// MARK: - Wake-on-LAN ("K" → "K mac broadcast"; "R mac [broadcast]" acorda outro computador)

enum WakeOnLAN {
    /// MAC e broadcast da interface de rede principal (en*, com IPv4).
    static var line: String? {
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0 else { return nil }
        defer { freeifaddrs(ifa) }
        var macs = [String: String](), bcast = [String: String]()
        var order = [String]()
        var p = ifa
        while let i = p {
            p = i.pointee.ifa_next
            let name = String(cString: i.pointee.ifa_name)
            guard name.hasPrefix("en"), let a = i.pointee.ifa_addr else { continue }
            if a.pointee.sa_family == UInt8(AF_LINK) {
                a.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                    let len = Int(dl.pointee.sdl_alen)
                    guard len == 6 else { return }
                    let off = Int(dl.pointee.sdl_nlen)
                    let bytes = withUnsafeBytes(of: dl.pointee.sdl_data) { Array($0) }
                    guard bytes.count >= off + 6 else { return }
                    macs[name] = bytes[off..<off + 6].map { String(format: "%02x", $0) }.joined(separator: ":")
                }
            } else if a.pointee.sa_family == UInt8(AF_INET), i.pointee.ifa_flags & UInt32(IFF_BROADCAST) != 0, let b = i.pointee.ifa_dstaddr {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(b, socklen_t(b.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                bcast[name] = String(cString: host)
                order.append(name)
            }
        }
        guard let name = order.first(where: { macs[$0] != nil }), let mac = macs[name] else { return nil }
        return "K \(mac) \(bcast[name] ?? "255.255.255.255")"
    }

    static func wake(_ mac: Substring, broadcast: Substring) {
        let hex = mac.filter(\.isHexDigit)
        guard hex.count == 12 else { return }
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); bytes.append(UInt8(hex[i..<j], radix: 16)!); i = j }
        let packet = [UInt8](repeating: 0xff, count: 6) + Array([[UInt8]](repeating: bytes, count: 16).joined())
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        for target in Set([String(broadcast.isEmpty ? "255.255.255.255" : broadcast), "255.255.255.255"]) {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(9).bigEndian
            inet_pton(AF_INET, target, &addr.sin_addr)
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        print("⏰ Wake-on-LAN para \(mac)")
    }
}

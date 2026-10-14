// Apps abertos (estilo ⌘-Tab): lista em ordem alfabética fixa, ícones, janelas e ações.

import AppKit
import ApplicationServices

final class AppsWatcher {
    var onChange: () -> Void = {}

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.onChange() }
        }
    }

    /// Ordem alfabética: os ícones não mudam de lugar ao trocar de app.
    private var apps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }

    /// "A pid␟ativo␟oculto␟nome␟chave␟janelas\t…" — chave identifica o ícone (bundle id ou nome)
    func list() -> String {
        "A " + apps.map { a in
            [String(a.processIdentifier), a.isActive ? "1" : "0", a.isHidden ? "1" : "0", clean(a.localizedName ?? "?"), iconKey(a),
             String(axWindows(a.processIdentifier).count)]
                .joined(separator: "\u{1f}")
        }.joined(separator: "\t")
    }

    // MARK: janelas (API de Acessibilidade — não precisa de Gravação de Tela para ler títulos)

    private func axWindows(_ pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25) // app travado não trava a lista
        guard let ws = ax(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return ws.filter { (ax($0, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole }
    }

    private func ax(_ e: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v : nil
    }

    /// "W pid índice␟título␟minimizada\t…"
    func windows(_ pid: pid_t) -> String {
        "W \(pid) " + axWindows(pid).enumerated().map { i, w in
            let title = (ax(w, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Sem título"
            let min = (ax(w, kAXMinimizedAttribute) as? Bool) == true
            return "\(i)\u{1f}\(clean(title))\u{1f}\(min ? 1 : 0)"
        }.joined(separator: "\t")
    }

    /// Foca uma janela. Confere pelo título, porque a lista pode ter mudado desde que o iPhone pediu.
    func focusWindow(_ pid: pid_t, index: Int, title: String) {
        let ws = axWindows(pid)
        let titled = ws.firstIndex { clean((ax($0, kAXTitleAttribute) as? String) ?? "") == title }
        let i = (index < ws.count && clean((ax(ws[index], kAXTitleAttribute) as? String) ?? "") == title) ? index : (titled ?? index)
        guard i < ws.count else { return activate(pid) }
        let w = ws[i]
        if (ax(w, kAXMinimizedAttribute) as? Bool) == true {
            AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        NSRunningApplication(processIdentifier: pid)?.unhide()
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    /// "I chave base64png"
    func icon(_ pid: pid_t) -> String? {
        guard let a = NSRunningApplication(processIdentifier: pid), let icon = a.icon, let png = pngBase64(icon) else { return nil }
        return "I \(iconKey(a)) \(png)"
    }

    // MARK: apps instalados (abrir pelo iPhone)

    private var installed = [URL]()

    /// "L índice␟nome␟aberto\t…" — apps das pastas de Aplicativos (e uma subpasta abaixo), em ordem alfabética.
    func installedList() -> String {
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    NSHomeDirectory() + "/Applications"]
        var seen = Set<String>()
        var urls = [URL]()
        func add(_ u: URL) { if u.pathExtension == "app", seen.insert(u.lastPathComponent).inserted { urls.append(u) } }
        for d in dirs {
            for u in (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: d), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                if u.pathExtension == "app" { add(u); continue }
                // pastas como "Microsoft Office" com apps dentro
                for v in (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] { add(v) }
            }
        }
        func name(_ u: URL) -> String { fm.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "") }
        installed = urls.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
        return "L " + installed.enumerated().map { i, u in
            "\(i)\u{1f}\(clean(name(u)))\u{1f}\(running.contains(u.standardizedFileURL.path) ? 1 : 0)"
        }.joined(separator: "\t")
    }

    /// "J índice base64png"
    func installedIcon(_ i: Int) -> String? {
        guard installed.indices.contains(i), let png = pngBase64(NSWorkspace.shared.icon(forFile: installed[i].path)) else { return nil }
        return "J \(i) \(png)"
    }

    func launch(_ i: Int) {
        guard installed.indices.contains(i) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: installed[i], configuration: cfg)
    }

    /// Traz para frente. openApplication é o caminho confiável a partir de um app de fundo
    /// (activate() pode ser recusado pela ativação cooperativa do macOS 14+).
    func activate(_ pid: pid_t) {
        guard let a = NSRunningApplication(processIdentifier: pid) else { return }
        if a.isHidden { a.unhide() }
        if let url = a.bundleURL {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
                if err != nil { DispatchQueue.main.async { a.activate() } }
            }
        } else {
            a.activate()
        }
    }

    func hide(_ pid: pid_t) { NSRunningApplication(processIdentifier: pid)?.hide() }
    func quit(_ pid: pid_t) { NSRunningApplication(processIdentifier: pid)?.terminate() }
}

/// Ícone 96×96 em PNG base64.
private func pngBase64(_ icon: NSImage) -> String? {
    let px = 96
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])?.base64EncodedString()
}

private func iconKey(_ a: NSRunningApplication) -> String {
    clean(a.bundleIdentifier ?? a.localizedName ?? "\(a.processIdentifier)").replacingOccurrences(of: " ", with: "_")
}

/// Assinatura de dados contínuos (um cliente por vez — o último que pediu).
final class Hub {
    static let shared = Hub()
    let stats = StatsSampler()
    let apps = AppsWatcher()
    private var sub: (kind: Character, owner: String, reply: (String) -> Void)?
    private var timer: Timer?
    private var tick = 0

    private init() {
        apps.onChange = { [weak self] in
            guard let s = self?.sub, s.kind == "a" else { return }
            s.reply(self!.apps.list())
        }
    }

    /// kind: "s" monitor, "a" apps, "0" nada
    func subscribe(_ kind: Character, owner: String, reply: @escaping (String) -> Void) {
        timer?.invalidate()
        timer = nil
        guard kind == "s" || kind == "a" else { sub = nil; return }
        sub = (kind, owner, reply)
        push()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.push() }
    }

    func drop(owner: String) {
        guard sub?.owner == owner else { return }
        sub = nil
        timer?.invalidate()
        timer = nil
    }

    private func push() {
        guard let s = sub else { return }
        tick += 1
        if s.kind == "s" {
            s.reply(stats.line())
            s.reply(stats.processes())
        } else if tick % 3 == 0 {
            s.reply(apps.list()) // as notificações cobrem quase tudo; isto é só uma rede de segurança
        }
    }
}

// TracePad para Mac — app de barra de menus.
// Recebe gestos do app do iPhone por USB ou Bluetooth, e do PWA por Wi-Fi, e injeta no sistema.

import AppKit
import ApplicationServices

setvbuf(stdout, nil, _IOLBF, 0)

final class Controller: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let usb = USBLink()
    let ble = BLELink()
    let web: WebServer
    var usbOn = false
    var bleName: String?
    var pwaCount = 0

    override init() {
        let dir = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.resourceURL!.appendingPathComponent("web")
        web = WebServer(webDir: dir)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refreshIcon()

        usb.onStatus = { [unowned self] in usbOn = $0; refreshIcon() }
        ble.onStatus = { [unowned self] in bleName = $0; refreshIcon() }
        web.onClientsChanged = { [unowned self] in pwaCount = $0; refreshIcon() }
        usb.start()
        ble.start()
        web.start()

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            print("⚠️  Permita o TracePad em Ajustes do Sistema › Privacidade e Segurança › Acessibilidade.")
        }
        print("TracePad rodando — PIN do PWA: \(PIN)")
        for ip in lanIPs() { print("  PWA: http://\(ip):\(HTTP_PORT)") }
    }

    var connected: Bool { usbOn || bleName != nil || pwaCount > 0 }

    func refreshIcon() {
        let name = connected ? "hand.point.up.left.fill" : "hand.point.up.left"
        item.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "TracePad")
        item.button?.toolTip = "TracePad"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func info(_ s: String) { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        func action(_ s: String, _ sel: Selector, _ key: String = "") {
            let i = NSMenuItem(title: s, action: sel, keyEquivalent: key)
            i.target = self
            menu.addItem(i)
        }

        info("TracePad")
        menu.addItem(.separator())
        info("USB: " + (usbOn ? "● conectado" : "aguardando iPhone"))
        info("Bluetooth: " + (bleName.map { "● \($0)" } ?? "procurando…"))
        info("Wi-Fi (PWA): " + (pwaCount > 0 ? "● \(pwaCount) conectado(s)" : "nenhum"))
        menu.addItem(.separator())

        if !AXIsProcessTrusted() {
            action("⚠️ Permitir Acessibilidade…", #selector(openAccessibility))
            menu.addItem(.separator())
        }

        info("PWA — PIN \(PIN)")
        if let ip = lanIPs().first {
            let url = "http://\(ip):\(HTTP_PORT)/?k=\(PIN)"
            if let cg = qrImage(url, scale: 5) {
                let qr = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                qr.image = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
                menu.addItem(qr)
            }
            info("http://\(ip):\(HTTP_PORT)")
        }
        menu.addItem(.separator())
        action("Sair", #selector(quit), "q")
    }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
app.run()

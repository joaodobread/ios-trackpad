// Injeção de eventos de mouse/teclado/scroll e o protocolo de texto comum a USB, Bluetooth e PWA.

import Foundation
import CoreGraphics

// MARK: - Injeção de eventos

final class Input {
    let src = CGEventSource(stateID: .hidSystemState)
    var pos = CGPoint.zero
    var lastSent = 0.0
    var held: CGMouseButton? = nil
    var lastClick = (t: 0.0, p: CGPoint.zero, b: CGMouseButton.left, n: Int64(0))

    init() { src?.localEventsSuppressionInterval = 0 }

    var now: Double { ProcessInfo.processInfo.systemUptime }

    /// Posição atual. Usa a posição interna enquanto estamos enviando eventos
    /// (a do sistema pode estar atrasada) e ressincroniza quando ocioso.
    func cur() -> CGPoint {
        if now - lastSent > 0.15 { pos = CGEvent(source: nil)?.location ?? pos }
        return pos
    }

    func clamp(_ p: CGPoint, from old: CGPoint) -> CGPoint {
        var id: CGDirectDisplayID = 0
        var n: UInt32 = 0
        if CGGetDisplaysWithPoint(p, 1, &id, &n) == .success, n > 0 { return p }
        CGGetDisplaysWithPoint(old, 1, &id, &n)
        let b = CGDisplayBounds(n > 0 ? id : CGMainDisplayID())
        return CGPoint(x: min(max(p.x, b.minX), b.maxX - 1), y: min(max(p.y, b.minY), b.maxY - 1))
    }

    func flags(_ mods: Substring) -> CGEventFlags {
        var f: CGEventFlags = []
        for c in mods {
            switch c {
            case "c", "w": f.insert(.maskCommand) // w = Super no Linux; no Mac, ⌘
            case "a": f.insert(.maskAlternate)
            case "t": f.insert(.maskControl)
            case "s": f.insert(.maskShift)
            case "f": f.insert(.maskSecondaryFn)
            default: break
            }
        }
        return f
    }

    func move(_ dx: Double, _ dy: Double) {
        let old = cur()
        let p = clamp(CGPoint(x: old.x + dx, y: old.y + dy), from: old)
        let type: CGEventType = switch held {
            case .left: .leftMouseDragged
            case .right: .rightMouseDragged
            case .center: .otherMouseDragged
            default: .mouseMoved
        }
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: held ?? .left) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        e.post(tap: .cghidEventTap)
        pos = p
        lastSent = now
    }

    func button(_ b: CGMouseButton, down: Bool, count: Int64, mods: Substring = "") {
        let type: CGEventType = switch (b, down) {
            case (.left, true): .leftMouseDown
            case (.left, false): .leftMouseUp
            case (.right, true): .rightMouseDown
            case (.right, false): .rightMouseUp
            case (_, true): .otherMouseDown
            case (_, false): .otherMouseUp
        }
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: cur(), mouseButton: b) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: count)
        if !mods.isEmpty { e.flags = flags(mods) }
        e.post(tap: .cghidEventTap)
        lastSent = now
    }

    func click(_ b: CGMouseButton, mods: Substring) {
        let t = now, p = cur()
        let n: Int64 = (b == lastClick.b && t - lastClick.t < 0.5 && hypot(p.x - lastClick.p.x, p.y - lastClick.p.y) < 8) ? lastClick.n + 1 : 1
        lastClick = (t, p, b, n)
        button(b, down: true, count: n, mods: mods)
        button(b, down: false, count: n, mods: mods)
    }

    func press(_ b: CGMouseButton) { held = b; button(b, down: true, count: 1) }
    func release() { if let b = held { held = nil; button(b, down: false, count: 1) } }

    /// phase: 1 began, 2 changed, 4 ended — momentum: 1 begin, 2 continue, 3 end
    func scroll(phase: Int64, momentum: Int64, dx: Int32, dy: Int32) {
        guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(CGEventField(rawValue: 99)!, value: phase)     // kCGScrollWheelEventScrollPhase
        e.setIntegerValueField(CGEventField(rawValue: 123)!, value: momentum) // kCGScrollWheelEventMomentumPhase
        e.post(tap: .cghidEventTap)
    }

    static let modKeys: [(Character, CGKeyCode, CGEventFlags)] = [
        ("t", 59, .maskControl), ("a", 58, .maskAlternate), ("s", 56, .maskShift), ("c", 55, .maskCommand),
    ]

    func key(_ code: CGKeyCode, mods: Substring) {
        var f: CGEventFlags = []
        let used = Input.modKeys.filter { mods.contains($0.0) || ($0.0 == "c" && mods.contains("w")) }
        for (_, k, m) in used {
            f.insert(m)
            post(k, down: true, f)
        }
        var kf = f
        if (123...126).contains(code) { kf.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        post(code, down: true, kf)
        post(code, down: false, kf)
        for (_, k, m) in used.reversed() {
            f.remove(m)
            post(k, down: false, f)
        }
    }

    private func post(_ code: CGKeyCode, down: Bool, _ f: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { return }
        e.flags = f
        e.post(tap: .cghidEventTap)
    }

    func type(_ s: String) {
        for (i, line) in s.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if i > 0 { key(36, mods: "") }
            let u = Array(line.utf16)
            var i = 0
            while i < u.count {
                let chunk = Array(u[i..<min(i + 16, u.count)])
                i += 16
                for down in [true, false] {
                    guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                    chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                    e.post(tap: .cghidEventTap)
                }
            }
        }
    }
}

let input = Input()

/// Apresentação deste computador: "H mac nome".
let hostHello = "H mac " + clean(Host.current().localizedName ?? "Mac")

// MARK: - Protocolo (texto, 1 comando por mensagem/linha)
//   m dx dy            mover
//   c l|r|m [mods]     clique (contagem de duplo/triplo clique feita aqui)
//   d / u              segurar / soltar botão esquerdo (arrastar)
//   s ph mom dx dy     scroll contínuo com fases (momentum incluso)
//   k code [mods]      tecla (mods: c=cmd a=opt t=ctrl s=shift w=super, que no Mac é cmd)
//   g nome             gesto padrão (mission, expose, desktop, space-left/right, lookup, zoom-in/out);
//                      redefinível em ~/.tracepad-actions com "@nome = atalho ou comando"
//   t texto            digitar texto unicode
//   p x                ping (eco)
//   ?                  quem é você → "H mac nome" (também enviado ao conectar; o iPhone escolhe o computador no Bluetooth)
//   v 0..1 / b 0..1    volume / brilho
//   z                  alterna mudo
//   x tecla            tecla de mídia (16 play/pause, 17 próxima, 18 anterior)
//   q                  pede o estado → responde "S volume brilho mudo"
//   w s|a|n|0          assina dados contínuos: monitor ("T …", "P …") / apps ("A …") /
//                      tocando agora ("N estado\tduração\tposição\ttítulo\tartista\tálbum\tapp" e capa "M base64jpg") / nada
//   l                  lista de apps → "A …"
//   i pid              ícone do app → "I chave base64png"
//   a pid / h pid / Q pid   ativar / ocultar / encerrar app
//   W pid              janelas do app → "W pid índice␟título␟minimizada\t…"
//   f pid índice título     foca uma janela específica
//   L                  apps instalados → "L índice␟nome␟aberto\t…"
//   j índice / o índice     ícone ("J índice base64png") / abrir app instalado
//   C                  ações de shell do computador → "C nome\tnome…" (de ~/.tracepad-actions)
//   r nome             roda a ação de shell com esse nome
//   O alvo             abre URL ou app pelo nome
//   y / Y base64       pede a área de transferência ("Y base64") / define (texto UTF-8)
//   F nome, D base64…, E   arquivo para ~/Downloads → "E ok caminho" ou "E erro mensagem"
//   K                  rede deste computador → "K mac broadcast" (o iPhone guarda para o Wake-on-LAN)
//   R mac [broadcast]  manda o pacote mágico para acordar outro computador da rede

/// owner identifica a conexão (para cancelar assinaturas quando ela cair).
func handle(_ msg: String, owner: String = "", reply: @escaping (String) -> Void = { _ in }) {
    guard let op = msg.first else { return }
    if op == "t" { input.type(String(msg.dropFirst(2))); return }
    if op == "r" { Actions.run(String(msg.dropFirst(2))); return }
    if op == "O" { Actions.open(String(msg.dropFirst(2))); return }
    if op == "F" { FileReceiver.shared.begin(String(msg.dropFirst(2)), owner: owner); return }
    if op == "D" { FileReceiver.shared.data(msg.dropFirst(2), owner: owner); return }
    if op == "E" { FileReceiver.shared.end(owner: owner, reply: reply); return }
    if op == "Y" { Clipboard.set(msg.dropFirst(2)); return }
    if op == "f" { // o título pode ter espaços: tudo depois do índice
        let p = msg.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        if p.count >= 3, let pid = pid_t(p[1]), let i = Int(p[2]) { Hub.shared.apps.focusWindow(pid, index: i, title: p.count > 3 ? String(p[3]) : "") }
        return
    }
    let a = msg.split(separator: " ")
    func d(_ i: Int) -> Double { i < a.count ? Double(a[i]) ?? 0 : 0 }
    func s(_ i: Int) -> Substring { i < a.count ? a[i] : "" }
    switch op {
    case "m": input.move(d(1), d(2))
    case "c": input.click(s(1) == "r" ? .right : s(1) == "m" ? .center : .left, mods: s(2))
    case "d": input.press(.left)
    case "u": input.release()
    case "s": input.scroll(phase: Int64(d(1)), momentum: Int64(d(2)), dx: Int32(d(3)), dy: Int32(d(4)))
    case "k": input.key(CGKeyCode(d(1)), mods: s(2))
    case "p": reply(msg)
    case "?": reply(hostHello)
    case "v": SystemControls.setVolume(Float(d(1)))
    case "b": SystemControls.setBrightness(Float(d(1)))
    case "z": SystemControls.setMuted(!SystemControls.muted); reply(SystemControls.state)
    case "x": SystemControls.mediaKey(Int(d(1)))
    case "q": reply(SystemControls.state)
    case "w": Hub.shared.subscribe(s(1).first ?? "0", owner: owner, reply: reply)
    case "l": reply(Hub.shared.apps.list())
    case "i": if let r = Hub.shared.apps.icon(pid_t(d(1))) { reply(r) }
    case "a": Hub.shared.apps.activate(pid_t(d(1)))
    case "h": Hub.shared.apps.hide(pid_t(d(1)))
    case "Q": Hub.shared.apps.quit(pid_t(d(1)))
    case "W": reply(Hub.shared.apps.windows(pid_t(d(1))))
    case "L": reply(Hub.shared.apps.installedList())
    case "j": if let r = Hub.shared.apps.installedIcon(Int(d(1))) { reply(r) }
    case "o": Hub.shared.apps.launch(Int(d(1)))
    case "C": reply(Actions.list())
    case "g": Actions.gesture(String(s(1)))
    case "y": reply(Clipboard.line)
    case "K": if let l = WakeOnLAN.line { reply(l) }
    case "R": WakeOnLAN.wake(s(1), broadcast: s(2))
    default: break
    }
}


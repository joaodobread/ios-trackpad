// Motor de gestos: multitoque → comandos para o Mac.
// 1 dedo move/clica/arrasta · 2 dedos rolam (com fases e inércia), clique direito, pinça = zoom
// 3/4 dedos: gestos de sistema (ou arrastar com 3 dedos, nos ajustes).

import UIKit
import SwiftUI

/// Modificadores fixos da barra do teclado (⌘⌥⌃⇧), consumidos pela próxima tecla ou clique.
enum Mods {
    static var active = Set<Character>() { didSet { onChange() } }
    static var onChange: () -> Void = {}
    static func take() -> String {
        let s = String(active.sorted())
        if !active.isEmpty { active.removeAll() }
        return s
    }
}

func sendKey(_ code: Int, extra: String = "") {
    let m = Mods.take() + extra
    Link.shared.send(m.isEmpty ? "k \(code)" : "k \(code) \(m)")
}


final class TrackpadView: UIView {
    var onFirstTouch: (() -> Void)?
    private let s = Settings.shared
    private let link = Link.shared
    private let gestures = GestureStore.shared

    private enum Mode { case scroll, pinch, done }
    private struct Gesture {
        var start: TimeInterval
        var startPoint: CGPoint
        var tapDrag: Bool
        var max = 0
        var travel: CGFloat = 0
        var mode: Mode?
        var drag = false
        var drag3 = false
        var fired = false
        var samples: [(t: TimeInterval, dx: CGFloat, dy: CGFloat)] = []
        var c = CGPoint.zero
        var d: CGFloat = 0
        var lt: TimeInterval = 0
        var acc = CGPoint.zero
        var pinch: CGFloat = 0
        /// pinça com ação personalizada dispara uma vez por gesto (o padrão, zoom, repete a cada passo)
        var pinchFired = false
    }

    private var points = [ObjectIdentifier: CGPoint]()
    private var g: Gesture?
    private var lastTap = (t: TimeInterval(0), p: CGPoint.zero)

    private let click = UIImpactFeedbackGenerator(style: .rigid)
    private let thump = UIImpactFeedbackGenerator(style: .medium)
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let tick = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    private func haptic(_ gen: UIImpactFeedbackGenerator, _ intensity: CGFloat = 1) {
        guard s.haptics else { return }
        gen.impactOccurred(intensity: intensity)
        gen.prepare()
    }

    private func centroid() -> CGPoint {
        var x: CGFloat = 0, y: CGFloat = 0
        for p in points.values { x += p.x; y += p.y }
        let n = CGFloat(max(points.count, 1))
        return CGPoint(x: x / n, y: y / n)
    }

    private func spread() -> CGFloat {
        guard points.count >= 2 else { return 0 }
        let v = Array(points.values)
        return hypot(v[0].x - v[1].x, v[0].y - v[1].y)
    }

    private func resetRef(_ now: TimeInterval) {
        g?.c = centroid()
        g?.d = spread()
        g?.lt = now
        g?.acc = .zero
        g?.pinch = 0
        if g?.mode != .scroll { g?.mode = nil }
    }

    /// Ganho com aceleração: velocidade em pt/ms.
    private func gain(_ dx: CGFloat, _ dy: CGFloat, _ dtMs: Double) -> Double {
        let v = Double(hypot(dx, dy)) / max(dtMs, 1)
        return s.speed * (0.55 + s.accel * min(v, 3))
    }

    // MARK: toques

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        onFirstTouch?()
        onFirstTouch = nil
        stopMomentum()
        let now = CACurrentMediaTime()
        for t in touches { points[ObjectIdentifier(t)] = t.location(in: self) }
        if g == nil, let p0 = touches.first?.location(in: self) {
            g = Gesture(start: now, startPoint: p0,
                        tapDrag: now - lastTap.t < 0.3 && hypot(p0.x - lastTap.p.x, p0.y - lastTap.p.y) < 80)
            click.prepare()
        }
        g!.max = max(g!.max, points.count)
        resetRef(now)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard var g else { return }
        for t in touches where points[ObjectIdentifier(t)] != nil { points[ObjectIdentifier(t)] = t.location(in: self) }
        let now = CACurrentMediaTime(), n = points.count, c = centroid(), d = spread()
        let dx = c.x - g.c.x, dy = c.y - g.c.y, dtMs = (now - g.lt) * 1000, dd = d - g.d
        g.c = c; g.d = d; g.lt = now
        g.travel += hypot(dx, dy)
        defer { self.g = g }

        switch n {
        case 1:
            if g.max > 1 { return } // dedo que sobrou de um gesto multitoque
            if g.tapDrag, !g.drag, g.travel > 3 { link.send("d"); g.drag = true; haptic(soft) }
            let k = gain(dx, dy, dtMs)
            link.move(Double(dx) * k, Double(dy) * k)
        case 2:
            g.acc.x += dx; g.acc.y += dy; g.pinch += dd
            switch g.mode {
            case nil:
                let pan = hypot(g.acc.x, g.acc.y)
                if abs(g.pinch) > 28, abs(g.pinch) > pan * 1.3 { g.mode = .pinch; g.pinch = 0 }
                else if pan > 6 { g.mode = .scroll; scroll(1, 0, g.acc.x, g.acc.y) }
            case .scroll:
                scroll(2, 0, dx, dy)
                g.samples.append((now, dx, dy))
                if g.samples.count > 12 { g.samples.removeFirst() }
            case .pinch:
                while abs(g.pinch) > 60 {
                    let id = g.pinch > 0 ? "pinch.open" : "pinch.close"
                    g.pinch -= g.pinch > 0 ? 60 : -60
                    if gestures.isCustom(id) { if g.pinchFired { continue }; g.pinchFired = true }
                    if gestures.perform(id) { haptic(tick, 0.5) }
                }
            case .done: break
            }
        case 3 where s.threeFingerDrag:
            if !g.drag3 { link.send("d"); g.drag3 = true; haptic(soft) }
            let k = gain(dx, dy, dtMs)
            link.move(Double(dx) * k, Double(dy) * k)
        default:
            g.acc.x += dx; g.acc.y += dy
            if !g.fired, hypot(g.acc.x, g.acc.y) > 55 {
                g.fired = true
                let horiz = abs(g.acc.x) > abs(g.acc.y)
                swipe(n, horiz ? (g.acc.x > 0 ? "right" : "left") : (g.acc.y > 0 ? "down" : "up"))
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { end(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { end(touches, cancelled: true) }

    private func end(_ touches: Set<UITouch>, cancelled: Bool) {
        for t in touches { points.removeValue(forKey: ObjectIdentifier(t)) }
        guard let gg = g else { return }
        let now = CACurrentMediaTime()
        if gg.mode == .scroll, points.count < 2 {
            endScroll(momentum: points.isEmpty && !cancelled)
            g?.mode = .done
        }
        if gg.drag3, points.count < 3 { link.send("u"); g?.drag3 = false; g?.mode = .done }
        if !points.isEmpty { resetRef(now); return }

        let f = g!
        g = nil
        if f.drag { link.send("u") }
        let isTap = !cancelled && now - f.start < (f.max == 1 ? 0.22 : 0.3) && f.travel < 14 && f.mode == nil && !f.fired && !f.drag
        lastTap.t = 0
        guard isTap else { return }
        switch f.max {
        case 1:
            let m = Mods.take()
            link.send(m.isEmpty ? "c l" : "c l \(m)")
            haptic(click, 0.9)
            lastTap = (now, f.startPoint)
        case 2:
            link.send("c r")
            haptic(thump)
        case 3:
            if gestures.perform("3.tap") { haptic(thump) }
        default:
            if gestures.perform("4.tap") { haptic(thump) }
        }
    }

    private func swipe(_ n: Int, _ dir: String) {
        // com "arrastar com 3 dedos", o ↓ de 4 dedos assume o App Exposé dos 3 dedos
        let standard = n >= 4 && dir == "down" && s.threeFingerDrag ? "expose" : nil
        if gestures.perform("\(min(n, 4)).\(dir)", standard: standard) { haptic(thump) }
    }

    // MARK: rolagem com fases + inércia (o macOS espera isso do driver do trackpad)

    private var rem = CGPoint.zero
    private var display: CADisplayLink?
    private var mv = CGPoint.zero
    private var momFirst = true
    private var momLast: CFTimeInterval = 0

    private func scroll(_ phase: Int, _ mom: Int, _ dx: CGFloat, _ dy: CGFloat) {
        let k = CGFloat(s.scroll) * (s.natural ? 1 : -1)
        rem.x += dx * k; rem.y += dy * k
        let ix = rem.x.rounded(.towardZero), iy = rem.y.rounded(.towardZero)
        rem.x -= ix; rem.y -= iy
        if ix == 0, iy == 0, phase == 2 || mom == 2 { return }
        link.send("s \(phase) \(mom) \(Int(ix)) \(Int(iy))")
    }

    private func endScroll(momentum: Bool) {
        link.send("s 4 0 0 0")
        rem = .zero
        guard momentum, s.momentum, let g else { return }
        let now = CACurrentMediaTime()
        let recent = g.samples.filter { now - $0.t < 0.09 }
        guard recent.count >= 2 else { return }
        let span = max((now - recent[0].t) * 1000, 16)
        let vx = recent.reduce(0) { $0 + $1.dx } / span, vy = recent.reduce(0) { $0 + $1.dy } / span
        guard hypot(vx, vy) > 0.25 else { return }
        mv = CGPoint(x: vx, y: vy)
        momFirst = true
        momLast = CACurrentMediaTime()
        let dl = CADisplayLink(target: self, selector: #selector(stepMomentum))
        dl.add(to: .main, forMode: .common)
        display = dl
    }

    @objc private func stepMomentum() {
        let now = CACurrentMediaTime()
        let dt = min((now - momLast) * 1000, 34)
        momLast = now
        let f = CGFloat(pow(0.9965, dt))
        mv.x *= f; mv.y *= f
        if hypot(mv.x, mv.y) < 0.03 { stopMomentum(); return }
        scroll(0, momFirst ? 1 : 2, mv.x * dt, mv.y * dt)
        momFirst = false
    }

    private func stopMomentum() {
        guard let display else { return }
        display.invalidate()
        self.display = nil
        link.send("s 0 3 0 0")
    }
}

struct Trackpad: UIViewRepresentable {
    var onFirstTouch: () -> Void
    func makeUIView(context: Context) -> TrackpadView {
        let v = TrackpadView()
        v.onFirstTouch = onFirstTouch
        return v
    }
    func updateUIView(_ v: TrackpadView, context: Context) {}
}

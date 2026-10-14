// Fundos do trackpad: prontos (animados via Core Animation, leves) ou mídia própria (GIF, imagem, vídeo).

import SwiftUI
import UIKit
import AVFoundation
import ImageIO

struct Preset: Identifiable {
    let id: String
    let name: String
    var light = false
}

let presets = [
    Preset(id: "grafite", name: "Grafite"), Preset(id: "aluminio", name: "Alumínio", light: true),
    Preset(id: "oceano", name: "Oceano"), Preset(id: "sunset", name: "Pôr do sol", light: true),
    Preset(id: "aurora", name: "Aurora"), Preset(id: "neon", name: "Neon"), Preset(id: "lava", name: "Lava"),
]

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: alpha)
    }
}

struct SkinView: View {
    let id: String
    var customURL = ""
    var version = 0

    var body: some View {
        switch id {
        case "aluminio":
            LinearGradient(colors: [Color(hex: 0xdfe2e6), Color(hex: 0xb4b9c1)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "oceano":
            LinearGradient(colors: [Color(hex: 0x0f2027), Color(hex: 0x203a43), Color(hex: 0x2c5364)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "sunset":
            LinearGradient(colors: [Color(hex: 0xff5f6d), Color(hex: 0xffc371)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "aurora":
            Blobs(base: Color(hex: 0x060a14), period: 22, blobs: [
                (Color(hex: 0x00ffa3, alpha: 0.55), 0.32, 0.40), (Color(hex: 0x7a5cff, alpha: 0.55), 0.68, 0.58), (Color(hex: 0x00b3ff, alpha: 0.5), 0.5, 0.28),
            ])
        case "lava":
            Blobs(base: Color(hex: 0x1a0500), period: 30, reverse: true, blobs: [
                (Color(hex: 0xff4d00, alpha: 0.63), 0.35, 0.35), (Color(hex: 0xff0055, alpha: 0.63), 0.65, 0.6), (Color(hex: 0xffb300, alpha: 0.63), 0.45, 0.7),
            ])
        case "neon":
            NeonGrid()
        case "url":
            MediaView(source: .remote(customURL))
        case "photo":
            MediaView(source: .file(Settings.photoURL, version))
        default:
            RadialGradient(colors: [Color(hex: 0x1e1e24), Color(hex: 0x141417)], center: .top, startRadius: 0, endRadius: 700)
        }
    }
}

/// Manchas de gradiente girando lentamente (uma única animação de rotação, composta na GPU).
private struct Blobs: View {
    let base: Color
    let period: Double
    var reverse = false
    let blobs: [(Color, CGFloat, CGFloat)]
    @State private var on = false

    var body: some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height) * 2.2
            ZStack {
                ForEach(blobs.indices, id: \.self) { i in
                    RadialGradient(colors: [blobs[i].0, blobs[i].0.opacity(0)], center: UnitPoint(x: blobs[i].1, y: blobs[i].2),
                                   startRadius: 0, endRadius: side * 0.28)
                }
            }
            .frame(width: side, height: side)
            .rotationEffect(.degrees(on ? (reverse ? -360 : 360) : 0))
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .background(base)
        .clipped()
        .onAppear { withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) { on = true } }
    }
}

private struct NeonGrid: View {
    @State private var on = false

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                var v = Path(), h = Path()
                for x in stride(from: 0, through: size.width, by: 40) { v.move(to: CGPoint(x: x, y: 0)); v.addLine(to: CGPoint(x: x, y: size.height)) }
                for y in stride(from: 0, through: size.height, by: 40) { h.move(to: CGPoint(x: 0, y: y)); h.addLine(to: CGPoint(x: size.width, y: y)) }
                ctx.stroke(v, with: .color(Color(hex: 0x00e5ff, alpha: 0.32)), lineWidth: 1)
                ctx.stroke(h, with: .color(Color(hex: 0xff2bd6, alpha: 0.32)), lineWidth: 1)
            }
            .frame(width: geo.size.width, height: geo.size.height + 40)
            .offset(y: on ? 0 : -40)
        }
        .background(LinearGradient(colors: [Color(hex: 0x0b0620), Color(hex: 0x22093f)], startPoint: .top, endPoint: .bottom))
        .clipped()
        .onAppear { withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { on = true } }
    }
}

// MARK: mídia própria

enum MediaSource: Equatable {
    case remote(String)
    case file(URL, Int)
}

struct MediaView: UIViewRepresentable {
    let source: MediaSource
    func makeUIView(context: Context) -> MediaUIView { MediaUIView() }
    func updateUIView(_ v: MediaUIView, context: Context) { v.load(source) }
}

final class MediaUIView: UIView {
    private let imageView = UIImageView()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var current: MediaSource?
    private var token = UUID()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        playerLayer?.frame = bounds
    }

    func load(_ source: MediaSource) {
        guard source != current else { return }
        current = source
        token = UUID()
        imageView.image = nil
        player?.pause()
        playerLayer?.removeFromSuperlayer()
        player = nil; looper = nil; playerLayer = nil

        switch source {
        case .remote(let s):
            log("carregando \(s)")
            guard let url = URL(string: s) else { return report("URL inválida: \(s)") }
            if ["mp4", "mov", "m4v", "webm"].contains(url.pathExtension.lowercased()) { return play(url) }
            let t = token
            URLSession.shared.dataTask(with: url) { [weak self] data, resp, err in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let type = resp?.mimeType ?? "?"
                DispatchQueue.main.async {
                    guard let self, self.token == t else { return }
                    if let err { return self.report("Erro de rede: \(err.localizedDescription)") }
                    guard let data, (200..<300).contains(code) else { return self.report("O servidor respondeu HTTP \(code).") }
                    self.log("recebido \(data.count) bytes, \(type)")
                    self.show(data)
                }
            }.resume()
        case .file(let url, _):
            guard let data = try? Data(contentsOf: url) else { return report("Arquivo da galeria não encontrado.") }
            show(data)
        }
    }

    private func show(_ data: Data) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0 else {
            return report("Isso não é uma imagem (talvez seja a página do site, não o arquivo).")
        }
        let frames = CGImageSourceGetCount(src)
        if frames > 1 {
            let t = token
            let status = CGAnimateImageDataWithBlock(data as CFData, nil) { [weak self] _, img, stop in
                guard let self, self.token == t else { stop.pointee = true; return }
                self.imageView.image = UIImage(cgImage: img)
            }
            if status != noErr { return report("Falha ao animar o GIF (código \(status)).") }
        } else {
            imageView.image = UIImage(data: data)
        }
        report(frames > 1 ? "GIF carregado (\(frames) quadros)." : "Imagem carregada.", ok: true)
    }

    private func log(_ s: String) { print("[TracePad skin] \(s)") }

    private func report(_ s: String, ok: Bool = false) {
        log(s)
        Settings.shared.skinStatus = (ok ? "✓ " : "⚠️ ") + s
    }

    private func play(_ url: URL) {
        let item = AVPlayerItem(url: url)
        let p = AVQueuePlayer()
        p.isMuted = true
        looper = AVPlayerLooper(player: p, templateItem: item)
        let l = AVPlayerLayer(player: p)
        l.videoGravity = .resizeAspectFill
        l.frame = bounds
        layer.addSublayer(l)
        player = p
        playerLayer = l
        p.play()
        report("Vídeo carregado.", ok: true)
    }
}

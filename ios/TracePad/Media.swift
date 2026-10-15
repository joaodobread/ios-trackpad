// Modos "Tocando agora" (capa, faixa e controles do player do computador) e "Apresentação"
// (passar slides com botões grandes ou os botões de volume, cronômetro e laser pelo giroscópio).

import SwiftUI
import AVFoundation
import MediaPlayer
import CoreMotion

private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
    if Settings.shared.haptics { UIImpactFeedbackGenerator(style: style).impactOccurred() }
}

private func time(_ s: Double) -> String {
    let t = Int(s.rounded(.down))
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}

// MARK: - Tocando agora

struct NowPlayingView: View {
    @ObservedObject private var link = Link.shared

    var body: some View {
        if link.transport == .none {
            Disconnected()
        } else if let np = link.nowPlaying {
            player(np)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "music.note").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Nada tocando no computador").font(.headline)
                Text(link.hostOS == "linux" ? "Players com MPRIS (Spotify, navegador, mpv…) aparecem aqui. Precisa do playerctl."
                     : "Qualquer player aparece aqui; no macOS recente, só Música e Spotify.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
                controls(playing: false).padding(.top, 12)
            }
            .padding()
        }
    }

    private func player(_ np: NowPlayingInfo) -> some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height
            let side = min(wide ? geo.size.height - 60 : geo.size.width - 64, 360)
            let layout = wide ? AnyLayout(HStackLayout(spacing: 32)) : AnyLayout(VStackLayout(spacing: 24))
            layout {
                cover.frame(width: side, height: side)
                VStack(spacing: 18) {
                    VStack(spacing: 4) {
                        Text(np.title).font(.title3.weight(.semibold)).lineLimit(2)
                        Text([np.artist, np.album].filter { !$0.isEmpty }.joined(separator: " — ")).foregroundStyle(.secondary).lineLimit(2)
                        if !np.app.isEmpty { Text(np.app).font(.caption).foregroundStyle(.tertiary) }
                    }
                    .multilineTextAlignment(.center)
                    progress(np)
                    controls(playing: np.playing)
                }
                .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 30)
        }
        .padding(.horizontal, 24)
    }

    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.08))
            if let img = link.artwork {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note").font(.system(size: 60)).foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }

    private func progress(_ np: NowPlayingInfo) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            if let d = np.duration, d > 0, let p = np.elapsed(ctx.date) {
                VStack(spacing: 4) {
                    ProgressView(value: min(p / d, 1)).tint(.white)
                    HStack {
                        Text(time(p))
                        Spacer()
                        Text("-" + time(max(d - p, 0)))
                    }
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func controls(playing: Bool) -> some View {
        HStack(spacing: 36) {
            button("backward.fill", 26) { link.send("x 18") }
            button(playing ? "pause.fill" : "play.fill", 40) { link.send("x 16") }
            button("forward.fill", 26) { link.send("x 17") }
        }
    }

    private func button(_ symbol: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button {
            action()
            haptic()
        } label: {
            Image(systemName: symbol).font(.system(size: size)).frame(width: 64, height: 64).contentShape(Rectangle())
        }
        .foregroundStyle(.white)
    }
}

// MARK: - Apresentação

struct PresentationView: View {
    @ObservedObject private var link = Link.shared
    @StateObject private var volume = VolumeButtons()
    @StateObject private var laser = Laser()
    @State private var start: Date?
    @State private var paused: Double = 0 // segundos acumulados antes da última pausa
    @State private var running = false

    var body: some View {
        if link.transport == .none {
            Disconnected()
        } else {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    timer
                    Spacer()
                    pill("play.rectangle", "Iniciar") { startShow() }
                    pill("xmark", "Sair") { link.send("k 53") }
                    pill("rectangle.fill", "Tela preta") { link.send("k 11") } // B: Keynote, PowerPoint, Impress
                }
                GeometryReader { geo in
                    HStack(spacing: 14) { // "próximo" maior: é o que mais se usa
                        slide("chevron.left", "Anterior") { previous() }
                            .frame(width: (geo.size.width - 14) * 0.38)
                        slide("chevron.right", "Próximo") { next() }
                    }
                }
                laserButton
                Text("Botões de volume também passam os slides (+ próximo, − anterior).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 48)
            .padding(.bottom, 12)
            .background(VolumeHUDHider().frame(width: 1, height: 1).opacity(0.01))
            .onAppear {
                volume.onPress = { up in up ? next() : previous() }
                volume.start()
            }
            .onDisappear {
                volume.stop()
                laser.stop()
            }
        }
    }

    private func next() { link.send("k 124"); haptic(.medium) }
    private func previous() { link.send("k 123"); haptic(.medium) }

    /// Começa a apresentação: Keynote (⌥⌘P) no Mac, F5 (LibreOffice, PowerPoint, Google Slides em tela cheia) nos outros.
    private func startShow() {
        link.send(link.hostOS == "mac" || link.hostOS == nil ? "k 35 ac" : "k 96")
        haptic()
        if !running { toggleTimer() }
    }

    private func toggleTimer() {
        if running {
            paused += Date().timeIntervalSince(start ?? Date())
            start = nil
        } else {
            start = Date()
        }
        running.toggle()
        haptic()
    }

    private var timer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let t = paused + (start.map { ctx.date.timeIntervalSince($0) } ?? 0)
            HStack(spacing: 8) {
                Text(time(t)).font(.title2.monospacedDigit().weight(.semibold))
                Image(systemName: running ? "pause.fill" : "play.fill").font(.caption)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .onTapGesture { toggleTimer() }
            .onLongPressGesture { paused = 0; start = running ? Date() : nil; haptic(.heavy) }
        }
    }

    private func pill(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.footnote.weight(.medium)).labelStyle(.titleAndIcon)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .foregroundStyle(.white)
    }

    private func slide(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 44, weight: .semibold))
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .contentShape(Rectangle())
        }
        .foregroundStyle(.white)
    }

    /// Segure para mover o cursor apontando o iPhone.
    private var laserButton: some View {
        Text(laser.active ? "Movendo o cursor…" : "Segure para apontar (laser)")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(laser.active ? Color.red.opacity(0.75) : .white.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(alignment: .leading) { Image(systemName: "dot.radiowaves.left.and.right").font(.title3).padding(.leading, 18) }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !laser.active { laser.start(); haptic() } }
                    .onEnded { _ in laser.stop() }
            )
    }
}

/// Botões de volume: o volume do sistema muda, a gente percebe e devolve ao meio (para sempre ter
/// espaço para os dois lados). Precisa de uma sessão de áudio ativa (não toca nada).
final class VolumeButtons: ObservableObject {
    var onPress: (Bool) -> Void = { _ in }
    private var observation: NSKeyValueObservation?
    private var resetting = false
    private let middle: Float = 0.5

    func start() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.ambient, options: .mixWithOthers)
        try? s.setActive(true)
        set(middle)
        observation = s.observe(\.outputVolume, options: [.old, .new]) { [weak self] _, ch in
            guard let self, let new = ch.newValue, let old = ch.oldValue else { return }
            DispatchQueue.main.async {
                if self.resetting { self.resetting = abs(new - self.middle) > 0.001; return }
                guard abs(new - old) > 0.001 else { return }
                self.onPress(new > old)
                self.set(self.middle)
            }
        }
    }

    func stop() {
        observation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func set(_ v: Float) {
        guard abs(AVAudioSession.sharedInstance().outputVolume - v) > 0.001 else { return }
        resetting = true
        VolumeHUDHider.slider?.value = v
    }
}

/// MPVolumeView fora de vista: esconde o aviso de volume do sistema e dá acesso ao controle de volume.
struct VolumeHUDHider: UIViewRepresentable {
    static weak var slider: UISlider?

    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 10, height: 10))
        DispatchQueue.main.async { VolumeHUDHider.slider = v.subviews.compactMap { $0 as? UISlider }.first }
        return v
    }

    func updateUIView(_ v: MPVolumeView, context: Context) {}
}

/// Giroscópio → movimento do cursor (girar para os lados = horizontal, inclinar = vertical).
final class Laser: ObservableObject {
    @Published private(set) var active = false
    private let motion = CMMotionManager()

    func start() {
        guard motion.isGyroAvailable, !active else { return }
        active = true
        motion.gyroUpdateInterval = 1 / 60
        motion.startGyroUpdates(to: .main) { data, _ in
            guard let r = data?.rotationRate else { return }
            let gain = 18 * Settings.shared.speed
            let dx = -r.z * gain, dy = -r.x * gain
            if abs(dx) + abs(dy) > 0.3 { Link.shared.move(dx, dy) }
        }
    }

    func stop() {
        guard active else { return }
        active = false
        motion.stopGyroUpdates()
    }
}

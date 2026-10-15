// Painel lateral (aberto pelo botão no topo): brilho, volume, mudo, mídia, área de transferência e arquivos.

import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct ControlDrawer: View {
    @ObservedObject private var link = Link.shared
    @Binding var open: Bool
    @State private var drag: CGFloat = 0
    @State private var photos = [PhotosPickerItem]()
    @State private var importing = false
    private let width: CGFloat = 250

    var body: some View {
        // ignora a margem segura lateral e soma ela à mão: fechada, a aba precisa sair também
        // da faixa da Dynamic Island, senão sobra um pedaço do painel na tela
        GeometryReader { geo in
            drawer(inset: geo.safeAreaInsets.trailing)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .ignoresSafeArea(edges: .horizontal)
    }

    private func drawer(inset: CGFloat) -> some View {
        let hidden = width + 10 + inset // largura total do painel com margens
        return ZStack(alignment: .trailing) {
            if open {
                // toque fora fecha (sem clicar no Mac)
                Color.black.opacity(0.25).ignoresSafeArea()
                    .onTapGesture { setOpen(false) }
                    .transition(.opacity)
            }
            panel.padding(.trailing, inset)
            .offset(x: max(0, (open ? 0 : hidden) + drag))
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { g in drag = open ? max(0, g.translation.width) : min(0, g.translation.width) }
                    .onEnded { g in
                        let end = (open ? 0 : hidden) + g.predictedEndTranslation.width
                        drag = 0
                        setOpen(end < hidden / 2)
                    }
            )
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: open)
        .onChange(of: open) { _, v in if v { link.send("q") } }
        .onChange(of: photos) { _, items in sendPhotos(items) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { sendFile($0) }
        .animation(.interactiveSpring, value: drag)
    }

    private func setOpen(_ v: Bool) {
        if v != open, Settings.shared.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        open = v
    }

    private var volumeIcon: String {
        guard !link.muted, let v = link.volume else { return "speaker.slash.fill" }
        return v < 0.01 ? "speaker.fill" : v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    private var panel: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                VSlider(icon: "sun.max.fill", value: link.brightness) { link.send(String(format: "b %.3f", $0)) }
                VSlider(icon: volumeIcon, value: link.volume) { link.send(String(format: "v %.3f", $0)) }
            }
            HStack(spacing: 10) {
                round(link.muted ? "speaker.slash.fill" : "speaker.fill", active: link.muted) { link.send("z") }
                round("backward.fill") { link.send("x 18") }
                round("playpause.fill") { link.send("x 16") }
                round("forward.fill") { link.send("x 17") }
            }
            HStack(alignment: .top, spacing: 10) {
                labeled("doc.on.clipboard", "Copiar do PC") { link.pullClipboard() }
                labeled("arrow.up.doc.on.clipboard", "Colar no PC") { link.pushClipboard() }
                PhotosPicker(selection: $photos, maxSelectionCount: 10) {
                    caption(icon("photo.on.rectangle"), "Fotos")
                }
                labeled("folder", "Arquivo") { importing = true }
            }
        }
        .padding(16)
        .frame(width: width)
        .frame(maxHeight: 430)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.vertical, 12)
        .padding(.trailing, 10)
    }

    private func round(_ symbol: String, active: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button {
            action()
            if Settings.shared.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        } label: {
            icon(symbol, active: active)
        }
    }

    private func icon(_ symbol: String, active: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 46, height: 46)
            .background(active ? Color.white : Color.white.opacity(0.14), in: Circle())
            .foregroundStyle(active ? Color.black : .white)
    }

    private func caption(_ v: some View, _ text: String) -> some View {
        VStack(spacing: 4) {
            v
            Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                .multilineTextAlignment(.center).frame(width: 50)
        }
    }

    private func labeled(_ symbol: String, _ text: String, _ action: @escaping () -> Void) -> some View {
        Button {
            action()
            if Settings.shared.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        } label: {
            caption(icon(symbol), text)
        }
    }

    /// Fotos e vídeos vão um depois do outro (o envio seguinte começa quando o anterior termina).
    private func sendPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photos = []
        setOpen(false)
        Task { @MainActor in
            for (i, item) in items.enumerated() {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "-")
                while link.transferProgress != nil { try? await Task.sleep(for: .milliseconds(200)) }
                link.sendFile(name: "iPhone \(stamp)\(items.count > 1 ? "-\(i + 1)" : "").\(ext)", data: data)
            }
        }
    }

    private func sendFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return link.show("Não consegui ler o arquivo") }
        setOpen(false)
        link.sendFile(name: url.lastPathComponent, data: data)
    }
}

/// Barra vertical no estilo da Central de Controle: arrasto relativo, haptic a cada 1/16 (passo do volume do Mac).
private struct VSlider: View {
    let icon: String
    let value: Double?
    let onChange: (Double) -> Void
    @State private var local: Double = 0
    @State private var start: Double?
    private let tick = UISelectionFeedbackGenerator()

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Rectangle().fill(.white.opacity(0.12))
                Rectangle().fill(.white.opacity(0.92)).frame(height: geo.size.height * local)
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(local > 0.14 ? Color.black.opacity(0.75) : .white)
                    .padding(.bottom, 16)
                if value == nil {
                    Text("Indisponível").font(.caption2).foregroundStyle(.white.opacity(0.7))
                        .frame(maxHeight: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if start == nil { start = local; tick.prepare() }
                        let v = min(max(start! - g.translation.height / geo.size.height * 1.2, 0), 1)
                        if Int(v * 16) != Int(local * 16), Settings.shared.haptics { tick.selectionChanged() }
                        local = v
                        onChange(v)
                    }
                    .onEnded { _ in start = nil }
            )
        }
        .opacity(value == nil ? 0.4 : 1)
        .disabled(value == nil)
        .onAppear { local = value ?? 0 }
        .onChange(of: value) { _, v in if start == nil, let v { local = v } }
    }
}

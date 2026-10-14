// Modos além do trackpad: monitor de consumo do Mac e alternador de apps (⌘-Tab).

import SwiftUI
import UIKit

private func bytes(_ v: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(max(v, 0)), countStyle: .memory)
}

private func rate(_ v: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(max(v, 0)), countStyle: .decimal) + "/s"
}

private func levelColor(_ v: Double) -> Color {
    v < 0.6 ? Color(hex: 0x34c759) : v < 0.85 ? Color(hex: 0xffcc00) : Color(hex: 0xff453a)
}

/// Aviso quando não há Mac conectado.
struct Disconnected: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "cable.connector.slash").font(.largeTitle)
            Text("Conecte ao computador por USB ou Bluetooth").font(.callout)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Monitor

struct MonitorView: View {
    @ObservedObject private var link = Link.shared

    var body: some View {
        Group {
            if link.transport == .none {
                Disconnected()
            } else if let s = link.stats {
                content(s)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ s: MacStats) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    Gauge(title: "CPU", value: s.cpu, detail: "\(s.cores) núcleos")
                    Gauge(title: "GPU", value: s.gpu, detail: s.gpu == nil ? "indisponível" : "uso")
                    Gauge(title: "Memória", value: s.memUsed / max(s.memTotal, 1), detail: "\(bytes(s.memUsed)) de \(bytes(s.memTotal))")
                    Gauge(title: "Disco", value: s.diskUsed / max(s.diskTotal, 1), detail: "\(bytes(s.diskTotal - s.diskUsed)) livres")
                }
                HStack(spacing: 14) {
                    card {
                        Label("Rede", systemImage: "network").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text("↓ \(rate(s.netIn))").font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
                        Text("↑ \(rate(s.netOut))").font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
                    }
                    if let b = s.battery {
                        card {
                            Label("Bateria", systemImage: s.charging ? "battery.100.bolt" : "battery.75").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text("\(Int(b * 100))%").font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                            Text(s.charging ? "carregando" : "na bateria").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    card {
                        Label("CPU · 60 s", systemImage: "waveform.path.ecg").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Sparkline(values: link.cpuHistory).stroke(levelColor(s.cpu), lineWidth: 2).frame(height: 44)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            card {
                Label("Processos", systemImage: "list.bullet").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(link.processes) { p in
                    HStack {
                        Text(p.name).lineLimit(1).font(.caption)
                        Spacer(minLength: 6)
                        Text(String(format: "%.0f%%", p.cpu * 100)).font(.caption.monospacedDigit()).foregroundStyle(levelColor(p.cpu / Double(max(s.cores, 1)) * 4))
                        Text(bytes(p.mem)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 62, alignment: .trailing)
                    }
                }
            }
            .frame(width: 270)
        }
        .padding(.horizontal, 16)
        .padding(.top, 50)
        .padding(.bottom, 12)
    }

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6, content: c)
            .padding(14)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct Gauge: View {
    let title: String
    let value: Double?
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.white.opacity(0.1), lineWidth: 11)
                Circle()
                    .trim(from: 0, to: min(max(value ?? 0, 0), 1))
                    .stroke(levelColor(value ?? 0), style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: value)
                Text(value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .contentTransition(.numericText())
            }
            .padding(6)
            Text(title).font(.caption.weight(.semibold))
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct Sparkline: Shape {
    let values: [Double]
    func path(in r: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let step = r.width / CGFloat(59)
        let x0 = r.maxX - step * CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let pt = CGPoint(x: x0 + step * CGFloat(i), y: r.maxY - r.height * CGFloat(min(max(v, 0), 1)))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }
}

// MARK: - Apps

struct AppsView: View {
    @ObservedObject private var link = Link.shared
    @State private var picking: MacApp?
    @State private var launcher = false
    @State private var query = ""
    private let tap = UIImpactFeedbackGenerator(style: .rigid)

    var body: some View {
        Group {
            if link.transport == .none {
                Disconnected()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 12) {
                        ForEach(link.apps) { app in tile(app) }
                        addTile
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 54)
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.hidden)
            }
            if let app = picking { windowPicker(app) }
            if launcher { launcherView }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: picking?.pid)
        .animation(.easeOut(duration: 0.18), value: launcher)
    }

    private var addTile: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 26, weight: .medium))
                .frame(width: 64, height: 64)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("Abrir app").font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            query = ""
            link.send("L")
            launcher = true
            haptic()
        }
    }

    /// Apps instalados no Mac, com busca. Ícones carregam conforme aparecem.
    private var launcherView: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? link.installed : link.installed.filter { $0.name.localizedCaseInsensitiveContains(q) }
        return ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { launcher = false }
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Buscar app no Mac", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.go)
                        .onSubmit { if let first = list.first { launch(first) } }
                    Button { launcher = false } label: { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                if link.installed.isEmpty {
                    ProgressView().tint(.white).frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                            ForEach(list) { app in
                                VStack(spacing: 4) {
                                    Group {
                                        if let img = link.installedIcons[app.name] {
                                            Image(uiImage: img).resizable().interpolation(.high)
                                        } else {
                                            RoundedRectangle(cornerRadius: 11).fill(.white.opacity(0.1))
                                        }
                                    }
                                    .frame(width: 48, height: 48)
                                    Text(app.name).font(.caption2).lineLimit(1)
                                    Circle().fill(app.running ? Color.white.opacity(0.7) : .clear).frame(width: 4, height: 4)
                                }
                                .padding(6)
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                                .onAppear { link.requestIcon(app) }
                                .onTapGesture { launch(app) }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.immediately)
                }
            }
            .padding(14)
            .frame(maxWidth: 640, maxHeight: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.top, 48).padding(.bottom, 10)
        }
        .transition(.opacity)
    }

    private func launch(_ app: InstalledApp) {
        link.send("o \(app.id)")
        haptic()
        launcher = false
    }

    private func haptic() { if Settings.shared.haptics { tap.impactOccurred(intensity: 0.8) } }

    /// Mais de uma janela: escolhe qual focar.
    private func open(_ app: MacApp) {
        guard app.windows > 1 else { link.send("a \(app.pid)"); return }
        link.clearWindows()
        link.send("W \(app.pid)")
        picking = app
    }

    private func windowPicker(_ app: MacApp) -> some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { picking = nil }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if let img = link.icons[app.key] { Image(uiImage: img).resizable().frame(width: 32, height: 32) }
                    Text(app.name).font(.headline)
                    Spacer()
                    Button { picking = nil } label: { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary) }
                }
                if let w = link.windows, w.pid == app.pid {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(w.list) { win in
                                Button {
                                    link.send("f \(app.pid) \(win.id) \(win.title)")
                                    haptic()
                                    picking = nil
                                } label: {
                                    HStack {
                                        Image(systemName: win.minimized ? "minus.square" : "macwindow")
                                        Text(win.title).lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 12)
                                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .opacity(win.minimized ? 0.6 : 1)
                                }
                                .foregroundStyle(.white)
                            }
                        }
                    }
                    .frame(maxHeight: 230)
                } else {
                    ProgressView().tint(.white).frame(maxWidth: .infinity).padding()
                }
            }
            .padding(16)
            .frame(width: 420)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .transition(.opacity)
    }

    private func tile(_ app: MacApp) -> some View {
        VStack(spacing: 6) {
            Group {
                if let img = link.icons[app.key] {
                    Image(uiImage: img).resizable().interpolation(.high)
                } else {
                    RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.12))
                        .overlay(Text(String(app.name.prefix(1))).font(.title2.bold()))
                }
            }
            .frame(width: 64, height: 64)
            .opacity(app.hidden ? 0.45 : 1)
            .overlay(alignment: .topTrailing) {
                if app.windows > 1 {
                    Text("\(app.windows)").font(.caption2.bold()).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                        .offset(x: 6, y: -4)
                }
            }
            Text(app.name).font(.caption).lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(app.active ? Color.white.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(app.active ? Color.white.opacity(0.5) : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture {
            open(app)
            haptic()
        }
        .contextMenu {
            Button { link.send("a \(app.pid)") } label: { Label("Trazer para frente", systemImage: "macwindow") }
            if app.windows > 1 {
                Button { open(app) } label: { Label("Escolher janela…", systemImage: "rectangle.on.rectangle") }
            }
            Button { link.send("h \(app.pid)") } label: { Label("Ocultar", systemImage: "eye.slash") }
            Button(role: .destructive) { link.send("Q \(app.pid)") } label: { Label("Encerrar", systemImage: "xmark.circle") }
        }
    }
}

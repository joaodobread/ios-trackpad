// Gestos configuráveis: cada gesto de 3/4 dedos e a pinça usam o padrão do computador ("g nome",
// traduzido pelo host — no Linux dá para redefinir em ~/.tracepad-actions), nada, ou uma ação própria.
// A configuração é separada por sistema (Mac/Linux): vale a do computador conectado.

import SwiftUI

struct GestureBinding: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable { case standard, none, action }
    var mode = Mode.standard
    var action = CustomAction.new()
}

struct GestureSlot: Identifiable {
    let id: String
    let title: String
    let icon: String
    /// nome do gesto padrão no protocolo ("g nome") e descrição no Mac e no Linux; nil = nenhum
    let standard: String?
    let standardTitle: String
    var linuxTitle: String? = nil
    var windowsTitle: String? = nil

    func title(_ os: String) -> String {
        switch os {
        case "linux": linuxTitle ?? standardTitle
        case "windows": windowsTitle ?? linuxTitle ?? standardTitle
        default: standardTitle
        }
    }
}

final class GestureStore: ObservableObject {
    static let shared = GestureStore()
    private let key = "gestures.v2"

    static let slots: [GestureSlot] = [
        .init(id: "3.up", title: "3 dedos ↑", icon: "arrow.up", standard: "mission", standardTitle: "Mission Control", linuxTitle: "Visão geral (Super)", windowsTitle: "Visão de tarefas (Win+Tab)"),
        .init(id: "3.down", title: "3 dedos ↓", icon: "arrow.down", standard: "expose", standardTitle: "App Exposé", linuxTitle: "Visão geral (Super)", windowsTitle: "Visão de tarefas (Win+Tab)"),
        .init(id: "3.left", title: "3 dedos ←", icon: "arrow.left", standard: "space-right", standardTitle: "Mesa à direita", linuxTitle: "Mesa à direita (Ctrl+Alt+→)", windowsTitle: "Área à direita (Ctrl+Win+→)"),
        .init(id: "3.right", title: "3 dedos →", icon: "arrow.right", standard: "space-left", standardTitle: "Mesa à esquerda", linuxTitle: "Mesa à esquerda (Ctrl+Alt+←)", windowsTitle: "Área à esquerda (Ctrl+Win+←)"),
        .init(id: "3.tap", title: "Toque com 3 dedos", icon: "hand.tap", standard: "lookup", standardTitle: "Consultar", linuxTitle: "Nada"),
        .init(id: "4.up", title: "4 dedos ↑", icon: "arrow.up", standard: "mission", standardTitle: "Mission Control", linuxTitle: "Visão geral (Super)", windowsTitle: "Visão de tarefas (Win+Tab)"),
        .init(id: "4.down", title: "4 dedos ↓", icon: "arrow.down", standard: "desktop", standardTitle: "Mostrar mesa", linuxTitle: "Mostrar mesa (Super+D)", windowsTitle: "Mostrar área de trabalho (Win+D)"),
        .init(id: "4.left", title: "4 dedos ←", icon: "arrow.left", standard: "space-right", standardTitle: "Mesa à direita", linuxTitle: "Mesa à direita (Ctrl+Alt+→)", windowsTitle: "Área à direita (Ctrl+Win+→)"),
        .init(id: "4.right", title: "4 dedos →", icon: "arrow.right", standard: "space-left", standardTitle: "Mesa à esquerda", linuxTitle: "Mesa à esquerda (Ctrl+Alt+←)", windowsTitle: "Área à esquerda (Ctrl+Win+←)"),
        .init(id: "4.tap", title: "Toque com 4 dedos", icon: "hand.tap", standard: nil, standardTitle: "Nada"),
        .init(id: "pinch.open", title: "Pinça abrir", icon: "arrow.up.left.and.arrow.down.right", standard: "zoom-in", standardTitle: "Aumentar zoom", linuxTitle: "Aumentar zoom (Ctrl+=)"),
        .init(id: "pinch.close", title: "Pinça fechar", icon: "arrow.down.right.and.arrow.up.left", standard: "zoom-out", standardTitle: "Diminuir zoom", linuxTitle: "Diminuir zoom (Ctrl+−)"),
    ]

    static let systems = [("mac", "Mac"), ("linux", "Linux"), ("windows", "Windows")]

    /// Sistema do computador ativo (sem anúncio = Mac, como os hosts antigos).
    static var currentOS: String { ["linux", "windows"].contains(Link.shared.hostOS) ? Link.shared.hostOS! : "mac" }

    /// sistema → gesto → configuração
    @Published var bindings: [String: [String: GestureBinding]] {
        didSet { if let d = try? JSONEncoder().encode(bindings) { UserDefaults.standard.set(d, forKey: key) } }
    }

    private init() {
        let d = UserDefaults.standard
        if let v2 = d.data(forKey: key).flatMap({ try? JSONDecoder().decode([String: [String: GestureBinding]].self, from: $0) }) {
            bindings = v2
        } else if let v1 = d.data(forKey: "gestures").flatMap({ try? JSONDecoder().decode([String: GestureBinding].self, from: $0) }) {
            bindings = ["mac": v1, "linux": v1, "windows": v1] // antes de separar por sistema
        } else {
            bindings = [:]
        }
    }

    func binding(_ id: String, os: String = GestureStore.currentOS) -> GestureBinding { bindings[os]?[id] ?? GestureBinding() }

    func set(_ id: String, os: String, _ b: GestureBinding) { bindings[os, default: [:]][id] = b }

    func isCustom(_ id: String) -> Bool { binding(id).mode == .action }

    /// Envia o gesto. `standard` pode substituir o padrão do slot (ex.: 4 dedos ↓ com "arrastar com 3 dedos").
    /// Devolve false quando não mandou nada (para não vibrar à toa).
    @discardableResult
    func perform(_ id: String, standard: String? = nil) -> Bool {
        let b = binding(id)
        switch b.mode {
        case .none: return false
        case .action:
            guard let c = b.action.command else { return false }
            Link.shared.send(c)
            return true
        case .standard:
            guard let name = standard ?? GestureStore.slots.first(where: { $0.id == id })?.standard else { return false }
            Link.shared.send("g " + name)
            return true
        }
    }

    func summary(_ slot: GestureSlot, os: String) -> String {
        let b = binding(slot.id, os: os)
        switch b.mode {
        case .standard: return slot.title(os)
        case .none: return "Nada"
        case .action: return b.action.name.isEmpty ? b.action.detail : b.action.name
        }
    }
}

// MARK: - Ajustes

struct GesturesView: View {
    @ObservedObject private var store = GestureStore.shared
    @State private var os = GestureStore.currentOS

    var body: some View {
        Form {
            Section {
                Picker("Sistema", selection: $os) {
                    ForEach(GestureStore.systems, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } footer: {
                Text("Cada sistema tem sua configuração; vale a do computador conectado.")
            }
            Section {
                ForEach(GestureStore.slots) { slot in
                    NavigationLink {
                        GestureEditor(slot: slot, os: os)
                    } label: {
                        LabeledContent {
                            Text(store.summary(slot, os: os)).foregroundStyle(store.binding(slot.id, os: os).mode == .standard ? .secondary : Color.accentColor)
                        } label: {
                            Label(slot.title, systemImage: slot.icon)
                        }
                    }
                }
            } footer: {
                Text("Padrão: o computador decide. No Mac são os atalhos do sistema; no Windows, Win+Tab, Ctrl+Win+←/→ e Win+D; no Linux, a visão geral (Super), Ctrl+Alt+←/→ e Super+D. No Linux e no Windows dá para redefinir no computador em ~/.tracepad-actions com linhas como “@mission = super+w” ou “@space-left = wmctrl -s 0”.")
            }
            if !(store.bindings[os] ?? [:]).isEmpty {
                Section { Button("Restaurar padrões do \(osName(os) ?? "Mac")", role: .destructive) { store.bindings[os] = nil } }
            }
        }
        .navigationTitle("Gestos")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct GestureEditor: View {
    let slot: GestureSlot
    let os: String
    @ObservedObject private var store = GestureStore.shared

    private var b: Binding<GestureBinding> {
        Binding(get: { store.binding(slot.id, os: os) }, set: { store.set(slot.id, os: os, $0) })
    }

    var body: some View {
        Form {
            Section {
                Picker("Ação", selection: b.mode) {
                    Text("Padrão").tag(GestureBinding.Mode.standard)
                    Text("Nada").tag(GestureBinding.Mode.none)
                    Text("Personalizada").tag(GestureBinding.Mode.action)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } footer: {
                if b.wrappedValue.mode == .standard {
                    Text(slot.standard.map { "\(slot.title(os)) (g \($0))." } ?? "Nada.")
                }
            }
            if b.wrappedValue.mode == .action {
                Section { TextField("Nome (opcional)", text: b.action.name) }
                ActionFields(action: b.action)
            }
        }
        .navigationTitle("\(slot.title) · \(osName(os) ?? "Mac")")
        .navigationBarTitleDisplayMode(.inline)
    }
}

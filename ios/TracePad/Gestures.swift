// Gestos configuráveis: cada gesto de 3/4 dedos e a pinça usam o padrão do computador ("g nome",
// traduzido pelo host — no Linux dá para redefinir em ~/.tracepad-actions), nada, ou uma ação própria.

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
    /// nome do gesto padrão no protocolo ("g nome") e descrição; nil = nenhum
    let standard: String?
    let standardTitle: String
}

final class GestureStore: ObservableObject {
    static let shared = GestureStore()
    private let key = "gestures"

    static let slots: [GestureSlot] = [
        .init(id: "3.up", title: "3 dedos ↑", icon: "arrow.up", standard: "mission", standardTitle: "Mission Control"),
        .init(id: "3.down", title: "3 dedos ↓", icon: "arrow.down", standard: "expose", standardTitle: "App Exposé"),
        .init(id: "3.left", title: "3 dedos ←", icon: "arrow.left", standard: "space-right", standardTitle: "Mesa à direita"),
        .init(id: "3.right", title: "3 dedos →", icon: "arrow.right", standard: "space-left", standardTitle: "Mesa à esquerda"),
        .init(id: "3.tap", title: "Toque com 3 dedos", icon: "hand.tap", standard: "lookup", standardTitle: "Consultar"),
        .init(id: "4.up", title: "4 dedos ↑", icon: "arrow.up", standard: "mission", standardTitle: "Mission Control"),
        .init(id: "4.down", title: "4 dedos ↓", icon: "arrow.down", standard: "desktop", standardTitle: "Mostrar mesa"),
        .init(id: "4.left", title: "4 dedos ←", icon: "arrow.left", standard: "space-right", standardTitle: "Mesa à direita"),
        .init(id: "4.right", title: "4 dedos →", icon: "arrow.right", standard: "space-left", standardTitle: "Mesa à esquerda"),
        .init(id: "4.tap", title: "Toque com 4 dedos", icon: "hand.tap", standard: nil, standardTitle: "Nada"),
        .init(id: "pinch.open", title: "Pinça abrir", icon: "arrow.up.left.and.arrow.down.right", standard: "zoom-in", standardTitle: "Aumentar zoom"),
        .init(id: "pinch.close", title: "Pinça fechar", icon: "arrow.down.right.and.arrow.up.left", standard: "zoom-out", standardTitle: "Diminuir zoom"),
    ]

    @Published var bindings: [String: GestureBinding] {
        didSet { if let d = try? JSONEncoder().encode(bindings) { UserDefaults.standard.set(d, forKey: key) } }
    }

    private init() {
        bindings = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([String: GestureBinding].self, from: $0) } ?? [:]
    }

    func binding(_ id: String) -> GestureBinding { bindings[id] ?? GestureBinding() }

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

    func summary(_ slot: GestureSlot) -> String {
        let b = binding(slot.id)
        switch b.mode {
        case .standard: return slot.standardTitle
        case .none: return "Nada"
        case .action: return b.action.name.isEmpty ? b.action.detail : b.action.name
        }
    }
}

// MARK: - Ajustes

struct GesturesView: View {
    @ObservedObject private var store = GestureStore.shared

    var body: some View {
        Form {
            Section {
                ForEach(GestureStore.slots) { slot in
                    NavigationLink {
                        GestureEditor(slot: slot)
                    } label: {
                        LabeledContent {
                            Text(store.summary(slot)).foregroundStyle(store.binding(slot.id).mode == .standard ? .secondary : Color.accentColor)
                        } label: {
                            Label(slot.title, systemImage: slot.icon)
                        }
                    }
                }
            } footer: {
                Text("Padrão: o computador decide. No Mac são os atalhos do sistema; no Linux, a visão geral (Super), Ctrl+Alt+←/→ e Super+D — redefinidos no computador em ~/.tracepad-actions com linhas como “@mission = super+w” ou “@space-left = wmctrl -s 0”.")
            }
            if !store.bindings.isEmpty {
                Section { Button("Restaurar padrões", role: .destructive) { store.bindings = [:] } }
            }
        }
        .navigationTitle("Gestos")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct GestureEditor: View {
    let slot: GestureSlot
    @ObservedObject private var store = GestureStore.shared

    private var b: Binding<GestureBinding> {
        Binding(get: { store.binding(slot.id) }, set: { store.bindings[slot.id] = $0 })
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
                    Text(slot.standard.map { "\(slot.standardTitle) (g \($0))." } ?? "Nada.")
                }
            }
            if b.wrappedValue.mode == .action {
                Section { TextField("Nome (opcional)", text: b.action.name) }
                ActionFields(action: b.action)
            }
        }
        .navigationTitle(slot.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

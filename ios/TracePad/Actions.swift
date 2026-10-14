// Modo Ações: grade de botões definidos no iPhone — atalho de teclado, texto, abrir URL/app
// ou comando de shell (definido no computador em ~/.tracepad-actions e chamado só pelo nome).

import SwiftUI
import UIKit

struct CustomAction: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case key, text, open, shell
        var title: String {
            switch self {
            case .key: "Atalho"
            case .text: "Texto"
            case .open: "Abrir"
            case .shell: "Comando"
            }
        }
    }

    var id = UUID()
    var name: String
    var icon: String
    var color: Int
    var kind: Kind
    /// tecla (rótulo do catálogo), texto, URL/app ou nome do comando, conforme o tipo
    var value: String
    /// modificadores do atalho: c=⌘ a=⌥ t=⌃ s=⇧ w=Super (no Mac, igual a ⌘)
    var mods = ""
    /// "mac", "linux" ou nil (todos): a grade mostra só as do computador conectado
    var os: String? = nil

    /// Linha do protocolo enviada ao computador.
    var command: String? {
        switch kind {
        case .key:
            guard let code = actionKeys.first(where: { $0.label == value })?.code else { return nil }
            return mods.isEmpty ? "k \(code)" : "k \(code) \(mods)"
        case .text: return value.isEmpty ? nil : "t " + value
        case .open: return value.isEmpty ? nil : "O " + value
        case .shell: return value.isEmpty ? nil : "r " + value
        }
    }

    /// Resumo curto mostrado no botão.
    var detail: String {
        switch kind {
        case .key:
            let sym = [("t", "⌃"), ("a", "⌥"), ("s", "⇧"), ("c", "⌘"), ("w", "❖")].filter { mods.contains($0.0) }.map(\.1).joined()
            return sym + (value.count == 1 ? value.uppercased() : value)
        case .text: return "texto"
        case .open: return value
        case .shell: return "comando"
        }
    }

    static func new() -> CustomAction { CustomAction(name: "", icon: "bolt.fill", color: actionColors[0], kind: .key, value: "a", mods: "c") }
}

/// Teclas do Mac oferecidas no editor (o host do Linux traduz os mesmos códigos).
let actionKeys: [(label: String, code: Int)] = {
    let special: [(String, Int)] = [
        ("espaço", 49), ("return", 36), ("tab", 48), ("esc", 53), ("⌫", 51), ("⌦", 117),
        ("←", 123), ("→", 124), ("↓", 125), ("↑", 126), ("home", 115), ("end", 119), ("pgup", 116), ("pgdn", 121),
        ("F1", 122), ("F2", 120), ("F3", 99), ("F4", 118), ("F5", 96), ("F6", 97),
        ("F7", 98), ("F8", 100), ("F9", 101), ("F10", 109), ("F11", 103), ("F12", 111),
    ]
    let chars = keycodes.filter { $0.key != " " }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    return chars + special
}()

let actionColors = [0x0a84ff, 0x30d158, 0xff9f0a, 0xff453a, 0xbf5af2, 0x64d2ff, 0xffd60a, 0x8e8e93]

private let actionIcons = [
    "bolt.fill", "command", "keyboard", "doc.on.doc", "doc.on.clipboard", "arrow.uturn.backward", "magnifyingglass",
    "camera.viewfinder", "lock.fill", "moon.fill", "sun.max.fill", "speaker.wave.2.fill", "music.note", "play.fill",
    "globe", "link", "envelope.fill", "message.fill", "terminal.fill", "chevron.left.forwardslash.chevron.right",
    "folder.fill", "trash.fill", "plus.square", "xmark.square", "rectangle.split.2x1", "macwindow", "power",
    "gearshape.fill", "star.fill", "heart.fill", "house.fill", "video.fill", "mic.fill", "paintbrush.fill", "text.cursor",
]

/// Ações salvas em UserDefaults (JSON).
final class ActionStore: ObservableObject {
    static let shared = ActionStore()
    private let key = "actions"

    @Published var items: [CustomAction] { didSet { save() } }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key), let list = try? JSONDecoder().decode([CustomAction].self, from: data) {
            items = list
        } else {
            items = [
                .init(name: "Copiar", icon: "doc.on.doc", color: 0x0a84ff, kind: .key, value: "c", mods: "c"),
                .init(name: "Colar", icon: "doc.on.clipboard", color: 0x0a84ff, kind: .key, value: "v", mods: "c"),
                .init(name: "Desfazer", icon: "arrow.uturn.backward", color: 0xff9f0a, kind: .key, value: "z", mods: "c"),
                .init(name: "Buscar", icon: "magnifyingglass", color: 0xbf5af2, kind: .key, value: "espaço", mods: "c"),
                .init(name: "Captura", icon: "camera.viewfinder", color: 0x30d158, kind: .key, value: "4", mods: "cs"),
                .init(name: "Nova aba", icon: "plus.square", color: 0x64d2ff, kind: .key, value: "t", mods: "c"),
                .init(name: "Fechar aba", icon: "xmark.square", color: 0xff453a, kind: .key, value: "w", mods: "c"),
            ]
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
    }

    func upsert(_ a: CustomAction) {
        if let i = items.firstIndex(where: { $0.id == a.id }) { items[i] = a } else { items.append(a) }
    }

    func remove(_ a: CustomAction) { items.removeAll { $0.id == a.id } }

    func move(_ a: CustomAction, by delta: Int) {
        guard let i = items.firstIndex(where: { $0.id == a.id }), items.indices.contains(i + delta) else { return }
        items.swapAt(i, i + delta)
    }
}

// MARK: - Grade

struct ActionsView: View {
    @ObservedObject private var store = ActionStore.shared
    @ObservedObject private var link = Link.shared
    @State private var editing: CustomAction?
    @State private var pressed: UUID?
    private let tap = UIImpactFeedbackGenerator(style: .rigid)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 12)], spacing: 12) {
                ForEach(store.items.filter { $0.os == nil || link.transport == .none || $0.os == GestureStore.currentOS }) { a in tile(a) }
                addTile
            }
            .padding(.horizontal, 20)
            .padding(.top, 54)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .opacity(link.transport == .none ? 0.5 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $editing) { a in ActionEditor(action: a, isNew: !store.items.contains { $0.id == a.id }) }
        .onAppear { link.send("C") }
        .onChange(of: link.transport) { _, t in if t != .none { link.send("C") } }
    }

    private func tile(_ a: CustomAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: a.icon).font(.system(size: 22, weight: .semibold))
            Spacer(minLength: 0)
            Text(a.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(a.detail).font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .background(Color(hex: UInt32(a.color)).opacity(0.85), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .scaleEffect(pressed == a.id ? 0.93 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: pressed)
        .contentShape(Rectangle())
        .onTapGesture { run(a) }
        .contextMenu {
            Button { editing = a } label: { Label("Editar", systemImage: "pencil") }
            Button { store.move(a, by: -1) } label: { Label("Mover para trás", systemImage: "arrow.left") }
            Button { store.move(a, by: 1) } label: { Label("Mover para frente", systemImage: "arrow.right") }
            Button(role: .destructive) { store.remove(a) } label: { Label("Excluir", systemImage: "trash") }
        }
    }

    private var addTile: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 24, weight: .medium))
            Text("Nova ação").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [5])))
        .contentShape(Rectangle())
        .onTapGesture { editing = .new() }
    }

    private func run(_ a: CustomAction) {
        guard let cmd = a.command else { editing = a; return }
        link.send(cmd)
        if Settings.shared.haptics { tap.impactOccurred(intensity: 0.8) }
        pressed = a.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { if pressed == a.id { pressed = nil } }
    }
}

// MARK: - Editor

private struct ActionEditor: View {
    @State var action: CustomAction
    let isNew: Bool
    @ObservedObject private var link = Link.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nome", text: $action.name)
                    Picker("Computador", selection: $action.os) {
                        Text("Todos").tag(String?.none)
                        Text("Só Mac").tag(String?.some("mac"))
                        Text("Só Linux").tag(String?.some("linux"))
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(actionColors, id: \.self) { c in
                                Circle().fill(Color(hex: UInt32(c))).frame(width: 28, height: 28)
                                    .overlay(Circle().stroke(.white, lineWidth: action.color == c ? 2.5 : 0).padding(-3))
                                    .onTapGesture { action.color = c }
                            }
                        }
                        .padding(.vertical, 6).padding(.horizontal, 4)
                    }
                    .scrollIndicators(.hidden)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 6)], spacing: 6) {
                        ForEach(actionIcons, id: \.self) { i in
                            Image(systemName: i).font(.system(size: 17))
                                .frame(width: 40, height: 36)
                                .background(action.icon == i ? Color(hex: UInt32(action.color)) : Color(.tertiarySystemFill),
                                            in: RoundedRectangle(cornerRadius: 8))
                                .onTapGesture { action.icon = i }
                        }
                    }
                    .padding(.vertical, 4)
                }

                ActionFields(action: $action)

                if !isNew {
                    Section { Button("Excluir ação", role: .destructive) { ActionStore.shared.remove(action); dismiss() } }
                }
            }
            .navigationTitle(isNew ? "Nova ação" : "Editar ação")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") { ActionStore.shared.upsert(action); dismiss() }.bold()
                        .disabled(action.name.trimmingCharacters(in: .whitespaces).isEmpty || action.command == nil)
                }
            }
        }
        .onAppear { link.send("C") }
    }
}

/// Tipo e conteúdo de uma ação — usado no editor de ações e no de gestos.
struct ActionFields: View {
    @Binding var action: CustomAction
    @ObservedObject private var link = Link.shared

    var body: some View {
        Group {
                Section("Tipo") {
                    Picker("Tipo", selection: $action.kind) {
                        ForEach(CustomAction.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                switch action.kind {
                case .key: keySection
                case .text:
                    Section {
                        TextEditor(text: $action.value).frame(minHeight: 90)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: { Text("Texto") } footer: { Text("Digitado no computador onde o cursor estiver. Quebras de linha viram return.") }
                case .open:
                    Section {
                        TextField("https://… ou nome do app", text: $action.value)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    } header: { Text("Abrir") } footer: {
                        Text("Um link (https://, spotify:, mailto:…) ou o nome de um app, como Safari ou Spotify. No Linux, use o nome do app como aparece no menu.")
                    }
                case .shell: shellSection
                }

                Section {
                    Button("Testar no computador") { if let c = action.command { link.send(c) } }
                        .disabled(action.command == nil || link.transport == .none)
                }
        }
        .onChange(of: action.kind) { _, k in
            action.value = k == .key ? "a" : ""
            action.mods = k == .key ? "c" : ""
        }
        .onAppear { link.send("C") }
    }

    private var keySection: some View {
        Section {
            HStack(spacing: 8) {
                ForEach([("⌘", Character("c")), ("⌥", "a"), ("⌃", "t"), ("⇧", "s"), ("❖", "w")], id: \.1) { sym, m in
                    let on = action.mods.contains(m)
                    Text(sym).font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(on ? Color.accentColor : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(on ? .white : .primary)
                        .onTapGesture {
                            if on { action.mods.removeAll { $0 == m } } else { action.mods.append(m) }
                        }
                }
            }
            Picker("Tecla", selection: $action.value) {
                ForEach(actionKeys, id: \.label) { k in Text(k.label.count == 1 ? k.label.uppercased() : k.label).tag(k.label) }
            }
            LabeledContent("Atalho", value: action.detail)
        } header: { Text("Atalho") } footer: {
            Text("❖ é a tecla Super/Windows no Linux (no Mac, igual a ⌘). No Linux, ⌘ vira Ctrl por padrão (TRACEPAD_CMD=super no host para virar Super).")
        }
    }

    private var shellSection: some View {
        Section {
            if link.commands.isEmpty {
                Text(link.transport == .none ? "Conecte ao computador para ver os comandos." : "Nenhum comando definido no computador.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Comando", selection: $action.value) {
                    Text("Escolha…").tag("")
                    ForEach(link.commands, id: \.self) { Text($0).tag($0) }
                    if !action.value.isEmpty, !link.commands.contains(action.value) { Text("\(action.value) (não encontrado)").tag(action.value) }
                }
            }
        } header: { Text("Comando") } footer: {
            Text("Os comandos ficam no computador, em ~/.tracepad-actions, um por linha: Nome = comando. O iPhone só chama pelo nome. No Mac: menu do TracePad › Editar ações de shell.")
        }
    }
}

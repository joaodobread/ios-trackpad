// Ações customizadas: comandos de shell definidos em ~/.tracepad-actions (o iPhone só chama pelo nome)
// e abrir URL/app. Atalhos e textos usam os comandos "k" e "t" de sempre.

import AppKit

enum Actions {
    static let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tracepad-actions")

    static let sample = """
    # Ações do TracePad — uma por linha: Nome = comando
    # Aparecem no iPhone em Ajustes › Modo › Ações › + › Comando. O comando roda no seu shell (com o PATH de login).
    #
    # Bloquear tela = pmset displaysleepnow
    # Spotify = open -a Spotify
    # Modo escuro = osascript -e 'tell app "System Events" to tell appearance preferences to set dark mode to not dark mode'
    #
    # Gestos padrão (quando o gesto está em "Padrão" no iPhone): @nome = atalho ou comando
    # nomes: mission, expose, desktop, space-left, space-right, lookup, zoom-in, zoom-out
    # @mission = ctrl+up
    # @desktop = open -a Finder

    """

    /// Cria o arquivo de exemplo na primeira vez.
    static func ensureFile() {
        if !FileManager.default.fileExists(atPath: file.path) { try? sample.write(to: file, atomically: true, encoding: .utf8) }
    }

    /// Lê o arquivo a cada pedido: editar não exige reiniciar o app.
    static func commands() -> [(name: String, command: String)] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.hasPrefix("#"), let eq = l.firstIndex(of: "=") else { return nil }
            let name = clean(l[..<eq].trimmingCharacters(in: .whitespaces))
            let cmd = l[l.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return name.isEmpty || cmd.isEmpty ? nil : (name, cmd)
        }
    }

    /// "C nome\tnome…" (linhas "@gesto" são redefinições de gestos, não aparecem)
    static func list() -> String { "C " + commands().map(\.name).filter { !$0.hasPrefix("@") }.joined(separator: "\t") }

    static func run(_ name: String) {
        guard !name.hasPrefix("@"), let cmd = commands().first(where: { $0.name == name })?.command else { return print("✗ ação desconhecida: \(name)") }
        shell(cmd, label: name)
    }

    private static func shell(_ cmd: String, label name: String) {
        print("▶ \(name)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-lc", cmd]
        p.terminationHandler = { if $0.terminationStatus != 0 { print("✗ \(name): saiu com \($0.terminationStatus)") } }
        do { try p.run() } catch { print("✗ \(name): \(error.localizedDescription)") }
    }

    /// URL (qualquer esquema) ou nome de app ("Safari", "Visual Studio Code").
    static func open(_ target: String) {
        let t = target.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        if t.contains("://") || t.hasPrefix("mailto:"), let url = URL(string: t) {
            NSWorkspace.shared.open(url)
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = t.hasPrefix("/") || t.hasPrefix("~") ? [(t as NSString).expandingTildeInPath] : ["-a", t]
        try? p.run()
    }

    // MARK: gestos padrão ("g nome")

    private static let gestureKeys: [String: (CGKeyCode, Substring)] = [
        "mission": (126, "t"), "expose": (125, "t"), "space-right": (124, "t"), "space-left": (123, "t"),
        "desktop": (103, ""), "lookup": (2, "tc"), "zoom-in": (24, "c"), "zoom-out": (27, "c"),
    ]

    static func gesture(_ name: String) {
        if let spec = commands().first(where: { $0.name == "@" + name })?.command {
            if let (code, mods) = combo(spec) { input.key(code, mods: mods) } else { shell(spec, label: "@" + name) }
        } else if let (code, mods) = gestureKeys[name] {
            input.key(code, mods: mods)
        }
    }

    private static let keyNames: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "equal": 24, "=": 24, "9": 25, "7": 26, "minus": 27,
        "-": 27, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "enter": 36, "return": 36, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46, "tab": 48, "space": 49, "backspace": 51, "esc": 53, "escape": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "home": 115, "pageup": 116, "pgup": 116, "delete": 117, "del": 117, "end": 119, "pagedown": 121, "pgdn": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    /// "ctrl+alt+left" → tecla e modificadores; nil se algum pedaço não for tecla (aí é comando de shell).
    private static func combo(_ spec: String) -> (CGKeyCode, Substring)? {
        let parts = spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 1, let key = keyNames[parts.last!] else { return nil }
        var mods = ""
        for p in parts.dropLast() {
            switch p {
            case "ctrl", "control": mods += "t"
            case "alt", "opt", "option": mods += "a"
            case "shift": mods += "s"
            case "cmd", "command", "super", "meta", "win": mods += "c"
            default: return nil
            }
        }
        return (key, Substring(mods))
    }

    static func edit() {
        ensureFile()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", file.path]
        try? p.run()
    }
}

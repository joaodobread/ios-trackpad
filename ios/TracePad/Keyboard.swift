// Teclado: um UIView que recebe o teclado do iOS (UIKeyInput) e repassa ao Mac,
// com barra de teclas extras (esc, tab, setas, ⌘⌥⌃⇧ fixos).

import UIKit
import SwiftUI

private let keycodes: [String: Int] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
    "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
    "n": 45, "m": 46, ".": 47, " ": 49, "`": 50,
]

final class KeyInputView: UIView, UIKeyInput {
    var onDismiss: () -> Void = {}
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var inlinePredictionType: UITextInlinePredictionType = .no

    private let tick = UIImpactFeedbackGenerator(style: .light)
    private var modButtons = [Character: UIButton]()

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true } // garante que o ⌫ sempre dispara

    func insertText(_ text: String) {
        if text == "\n" { return sendKey(36) }
        if !Mods.active.isEmpty, text.count == 1, let code = keycodes[text.lowercased()] {
            return sendKey(code, extra: text != text.lowercased() ? "s" : "")
        }
        Link.shared.send("t " + text)
    }

    func deleteBackward() { sendKey(51) }

    override func resignFirstResponder() -> Bool {
        let r = super.resignFirstResponder()
        if r { onDismiss() }
        return r
    }

    override var inputAccessoryView: UIView? { bar }

    private lazy var bar: UIView = {
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 50), inputViewStyle: .keyboard)
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        let stack = UIStackView()
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        bar.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 38),
        ])

        func button(_ title: String, _ action: @escaping () -> Void) -> UIButton {
            var cfg = UIButton.Configuration.gray()
            cfg.title = title
            cfg.cornerStyle = .medium
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
            let b = UIButton(configuration: cfg, primaryAction: UIAction { [weak self] _ in
                action()
                if Settings.shared.haptics { self?.tick.impactOccurred(intensity: 0.6) }
            })
            b.tintColor = .white
            stack.addArrangedSubview(b)
            return b
        }

        _ = button("⌄") { [weak self] in _ = self?.resignFirstResponder() }
        for (t, k) in [("esc", 53), ("tab", 48)] { _ = button(t) { sendKey(k) } }
        for (t, m) in [("⌘", Character("c")), ("⌥", "a"), ("⌃", "t"), ("⇧", "s")] {
            modButtons[m] = button(t) { if Mods.active.contains(m) { Mods.active.remove(m) } else { Mods.active.insert(m) } }
        }
        for (t, k) in [("←", 123), ("↓", 125), ("↑", 126), ("→", 124), ("⌦", 117), ("home", 115), ("end", 119), ("pgup", 116), ("pgdn", 121)] {
            _ = button(t) { sendKey(k) }
        }
        Mods.onChange = { [weak self] in
            for (m, b) in self?.modButtons ?? [:] {
                b.configuration?.baseBackgroundColor = Mods.active.contains(m) ? .systemBlue : nil
            }
        }
        return bar
    }()
}

struct KeyboardHost: UIViewRepresentable {
    @Binding var active: Bool

    func makeUIView(context: Context) -> KeyInputView {
        let v = KeyInputView()
        let binding = $active
        v.onDismiss = { DispatchQueue.main.async { binding.wrappedValue = false } }
        return v
    }

    func updateUIView(_ v: KeyInputView, context: Context) {
        if active, !v.isFirstResponder { v.becomeFirstResponder() }
        // Fechar fora do ciclo de atualização do SwiftUI (igual ao botão ⌄ da barra).
        // Fechar aqui dentro deixava o layout preso no tamanho com teclado no aparelho.
        if !active, v.isFirstResponder { DispatchQueue.main.async { _ = v.resignFirstResponder() } }
    }
}

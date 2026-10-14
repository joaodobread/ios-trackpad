import Foundation
import Combine

/// Ajustes persistidos em UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var speed: Double { didSet { d.set(speed, forKey: "speed") } }
    @Published var accel: Double { didSet { d.set(accel, forKey: "accel") } }
    @Published var scroll: Double { didSet { d.set(scroll, forKey: "scroll") } }
    @Published var natural: Bool { didSet { d.set(natural, forKey: "natural") } }
    @Published var momentum: Bool { didSet { d.set(momentum, forKey: "momentum") } }
    @Published var haptics: Bool { didSet { d.set(haptics, forKey: "haptics") } }
    @Published var threeFingerDrag: Bool { didSet { d.set(threeFingerDrag, forKey: "threeFingerDrag") } }
    /// id de uma skin pronta, "url" (customURL) ou "photo" (arquivo salvo localmente)
    @Published var skin: String { didSet { d.set(skin, forKey: "skin") } }
    @Published var customURL: String { didSet { d.set(customURL, forKey: "customURL") } }
    @Published var dim: Double { didSet { d.set(dim, forKey: "dim") } }
    /// "trackpad", "monitor" ou "apps"
    @Published var mode: String { didSet { d.set(mode, forKey: "mode") } }
    /// muda quando a foto da skin é trocada, para recarregar a mídia
    @Published var skinVersion = 0
    /// resultado do último carregamento de mídia (mostrado nos Ajustes)
    @Published var skinStatus = ""

    static let photoURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("skin")

    private init() {
        d.register(defaults: [
            "speed": 1.8, "accel": 0.9, "scroll": 1.2, "natural": true, "momentum": true, "haptics": true,
            "threeFingerDrag": false, "skin": "grafite", "customURL": "", "dim": 0.0, "mode": "trackpad",
        ])
        speed = d.double(forKey: "speed")
        accel = d.double(forKey: "accel")
        scroll = d.double(forKey: "scroll")
        natural = d.bool(forKey: "natural")
        momentum = d.bool(forKey: "momentum")
        haptics = d.bool(forKey: "haptics")
        threeFingerDrag = d.bool(forKey: "threeFingerDrag")
        skin = d.string(forKey: "skin") ?? "grafite"
        customURL = d.string(forKey: "customURL") ?? ""
        dim = d.double(forKey: "dim")
        mode = d.string(forKey: "mode") ?? "trackpad"
    }

    func savePhoto(_ data: Data) throws {
        try FileManager.default.createDirectory(at: Settings.photoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: Settings.photoURL, options: .atomic)
        skin = "photo"
        skinVersion += 1
    }
}

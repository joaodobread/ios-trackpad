import SwiftUI

@main
struct TracePadApp: App {
    @Environment(\.scenePhase) private var phase

    init() { Link.shared.start() }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onChange(of: phase) { _, p in
                    guard p == .active else { return }
                    Link.shared.resume()
                    UIApplication.shared.isIdleTimerDisabled = true // tela não apaga enquanto usa
                }
        }
    }
}

struct ContentView: View {
    @ObservedObject private var s = Settings.shared
    @ObservedObject private var link = Link.shared
    @State private var keyboard = false
    @State private var settings = false
    @State private var hint = true
    @State private var drawer = false

    private var lightSkin: Bool { presets.first { $0.id == s.skin }?.light ?? false }

    var body: some View {
        ZStack {
            SkinView(id: s.skin, customURL: s.customURL, version: s.skinVersion)
                .ignoresSafeArea()
            Color.black.opacity(s.dim).ignoresSafeArea()

            if hint {
                VStack(spacing: 4) {
                    Text("**1 dedo** mover · toque = clique · toque + arrastar = arrastar")
                    Text("**2 dedos** rolar · toque = clique direito · pinça = zoom")
                    Text("**3 dedos** ↑ Mission Control · ↓ Exposé · ←→ mesas · toque = consultar")
                    Text("**4 dedos** ↓ mostrar mesa")
                    Text("☀︎ no topo: brilho, volume e mídia").padding(.top, 6)
                }
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(lightSkin ? Color.black.opacity(0.45) : Color.white.opacity(0.4))
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            Trackpad { withAnimation(.easeOut(duration: 0.4)) { hint = false } }
                .ignoresSafeArea()

            KeyboardHost(active: $keyboard).frame(width: 0, height: 0)

            VStack {
                HStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(link.transport == .none ? Color.red : .green).frame(width: 8, height: 8)
                        Text(link.transport.rawValue).font(.caption)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    toolButton("sun.max") { drawer.toggle() }
                    toolButton(keyboard ? "keyboard.chevron.compact.down" : "keyboard") { keyboard.toggle() }
                    toolButton("slider.horizontal.3") { settings = true }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                Spacer()
            }

            ControlDrawer(open: $drawer)
        }
        // o teclado passa por cima; nada é redimensionado (antes o fundo encolhia e não voltava)
        .ignoresSafeArea(.keyboard)
        .background(Color.black)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $settings) { SettingsView() }
        #if DEBUG
        .task {
            // teste automatizado do teclado no simulador: TP_KBTEST=1
            guard ProcessInfo.processInfo.environment["TP_KBTEST"] != nil else { return }
            try? await Task.sleep(for: .seconds(1.5)); keyboard = true
            try? await Task.sleep(for: .seconds(2.5)); keyboard = false
        }
        #endif
    }

    private func toolButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 38, height: 32)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .foregroundStyle(.white)
    }
}

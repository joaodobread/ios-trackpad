import SwiftUI
import PhotosUI

struct SettingsView: View {
    @ObservedObject var s = Settings.shared
    @ObservedObject var link = Link.shared
    @Environment(\.dismiss) private var dismiss
    @State private var url = Settings.shared.customURL
    @State private var photo: PhotosPickerItem?
    @State private var message = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Conexão") {
                    LabeledContent("Status", value: link.transport.rawValue)
                    if link.bluetoothOff { Text("Bluetooth desligado ou sem permissão.").foregroundStyle(.orange) }
                    Text("USB: conecte o cabo com o TracePad aberto no Mac. Bluetooth: conecta sozinho quando os dois estão abertos (na primeira vez o iPhone e o Mac pedem para parear).")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Controle") {
                    slider("Velocidade", $s.speed, 0.4...5)
                    slider("Aceleração", $s.accel, 0...2)
                    slider("Rolagem", $s.scroll, 0.3...4)
                    Toggle("Rolagem natural", isOn: $s.natural)
                    Toggle("Inércia na rolagem", isOn: $s.momentum)
                    Toggle("Vibração", isOn: $s.haptics)
                    Picker("3 dedos", selection: $s.threeFingerDrag) {
                        Text("Gestos").tag(false)
                        Text("Arrastar").tag(true)
                    }
                }

                Section("Aparência do trackpad") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                        ForEach(presets) { p in
                            tile(selected: s.skin == p.id, label: p.name, light: p.light) { SkinView(id: p.id) }
                                .onTapGesture { s.skin = p.id; message = "" }
                        }
                        PhotosPicker(selection: $photo, matching: .images) {
                            tile(selected: s.skin == "photo" || s.skin == "url", label: "Minha", light: false) {
                                if s.skin == "photo" || s.skin == "url" {
                                    SkinView(id: s.skin, customURL: s.customURL, version: s.skinVersion)
                                } else {
                                    Image(systemName: "photo.on.rectangle").font(.title2).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(.tertiarySystemFill))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)

                    HStack {
                        TextField("URL de GIF, imagem ou vídeo", text: $url)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit(applyURL)
                        Button("Usar", action: applyURL).buttonStyle(.borderedProminent)
                    }
                    if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    if !s.skinStatus.isEmpty, s.skin == "url" || s.skin == "photo" {
                        Text(s.skinStatus).font(.footnote).foregroundStyle(s.skinStatus.hasPrefix("✓") ? Color.green : Color.orange)
                    }
                    slider("Escurecer", $s.dim, 0...0.8, percent: true)
                }
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Pronto") { dismiss() }.bold() }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                // Data preserva o GIF animado (UIImage perderia os quadros)
                if let data = try? await item.loadTransferable(type: Data.self) {
                    try? s.savePhoto(data)
                    message = "Usando imagem da galeria."
                } else {
                    message = "Não consegui carregar essa imagem."
                }
                photo = nil
            }
        }
    }

    private func applyURL() {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[TracePad skin] aplicar URL: \(u)")
        guard u.lowercased().hasPrefix("http") else { message = "Cole o link direto do arquivo (http…)."; return }
        s.skinStatus = ""
        s.customURL = u
        s.skin = "url"
        message = "Aplicado. Use o link direto do arquivo (.gif, .png, .mp4…)."
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, percent: Bool = false) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(percent ? "\(Int(value.wrappedValue * 100))%" : String(format: "%.1f", value.wrappedValue))
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
        }
    }

    private func tile<C: View>(selected: Bool, label: String, light: Bool, @ViewBuilder content: () -> C) -> some View {
        content()
            .frame(height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottomLeading) {
                Text(label).font(.caption2.bold()).foregroundStyle(light ? .black.opacity(0.8) : .white).padding(6)
            }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Rectangle())
    }
}

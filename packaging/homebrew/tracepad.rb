cask "tracepad" do
  version "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/joaodobread/ios-trackpad/releases/download/v#{version}/TracePad-mac.zip"
  name "TracePad"
  desc "Usa o iPhone como trackpad (app de barra de menus)"
  homepage "https://github.com/joaodobread/ios-trackpad"

  depends_on macos: :sonoma

  app "TracePad.app"

  # O app é assinado ad-hoc (sem notarização): tira a quarentena para o Gatekeeper deixar abrir
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/TracePad.app"]
  end

  uninstall quit: "com.joaodobread.iostrackpad.mac"

  zap trash: [
    "~/.tracepad-actions",
    "~/.tracepad-pin",
  ]
end

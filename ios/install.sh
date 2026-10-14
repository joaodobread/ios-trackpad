#!/bin/sh
# Compila, assina e instala o TracePad no iPhone conectado (cabo ou mesma rede, desbloqueado).
# Configuração em ios/local.env (fora do git) ou variáveis de ambiente:
#   TEAM=<id>        time de assinatura. Sem conta paga: adicione sua Apple ID grátis no Xcode
#                    (Ajustes › Contas) e use o ID do "Personal Team" — o app expira em 7 dias,
#                    é só rodar este script de novo.
#   BUNDLE_ID=<id>   opcional; padrão com.joaodobread.iostrackpad; troque se sua conta não puder registrar esse ID
set -e
cd "$(dirname "$0")"
[ -f local.env ] && . ./local.env
[ -z "$TEAM" ] && { echo "Defina TEAM (ex.: echo 'TEAM=ABCDE12345' > ios/local.env). Veja o ID em Xcode › Ajustes › Contas."; exit 1; }
BUNDLE_ID="${BUNDLE_ID:-com.joaodobread.iostrackpad}"
DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/available \(paired\)/ && !/simulated/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1)
[ -z "$DEVICE" ] && { echo "Nenhum iPhone pareado e disponível. Conecte o cabo e desbloqueie."; exit 1; }
xcodebuild -project TracePad.xcodeproj -scheme TracePad -configuration Release \
  -destination "id=$DEVICE" -derivedDataPath ../build/ios-dd \
  DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" -allowProvisioningUpdates build -quiet
xcrun devicectl device install app --device "$DEVICE" ../build/ios-dd/Build/Products/Release-iphoneos/TracePad.app
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
echo "TracePad instalado no iPhone."

#!/bin/sh
# Compila o app de barra de menus do Mac (build/TracePad.app) e abre.
# Assina com o primeiro certificado "Apple Development" válido para a permissão de
# Acessibilidade sobreviver a recompilações (assinatura ad-hoc muda a cada build).
set -e
cd "$(dirname "$0")"
APP=build/TracePad.app
if [ ! -x "$APP/Contents/MacOS/TracePad" ] || [ -n "$(find mac web -newer "$APP/Contents/MacOS/TracePad" -type f)" ]; then
  echo "Compilando…"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  swiftc -O -swift-version 5 mac/*.swift -o "$APP/Contents/MacOS/TracePad"
  cp mac/Info.plist "$APP/Contents/Info.plist"
  cp -R web "$APP/Contents/Resources/web"
  ID=$(security find-identity -v -p codesigning | grep "Apple Development" | grep -v REVOKED | head -1 | awk '{print $2}')
  codesign --force --sign "${ID:--}" "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"
fi
pkill -x TracePad 2>/dev/null || true
open "$APP"
echo "TracePad aberto na barra de menus."

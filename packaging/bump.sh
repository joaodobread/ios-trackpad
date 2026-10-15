#!/bin/sh
# Atualiza o PKGBUILD/.SRCINFO (AUR) e o cask do Homebrew para uma versão já publicada.
# Uso: packaging/bump.sh 1.2.0   (a tag v1.2.0 e o release com TracePad-mac.zip precisam existir)
# No CI, MAC_ZIP=caminho/TracePad-mac.zip usa o zip local (o release ainda não foi publicado).
# Depois: copie packaging/arch/* para o repo do AUR e packaging/homebrew/tracepad.rb para o tap.
set -e
V=${1#v}
[ -n "$V" ] || { echo "uso: $0 VERSÃO (ex.: 1.2.0)"; exit 1; }
cd "$(dirname "$0")"
REPO=https://github.com/joaodobread/ios-trackpad

sha() {
  curl -fsSL "$1" | shasum -a 256 | cut -d' ' -f1
}

echo "Baixando o tarball da tag v${V}…"
SRC=$(sha "$REPO/archive/refs/tags/v$V.tar.gz")
echo "  sha256 $SRC"
if [ -n "$MAC_ZIP" ]; then
  MAC=$(shasum -a 256 "$MAC_ZIP" | cut -d' ' -f1)
else
  echo "Baixando TracePad-mac.zip do release v${V}…"
  MAC=$(sha "$REPO/releases/download/v$V/TracePad-mac.zip")
fi
echo "  sha256 $MAC"

export V SRC MAC REPO

# PKGBUILD: versão, pkgrel=1 e o 1º sha256sums (o do tarball; os outros são dos arquivos locais)
perl -0pi -e 's/^pkgver=.*/pkgver=$ENV{V}/m; s/^pkgrel=.*/pkgrel=1/m;
  s/^sha256sums=\(\x27[^\x27]*\x27/sha256sums=(\x27$ENV{SRC}\x27/m' arch/PKGBUILD

# .SRCINFO: regenera com makepkg se houver; senão edita no lugar
if command -v makepkg >/dev/null; then
  (cd arch && makepkg --printsrcinfo > .SRCINFO)
else
  perl -0pi -e 's/^\tpkgver = .*/\tpkgver = $ENV{V}/m; s/^\tpkgrel = .*/\tpkgrel = 1/m;
    s{^\tsource = tracepad-.*}{\tsource = tracepad-$ENV{V}.tar.gz::$ENV{REPO}/archive/refs/tags/v$ENV{V}.tar.gz}m;
    s/^\tsha256sums = .*/\tsha256sums = $ENV{SRC}/m' arch/.SRCINFO
fi

# Cask: versão e sha256
perl -pi -e 's/^  version ".*"/  version "$ENV{V}"/; s/^  sha256 ".*"/  sha256 "$ENV{MAC}"/' homebrew/tracepad.rb

echo "Pronto: arch/PKGBUILD, arch/.SRCINFO e homebrew/tracepad.rb em v${V}."

#!/bin/sh
# Instala o TracePad no Linux: dependências, acesso ao /dev/uinput e serviço de usuário (sobe com a sessão gráfica).
# Rode da pasta do projeto: ./linux/install.sh   (pede sudo para pacotes e a regra do udev)
set -e
cd "$(dirname "$0")/.."
DIR=$(pwd)

echo "Instalando dependências…"
# X11 usa wmctrl/xdotool; Wayland usa wtype/wl-clipboard (no Hyprland/Omarchy o modo Apps vai pelo hyprctl)
if command -v apt-get >/dev/null; then
  sudo apt-get install -y python3-evdev python3-psutil usbmuxd libimobiledevice-utils pulseaudio-utils brightnessctl \
    wmctrl xdotool xclip wtype wl-clipboard playerctl python3-venv || true
  sudo apt-get install -y python3-bleak 2>/dev/null || true
elif command -v dnf >/dev/null; then
  sudo dnf install -y python3-evdev python3-psutil usbmuxd libimobiledevice-utils pulseaudio-utils brightnessctl \
    wmctrl xdotool xclip wtype wl-clipboard playerctl python3-bleak || true
elif command -v pacman >/dev/null; then
  # Arch e Omarchy (que já traz wtype, wl-clipboard, libpulse, brightnessctl e o agente de pareamento bt-agent)
  sudo pacman -S --needed --noconfirm python-evdev python-psutil usbmuxd libimobiledevice libpulse brightnessctl wtype wl-clipboard playerctl || true
  [ -z "$WAYLAND_DISPLAY" ] && sudo pacman -S --needed --noconfirm wmctrl xdotool xclip || true
  python3 -c "import bleak" 2>/dev/null || sudo pacman -S --needed --noconfirm python-bleak || true
else
  echo "Gerenciador de pacotes não reconhecido: instale usbmuxd (e, se quiser, pactl, brightnessctl, playerctl) manualmente."
fi

# O que a distro não tem (ou o pip não deixa instalar no Python do sistema — PEP 668) vai para um venv
# que enxerga os pacotes do sistema; o serviço passa a rodar com o Python dele.
PY=python3
MISSING=""
for m in evdev psutil bleak; do python3 -c "import $m" 2>/dev/null || MISSING="$MISSING $m"; done
if [ -n "$MISSING" ]; then
  VENV="$HOME/.local/share/tracepad/venv"
  echo "Instalando num venv ($VENV):$MISSING"
  # evdev compila uma extensão em C: precisa de gcc e dos headers do kernel/Python
  python3 -m venv --system-site-packages "$VENV" && "$VENV/bin/pip" install -q $MISSING && PY="$VENV/bin/python" \
    || echo "⚠️  Não deu para instalar:$MISSING (sem evdev não há mouse/teclado; sem bleak, só USB e Wi-Fi)"
fi

echo "Liberando /dev/uinput para o usuário logado…"
sudo mkdir -p /etc/modules-load.d /etc/udev/rules.d
echo 'KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"' | sudo tee /etc/udev/rules.d/60-tracepad-uinput.rules >/dev/null
echo uinput | sudo tee /etc/modules-load.d/tracepad-uinput.conf >/dev/null
sudo modprobe uinput
sudo udevadm control --reload-rules && sudo udevadm trigger --name-match=uinput || true

echo "Criando o serviço de usuário…"
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/tracepad.service <<EOF
[Unit]
Description=TracePad (iPhone como trackpad)
PartOf=graphical-session.target
After=graphical-session.target

[Service]
ExecStart=$( [ "$PY" = python3 ] && echo "/usr/bin/env python3" || echo "$PY" ) $DIR/linux/tracepad.py $DIR/web
Restart=on-failure

[Install]
WantedBy=graphical-session.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now tracepad.service

echo
echo "Pronto. Logs e PIN do PWA: journalctl --user -u tracepad -f"
echo "USB: com o iPhone plugado e desbloqueado, rode uma vez 'idevicepair pair' e toque em Confiar."
echo "Se o mouse não mexer, saia e entre de novo na sessão (para o acesso ao /dev/uinput valer)."

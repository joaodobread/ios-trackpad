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
    wmctrl xdotool wtype wl-clipboard python3-pip || true
  sudo apt-get install -y python3-bleak 2>/dev/null || pip3 install --user bleak 2>/dev/null || pip3 install --user --break-system-packages bleak || true
elif command -v dnf >/dev/null; then
  sudo dnf install -y python3-evdev python3-psutil usbmuxd libimobiledevice-utils pulseaudio-utils brightnessctl \
    wmctrl xdotool wtype wl-clipboard python3-bleak || true
elif command -v pacman >/dev/null; then
  # Arch e Omarchy (que já traz wtype, wl-clipboard, libpulse, brightnessctl e o agente de pareamento bt-agent)
  sudo pacman -S --needed --noconfirm python-evdev python-psutil usbmuxd libimobiledevice libpulse brightnessctl wtype wl-clipboard || true
  [ -z "$WAYLAND_DISPLAY" ] && sudo pacman -S --needed --noconfirm wmctrl xdotool || true
  if ! python3 -c "import bleak" 2>/dev/null; then
    sudo pacman -S --needed --noconfirm python-bleak 2>/dev/null \
      || { command -v yay >/dev/null && yay -S --needed --noconfirm python-bleak; } \
      || pip install --user --break-system-packages bleak || true
  fi
else
  echo "Gerenciador de pacotes não reconhecido: instale python3-evdev, psutil, bleak e usbmuxd manualmente."
fi

echo "Liberando /dev/uinput para o usuário logado…"
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
ExecStart=/usr/bin/env python3 $DIR/linux/tracepad.py $DIR/web
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

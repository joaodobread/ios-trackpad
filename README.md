# TracePad

[![build](../../actions/workflows/build.yml/badge.svg)](../../actions/workflows/build.yml)
[![licença: MIT](https://img.shields.io/badge/licen%C3%A7a-MIT-blue.svg)](LICENSE)

Use o iPhone como trackpad do Mac, do Linux ou do Windows — com gestos de verdade, vibração, teclado, ações customizadas, mídia, apresentação, área de transferência, envio de arquivos, brilho/volume e skins.

- **App nativo do iPhone** (`ios/`): paisagem e tela cheia de verdade, Taptic Engine, skins. Conecta por **USB** (~1 ms, via usbmuxd) ou **Bluetooth LE** (~15 ms, sem Wi-Fi). USB tem prioridade.
- **App de barra de menus do Mac** (`mac/`): recebe os gestos e injeta no sistema. Também serve o **PWA** (`web/`) por Wi-Fi para quem não quer instalar nada no celular.
- **Host do Linux** (`linux/`): o mesmo, em Python — USB, Bluetooth e PWA; X11 e Wayland.
- **Host do Windows** (`windows/`): idem, em Python — USB (Apple Mobile Device Service), Bluetooth e PWA.

Builds prontos de cada commit ficam nos artefatos do [GitHub Actions](../../actions/workflows/build.yml) (app do Mac, `.ipa` sem assinatura para Sideloadly/AltStore e pacotes do Linux e do Windows); tags `v*` viram release.

## Requisitos

- macOS 14+ com Xcode 16+ (ou só as Command Line Tools, para o app do Mac)
- iPhone com iOS 17+ (o PWA funciona em qualquer celular com navegador)

## Mac

```sh
./run.sh
```

Na primeira vez, permita o **TracePad** em Ajustes do Sistema › Privacidade e Segurança › **Acessibilidade** (e Bluetooth quando pedir).

## Linux

```sh
./linux/install.sh   # dependências, acesso ao /dev/uinput e serviço de usuário
journalctl --user -u tracepad -f   # logs e PIN do PWA
```

Ou rode direto: `python3 linux/tracepad.py`. Só `python3-evdev` é obrigatório; o resto liga recursos:

| Recurso | Precisa de |
|---|---|
| Mouse, teclado, rolagem | `python3-evdev` + acesso ao `/dev/uinput` (o `install.sh` cuida) |
| USB | `usbmuxd` e, uma vez, `idevicepair pair` com o iPhone desbloqueado |
| Bluetooth | `bleak` (BlueZ); na primeira conexão os dois pedem para parear |
| Monitor | `psutil` (GPU: AMD/Intel via sysfs ou `nvidia-smi`) |
| Volume / brilho | `pactl` / `brightnessctl` |
| Apps (janelas) | `wmctrl` + `xdotool`, só em X11; abrir apps instalados funciona em qualquer sessão |
| Texto com acentos | `xdotool` (X11), `wtype` (Sway/Hyprland) ou `wl-copy` (GNOME/KDE Wayland, cola) |
| Tocando agora | `playerctl` (qualquer player MPRIS); capa reduzida se tiver ImageMagick |
| Área de transferência | `wl-clipboard` (Wayland) ou `xclip` (X11) |

### Omarchy / Hyprland

Suportado: o `install.sh` usa o pacman (tudo nos repositórios oficiais) e o serviço sobe com a sessão do uwsm. O Omarchy já traz `wtype`, `wl-clipboard`, `libpulse`, `brightnessctl` e o agente de pareamento Bluetooth. No Hyprland:

- **Apps**: janelas pelo `hyprctl` (configuração em Lua do Omarchy ou a clássica). Ocultar manda para `special:minimized`, como o Super+M do Omarchy, e abrir de novo traz de volta para a mesa de origem.
- **Gestos padrão**: ←/→ trocam de mesa (`e±1`), ↑ abre o scratchpad (Super+S), ↓ com 3 dedos alterna janelas e ↓ com 4 dedos vai para uma mesa vazia. Redefina com `@gesto` (ex.: `@mission = hyprctl dispatch 'hl.dsp.workspace.toggle_special("scratchpad")'`) ou por sistema em Ajustes › Gestos.
- **Texto** por `wtype` (acentos inclusos); **volume** por `pactl` ou `wpctl`.
- Rodando como serviço, o host acha sozinho a instância do Hyprland e o socket do Wayland.

As teclas chegam com códigos do Mac e viram as mesmas teclas físicas: ⌘ vira Ctrl (ou Super com `TRACEPAD_CMD=super`) e ❖ é Super. Os gestos padrão viram a visão geral (Super), Ctrl+Alt+←/→ para trocar de mesa e Super+D para mostrar a mesa — e dá para mudar (veja [Gestos configuráveis](#gestos-configuráveis)).

## Windows

```powershell
powershell -ExecutionPolicy Bypass -File windows\install.ps1   # dependências (pip), atalho na Inicialização e firewall
```

Ou rode direto: `python windows\tracepad.py` (ou `pythonw`, sem janela; o log vai para `~\.tracepad.log`). Mouse, teclado, Apps e área de transferência vão por ctypes; `windows\requirements.txt` liga o resto: `psutil` (Monitor, Wake-on-LAN), `bleak` (Bluetooth), `pycaw` (volume), `wmi` (brilho), `winrt-Windows.Media.Control` (tocando agora) e `Pillow` (capa menor).

- **USB:** precisa do Apple Mobile Device Service, que vem com o app **Dispositivos Apple** (Microsoft Store) ou o iTunes. Plugue o iPhone desbloqueado e toque em **Confiar**.
- **PWA:** permita o firewall em **Redes privadas** (o instalador libera 8787/8788 se rodar como administrador).
- **Teclas:** ⌘ vira Ctrl (ou Windows com `TRACEPAD_CMD=win`) e ❖ é a tecla Windows. Gestos padrão: Win+Tab, Win+D, Ctrl+Win+←/→ e Ctrl+=/−, redefiníveis com `@nome` em `~\.tracepad-actions`; ações rodam no `cmd` (ou PowerShell com `TRACEPAD_SHELL=powershell`).

## Instalar por pacote

**Arch / Omarchy (AUR):**

```sh
yay -S tracepad
systemctl --user enable --now tracepad
```

O pacote instala a regra do udev do `/dev/uinput` e carrega o módulo `uinput` (saia e entre de novo na sessão). Os extras (Bluetooth, volume, brilho, playerctl…) são dependências opcionais.

**macOS (Homebrew)**, pelo tap [joaodobread/homebrew-tracepad](https://github.com/joaodobread/homebrew-tracepad):

```sh
brew install --cask joaodobread/tracepad/tracepad
```

O app é assinado ad-hoc; o cask tira a quarentena. Os arquivos ficam em `packaging/`; a cada tag `v*` o release anexa o `PKGBUILD` e o `tracepad.rb` com os sha256 preenchidos (`packaging/bump.sh VERSÃO` faz o mesmo localmente).

## iPhone

Com o iPhone conectado e desbloqueado (e o Modo de Desenvolvedor ativo em Ajustes › Privacidade e Segurança):

```sh
echo 'TEAM=SEU_TEAM_ID' > ios/local.env   # uma vez; ID em Xcode › Ajustes › Contas
./ios/install.sh
```

**Sem conta paga da Apple:** adicione sua Apple ID gratuita no Xcode (Ajustes › Contas), use o ID do "Personal Team" em `ios/local.env`. O app expira em 7 dias — é só rodar o script de novo. Na primeira instalação com conta grátis, confie no desenvolvedor em Ajustes › Geral › VPN e Gerenciamento de Dispositivo.

Bluetooth: na primeira conexão o iPhone e o Mac pedem para parear (a característica GATT exige criptografia).

**Vários computadores:** cada computador se apresenta ao conectar, e o topo da tela mostra qual está ativo e se é Mac ou Linux (ex.: "Bluetooth · Linux · pc-sala"). Com mais de um conectado por Bluetooth, todos ficam pareados ao mesmo tempo e só o escolhido recebe os comandos: toque no status no topo (ou em Ajustes › Conexão) para trocar. O iPhone lembra a escolha. O cabo sempre tem prioridade. Gestos e ações têm configuração separada para Mac e Linux e seguem o computador ativo. No Linux, o nome mostrado é o hostname (ou `TRACEPAD_NAME`).

Dica: para bloquear de vez a barra de Início, a Central de Controle e as notificações enquanto usa, ative o **Acesso Guiado** (Ajustes › Acessibilidade) e clique três vezes no botão lateral com o TracePad aberto.

## Gestos

| Dedos | Ação |
|---|---|
| 1 | mover · toque = clique · 2 toques = duplo clique · toque + toque-e-arrastar = arrastar |
| 2 | rolar (fases + inércia nativas, voltar/avançar no Safari) · toque = clique direito · pinça = zoom (⌘+/⌘−) |
| 3 | ↑ Mission Control · ↓ App Exposé · ←→ trocar mesa · toque = Consultar · (ou "Arrastar" nos ajustes) |
| 4 | ↓ Mostrar mesa · ↑ Mission Control · ←→ trocar mesa |

### Gestos configuráveis

Em Ajustes › **Gestos** (separado para Mac e Linux), cada gesto de 3 e 4 dedos (↑ ↓ ← → e toque) e a pinça pode ficar no **Padrão**, em **Nada** ou virar uma ação **Personalizada** (atalho, texto, abrir ou comando, como no modo Ações).

No Padrão, o iPhone manda só o nome do gesto e o computador decide o que fazer. Para mudar isso no próprio computador (vale também para o PWA), use `~/.tracepad-actions`:

```
# @gesto = atalho ou comando de shell
@mission = super+w
@space-left = super+pageup
@space-right = super+pagedown
@desktop = wmctrl -k on
```

Nomes: `mission`, `expose`, `desktop`, `space-left`, `space-right`, `lookup`, `zoom-in`, `zoom-out`. Atalhos usam `ctrl`, `alt`, `shift`, `super` (ou `cmd`) e o nome da tecla (`a`, `1`, `left`, `pageup`, `f11`, `enter`…); qualquer outra coisa roda como comando.

Teclado: botão ⌨ abre o teclado do iPhone com barra de esc, tab, setas e modificadores fixos (⌘ ⌥ ⌃ ⇧). Modificador + toque = ⌘-clique etc.

Botão ☀︎: painel com brilho (tela embutida), volume, mudo, controles de mídia e mais:

- **Copiar do PC / Colar no PC** — traz o texto copiado no computador para o iPhone, ou manda o do iPhone para lá.
- **Fotos / Arquivo** — envia para a pasta Downloads do computador (por USB é rápido; pelo Bluetooth, ~20–50 KB/s). O progresso aparece no topo, com botão para cancelar.

**Ligar pela rede**: em Ajustes, cada computador já conectado fica numa lista com o botão **Ligar** (Wake-on-LAN). O pacote mágico sai do computador conectado no momento — o iOS não deixa apps sem conta paga mandarem broadcast — então serve para acordar, por exemplo, o PC Linux a partir do Mac. O computador desligado precisa ter Wake-on-LAN ativo (de preferência no cabo).

## Modos

Troque em Ajustes › Modo:

- **Trackpad** — o padrão.
- **Monitor** — CPU, GPU, memória e disco em medidores, rede, bateria, histórico de CPU e processos que mais consomem (atualiza a cada 1 s).
- **Apps** — apps abertos em ordem alfabética, estilo ⌘-Tab. Toque para trazer para frente; apps com várias janelas mostram um número e abrem a lista para escolher a janela. Segure para ocultar ou encerrar. O bloco **+ Abrir app** lista os apps instalados no Mac, com busca.
- **Tocando agora** — capa, faixa, progresso e controles do player do computador. No Mac usa o MediaRemote (qualquer player) e, onde ele é bloqueado (macOS 15.4+), Música e Spotify por AppleScript; no Linux, `playerctl`.
- **Apresentação** — botões grandes de anterior/próximo (←/→), **Iniciar** (⌥⌘P no Keynote; F5 no Linux/Windows), **Sair**, **Tela preta**, cronômetro (toque pausa, segure zera), os **botões de volume** do iPhone passam slides e **segure para apontar** move o cursor pelo giroscópio, como um laser.
- **Ações** — grade de botões seus (cada um para todos os computadores ou só um sistema): **atalho** de teclado, **texto** pronto, **abrir** URL ou app, ou **comando** de shell. Toque em **+ Nova ação**; segure um botão para editar, mover ou excluir.

Comandos de shell ficam no computador, em `~/.tracepad-actions` (o iPhone só chama pelo nome, nunca envia o comando):

```
# Nome = comando
Bloquear tela = pmset displaysleepnow
Spotify = open -a Spotify
```

No Mac, abra pelo menu do TracePad › **Editar ações de shell…**. O arquivo é relido a cada uso.

## Protocolo

Linhas de texto, iguais em todos os transportes, nos dois sentidos (lista completa em `mac/Input.swift`): `m dx dy`, `c l|r|m [mods]`, `d`/`u`, `s fase momentum dx dy`, `k código [mods]`, `t texto`, volume/brilho/mídia, assinatura de monitor/apps (`w s|a|0`), controle de apps e janelas, ações (`C` lista os comandos de shell, `r nome` roda, `O alvo` abre URL/app) gestos padrão por nome (`g mission`) e apresentação do computador (`?` → `H mac|linux|windows nome`, enviada também ao conectar). Tocando agora é a assinatura `w n` (`N estado\tduração\tposição\ttítulo\tartista\tálbum\tapp` e capa `M base64`); área de transferência `y` / `Y base64`; arquivos `F nome`, `D base64`…, `E` → `E ok caminho`; Wake-on-LAN `K` → `K mac broadcast` e `R mac broadcast`.

- USB: iPhone escuta em `localhost:2345`; o Mac conecta pelo usbmuxd.
- BLE: serviço `6E7A0001-…`, característica de notify `6E7A0002-…`.
- PWA: HTTP `:8787`, WebSocket `:8788`, PIN em `~/.tracepad-pin`.

## Contribuindo

Veja [CONTRIBUTING.md](CONTRIBUTING.md).

## Licença

[MIT](LICENSE) © 2026 João Victor

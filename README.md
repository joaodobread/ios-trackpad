# TracePad

[![build](../../actions/workflows/build.yml/badge.svg)](../../actions/workflows/build.yml)
[![licença: MIT](https://img.shields.io/badge/licen%C3%A7a-MIT-blue.svg)](LICENSE)

Use o iPhone como trackpad do Mac ou do Linux — com gestos de verdade, vibração, teclado, ações customizadas, brilho/volume e skins.

- **App nativo do iPhone** (`ios/`): paisagem e tela cheia de verdade, Taptic Engine, skins. Conecta por **USB** (~1 ms, via usbmuxd) ou **Bluetooth LE** (~15 ms, sem Wi-Fi). USB tem prioridade.
- **App de barra de menus do Mac** (`mac/`): recebe os gestos e injeta no sistema. Também serve o **PWA** (`web/`) por Wi-Fi para quem não quer instalar nada no celular.
- **Host do Linux** (`linux/`): o mesmo, em Python — USB, Bluetooth e PWA; X11 e Wayland.

Builds prontos de cada commit ficam nos artefatos do [GitHub Actions](../../actions/workflows/build.yml) (app do Mac, `.ipa` sem assinatura para Sideloadly/AltStore e pacote do Linux); tags `v*` viram release.

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

As teclas chegam com códigos do Mac e viram as mesmas teclas físicas: ⌘ vira Ctrl (ou Super com `TRACEPAD_CMD=super`) e ❖ é Super. Os gestos padrão viram a visão geral (Super), Ctrl+Alt+←/→ para trocar de mesa e Super+D para mostrar a mesa — e dá para mudar (veja [Gestos configuráveis](#gestos-configuráveis)).

## iPhone

Com o iPhone conectado e desbloqueado (e o Modo de Desenvolvedor ativo em Ajustes › Privacidade e Segurança):

```sh
echo 'TEAM=SEU_TEAM_ID' > ios/local.env   # uma vez; ID em Xcode › Ajustes › Contas
./ios/install.sh
```

**Sem conta paga da Apple:** adicione sua Apple ID gratuita no Xcode (Ajustes › Contas), use o ID do "Personal Team" em `ios/local.env`. O app expira em 7 dias — é só rodar o script de novo. Na primeira instalação com conta grátis, confie no desenvolvedor em Ajustes › Geral › VPN e Gerenciamento de Dispositivo.

Bluetooth: na primeira conexão o iPhone e o Mac pedem para parear (a característica GATT exige criptografia).

Dica: para bloquear de vez a barra de Início, a Central de Controle e as notificações enquanto usa, ative o **Acesso Guiado** (Ajustes › Acessibilidade) e clique três vezes no botão lateral com o TracePad aberto.

## Gestos

| Dedos | Ação |
|---|---|
| 1 | mover · toque = clique · 2 toques = duplo clique · toque + toque-e-arrastar = arrastar |
| 2 | rolar (fases + inércia nativas, voltar/avançar no Safari) · toque = clique direito · pinça = zoom (⌘+/⌘−) |
| 3 | ↑ Mission Control · ↓ App Exposé · ←→ trocar mesa · toque = Consultar · (ou "Arrastar" nos ajustes) |
| 4 | ↓ Mostrar mesa · ↑ Mission Control · ←→ trocar mesa |

### Gestos configuráveis

Em Ajustes › **Gestos**, cada gesto de 3 e 4 dedos (↑ ↓ ← → e toque) e a pinça pode ficar no **Padrão**, em **Nada** ou virar uma ação **Personalizada** (atalho, texto, abrir ou comando, como no modo Ações).

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

Botão ☀︎: painel com brilho (tela embutida), volume, mudo e controles de mídia do Mac.

## Modos

Troque em Ajustes › Modo:

- **Trackpad** — o padrão.
- **Monitor** — CPU, GPU, memória e disco em medidores, rede, bateria, histórico de CPU e processos que mais consomem (atualiza a cada 1 s).
- **Apps** — apps abertos em ordem alfabética, estilo ⌘-Tab. Toque para trazer para frente; apps com várias janelas mostram um número e abrem a lista para escolher a janela. Segure para ocultar ou encerrar. O bloco **+ Abrir app** lista os apps instalados no Mac, com busca.
- **Ações** — grade de botões seus: **atalho** de teclado, **texto** pronto, **abrir** URL ou app, ou **comando** de shell. Toque em **+ Nova ação**; segure um botão para editar, mover ou excluir.

Comandos de shell ficam no computador, em `~/.tracepad-actions` (o iPhone só chama pelo nome, nunca envia o comando):

```
# Nome = comando
Bloquear tela = pmset displaysleepnow
Spotify = open -a Spotify
```

No Mac, abra pelo menu do TracePad › **Editar ações de shell…**. O arquivo é relido a cada uso.

## Protocolo

Linhas de texto, iguais em todos os transportes, nos dois sentidos (lista completa em `mac/Input.swift`): `m dx dy`, `c l|r|m [mods]`, `d`/`u`, `s fase momentum dx dy`, `k código [mods]`, `t texto`, volume/brilho/mídia, assinatura de monitor/apps (`w s|a|0`), controle de apps e janelas, ações (`C` lista os comandos de shell, `r nome` roda, `O alvo` abre URL/app) e gestos padrão por nome (`g mission`).

- USB: iPhone escuta em `localhost:2345`; o Mac conecta pelo usbmuxd.
- BLE: serviço `6E7A0001-…`, característica de notify `6E7A0002-…`.
- PWA: HTTP `:8787`, WebSocket `:8788`, PIN em `~/.tracepad-pin`.

## Contribuindo

Veja [CONTRIBUTING.md](CONTRIBUTING.md).

## Licença

[MIT](LICENSE) © 2026 João Victor

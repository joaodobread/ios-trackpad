# TracePad

[![build](../../actions/workflows/build.yml/badge.svg)](../../actions/workflows/build.yml)
[![licença: MIT](https://img.shields.io/badge/licen%C3%A7a-MIT-blue.svg)](LICENSE)

Use o iPhone como trackpad do Mac — com gestos de verdade, vibração, teclado, brilho/volume e skins.

- **App nativo do iPhone** (`ios/`): paisagem e tela cheia de verdade, Taptic Engine, skins. Conecta por **USB** (~1 ms, via usbmuxd) ou **Bluetooth LE** (~15 ms, sem Wi-Fi). USB tem prioridade.
- **App de barra de menus do Mac** (`mac/`): recebe os gestos e injeta no sistema. Também serve o **PWA** (`web/`) por Wi-Fi para quem não quer instalar nada no celular.

## Requisitos

- macOS 14+ com Xcode 16+ (ou só as Command Line Tools, para o app do Mac)
- iPhone com iOS 17+ (o PWA funciona em qualquer celular com navegador)

## Mac

```sh
./run.sh
```

Na primeira vez, permita o **TracePad** em Ajustes do Sistema › Privacidade e Segurança › **Acessibilidade** (e Bluetooth quando pedir).

## iPhone

Com o iPhone conectado e desbloqueado (e o Modo de Desenvolvedor ativo em Ajustes › Privacidade e Segurança):

```sh
echo 'TEAM=SEU_TEAM_ID' > ios/local.env   # uma vez; ID em Xcode › Ajustes › Contas
./ios/install.sh
```

**Sem conta paga da Apple:** adicione sua Apple ID gratuita no Xcode (Ajustes › Contas), use o ID do "Personal Team" em `ios/local.env`. O app expira em 7 dias — é só rodar o script de novo. Na primeira instalação com conta grátis, confie no desenvolvedor em Ajustes › Geral › VPN e Gerenciamento de Dispositivo.

Bluetooth: na primeira conexão o iPhone e o Mac pedem para parear (a característica GATT exige criptografia).

## Gestos

| Dedos | Ação |
|---|---|
| 1 | mover · toque = clique · 2 toques = duplo clique · toque + toque-e-arrastar = arrastar |
| 2 | rolar (fases + inércia nativas, voltar/avançar no Safari) · toque = clique direito · pinça = zoom (⌘+/⌘−) |
| 3 | ↑ Mission Control · ↓ App Exposé · ←→ trocar mesa · toque = Consultar · (ou "Arrastar" nos ajustes) |
| 4 | ↓ Mostrar mesa · ↑ Mission Control · ←→ trocar mesa |

Teclado: botão ⌨ abre o teclado do iPhone com barra de esc, tab, setas e modificadores fixos (⌘ ⌥ ⌃ ⇧). Modificador + toque = ⌘-clique etc.

## Protocolo

Linhas de texto, iguais em todos os transportes (ver `mac/Input.swift`): `m dx dy`, `c l|r|m [mods]`, `d`/`u`, `s fase momentum dx dy`, `k código [mods]`, `t texto`.

- USB: iPhone escuta em `localhost:2345`; o Mac conecta pelo usbmuxd.
- BLE: serviço `6E7A0001-…`, característica de notify `6E7A0002-…`.
- PWA: HTTP `:8787`, WebSocket `:8788`, PIN em `~/.tracepad-pin`.

## Contribuindo

Veja [CONTRIBUTING.md](CONTRIBUTING.md).

## Licença

[MIT](LICENSE) © 2026 João Victor

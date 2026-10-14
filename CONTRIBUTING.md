# Contribuindo

Issues e pull requests são bem-vindos.

## Ambiente

- macOS 14+ e Xcode 16+ (o projeto do iPhone usa pastas sincronizadas do Xcode 16).
- iPhone com iOS 17+ e Modo de Desenvolvedor ativo para testar no aparelho.

## Rodando

```sh
./run.sh                                   # app do Mac (barra de menus)
echo 'TEAM=SEU_TEAM_ID' > ios/local.env    # uma vez
./ios/install.sh                           # app do iPhone
```

`ios/local.env` fica fora do git: cada pessoa usa o próprio time de assinatura (uma Apple ID gratuita serve).

## Estrutura

| Pasta | O quê |
|---|---|
| `mac/` | App de barra de menus: injeção de eventos (`Input.swift`), USB via usbmuxd, Bluetooth LE, servidor do PWA, volume/brilho |
| `ios/` | App do iPhone: motor de gestos (`Trackpad.swift`), transportes (`Link.swift`), teclado, skins, painel de controles |
| `web/` | PWA (um único `index.html`) para usar por Wi-Fi sem instalar nada |

O protocolo é o mesmo em todos os transportes — linhas de texto descritas em `mac/Input.swift`. Ao adicionar um comando, implemente no Mac e nos clientes que precisarem dele.

## Estilo

- Swift sem dependências externas; prefira frameworks do sistema.
- Comentários em português, curtos, explicando o porquê.
- Antes de abrir o PR, confira que `swiftc mac/*.swift` e o build do projeto do iPhone passam (o CI roda os dois).

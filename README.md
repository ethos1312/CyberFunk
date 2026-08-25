# RA CYF — Realidade Aumentada Web

Aponte a câmera para qualquer um dos 18 pôsteres e o vídeo correspondente é
projetado exatamente sobre ele, alinhado pixel a pixel.

Construído com o **8th Wall Engine** (distribuição open source / self-hosted).

---

## ⚠️ Antes de tudo: o 8th Wall mudou

O 8th Wall que exigia conta, app key e hospedagem no `8thwall.com` **não existe mais**:

| Data | O que aconteceu |
|---|---|
| 28/02/2026 | Fim dos logins, da criação de contas e da edição de projetos |
| 28/02/2027 | Desligamento definitivo dos projetos ainda hospedados |

Em vez disso, a Niantic Spatial liberou o 8th Wall em **`8thwall.org`**: engine gratuito,
sem login, sem app key, e você hospeda onde quiser. As ferramentas auxiliares
(XRExtras, Image Target CLI) são MIT.

Este projeto já usa esse modelo novo. Ele **não** funcionaria copiado de um tutorial
antigo — o `//apps.8thwall.com/xrweb?appKey=...` e o `cdn.8thwall.com` daquela época
estão mortos.

---

## Rodando

### No PC

```powershell
.\serve.ps1
```

Abra <http://localhost:8080>. A câmera funciona porque `localhost` conta como origem
segura.

### No celular (é aqui que dá certo de verdade)

A câmera **só** é liberada em `https://`. Abrir o IP da rede local por HTTP não
funciona. Três caminhos, do mais simples ao mais técnico:

**1. Publicar (recomendado).** Qualquer host estático com HTTPS serve. Veja
[Publicando](#publicando) — atenção aos limites de tamanho de arquivo.

**2. Túnel temporário.** Com o `serve.ps1` rodando, em outro terminal:

```powershell
cloudflared tunnel --url http://localhost:8080
```

Ele devolve uma URL `https://...trycloudflare.com` que abre direto no celular.
Com `ngrok`: `ngrok http 8080`.

**3. Android + Chrome, só para teste.** Em `chrome://flags/#unsafely-treat-insecure-origin-as-secure`
adicione `http://SEU-IP:8080` e marque *Enabled*. Rode `.\serve.ps1` como
administrador para escutar na rede. **Não funciona no iPhone** — o Safari não tem
equivalente.

---

## Publicando

A pasta é 100% estática: suba o conteúdo de `webar/` na raiz do site.

O projeto inteiro pesa **27,5 MB** (20,2 MB de vídeo, maior arquivo 3,9 MB), então
cabe em qualquer host estático — Netlify, Vercel, Cloudflare Pages e GitHub Pages
funcionam sem ressalva.

Único requisito real: o host precisa aceitar requisições **Range**. Sem elas o vídeo
não reproduz no iOS. Todos os quatro acima aceitam.

### Os vídeos já foram otimizados

Os originais em `../VIDEO/` estavam em 2160×2700 a 10–25 Mbps — resolução e bitrate de
impressão, para clipes de 14 fps que na tela ocupam algumas centenas de pixels. Foram
reencodados para 1080×1350, CRF 21:

**235,8 MB → 20,2 MB, uma redução de 91%**, sem diferença visível (comparado em recortes
1:1 das áreas de meio-tom, que é onde a compressão apareceria primeiro).

Os originais continuam intactos em `../VIDEO/`. Para reencodar de novo — depois de
trocar algum clipe, ou com outra qualidade:

```powershell
.\tools\optimize-videos.ps1 -Crf 21 -Width 1080 -InPlace
```

Precisa do `ffmpeg` no PATH; sem isso, passe o caminho com `-FFmpeg` e `-FFprobe`.
O script detecta sozinho quais vídeos têm áudio (10 dos 18 têm) e descarta a faixa
nos que não têm.

---

## Estrutura

```
webar/
├── index.html                  cena A-Frame + UI
├── app.js                      carrega alvos, monta a cena, controla vídeo e som
├── styles.css                  HUD de scan e botão de som
├── serve.ps1                   servidor local com suporte a Range
├── image-targets/
│   ├── manifest.json           índice dos 18 alvos
│   ├── NN.json                 metadata de cada alvo (o engine lê isto)
│   ├── NN_luminance.png        512×640 em escala de cinza — o que é rastreado
│   └── NN_thumbnail.png        280×350, referência visual
├── video/
│   └── NN.mp4                  vídeo de cada alvo, 1080×1350
└── tools/
    ├── build-image-targets.ps1 regenera image-targets/ a partir de ../stll e ../VIDEO
    └── optimize-videos.ps1     reencoda os vídeos para a web (ffmpeg)
```

O par imagem↔vídeo é feito pelo **número do arquivo**: `stll/07.png` → `VIDEO/07.mp4`.

---

## Trocando ou adicionando imagens

1. Coloque a imagem em `../stll/` e o vídeo com **o mesmo número** em `../VIDEO/`.
2. Rode:

```powershell
.\tools\build-image-targets.ps1
```

Ele regenera tudo em `image-targets/`. Copie o novo `.mp4` para `webar/video/`.

O script substitui o `@8thwall/image-target-cli` oficial, que precisaria de Node,
npm e da biblioteca nativa `sharp` — nenhum deles instalado aqui. A saída segue o
mesmo schema `ImageTargetData`, então continua compatível com o engine. Se um dia
quiser usar o oficial: `npx @8thwall/image-target-cli@latest`.

**Uma diferença proposital:** o CLI oficial recorta a imagem para 3:4 por padrão.
Seus pôsteres são 4:5 (2160×2700), então o recorte oficial cortaria as laterais e o
vídeo ficaria desalinhado. Este script usa a imagem **inteira** como alvo, e por isso
o vídeo — que mantém a mesma proporção 4:5 — encaixa exatamente sobre o pôster impresso.
Se um dia trocar a proporção dos vídeos, regenere os alvos com o mesmo recorte.

### O que faz uma imagem rastrear bem

Seus pôsteres são ótimos alvos: alto contraste, textura de meio-tom densa, muita
linha. O rastreamento procura cantos e bordas, então o que atrapalha é o oposto —
áreas grandes e chapadas, degradês suaves, simetria repetitiva ou texto isolado
sobre fundo liso.

---

## Como funciona

```
manifest.json  →  NN.json (×18)  →  XR8.XrController.configure({imageTargetData})
```

`app.js` carrega os 18 alvos, cria um `<video>` e uma entidade rastreada para cada
um, e configura o engine. O componente `ar-video-plane` (em `app.js`) constrói o
plano do vídeo a partir da geometria real que o engine reporta ao reconhecer o
alvo — daí o encaixe exato, sem número mágico de escala.

**Detalhes que fazem diferença na prática:**

- **Carregamento sob demanda.** Os `<video>` nascem com `preload="none"` e ficam
  fora de `<a-assets>`. Dentro, o A-Frame travaria a cena até baixar os 20 MB de vídeo
  antes de mostrar qualquer coisa. Cada vídeo só começa a baixar quando seu alvo
  aparece — na prática, ~1 MB por reconhecimento.
- **Som.** Navegador nenhum toca áudio sem gesto do usuário. Os vídeos entram mudos
  e o botão *Toque para o som* libera o áudio — sempre um vídeo por vez, o do alvo
  reconhecido mais recentemente.
- **`disableWorldTracking: true`.** Sem SLAM o reconhecimento é mais rápido e leve,
  já que nada aqui depende de rastrear o ambiente.
- **`data-preload-chunks="slam"`.** Não é opcional: o `xr.js` é só o carregador, e o
  rastreamento de image target mora dentro do `xr-slam.js`. Sem o preload, esse
  chunk de 5,4 MB só seria baixado quando a câmera iniciasse, atrasando o primeiro
  reconhecimento.
- **18 alvos ativos ao mesmo tempo.** O engine rastreia até 32 simultâneos, então
  não é preciso alternar conjuntos em runtime.
- **Cor do vídeo.** A textura é marcada como sRGB; sem isso o vídeo sai lavado sob o
  gerenciamento de cor do A-Frame.

---

## Dependências (todas via CDN, nada para instalar)

| O quê | Versão | Licença |
|---|---|---|
| A-Frame | 1.5.0 | MIT |
| `@8thwall/xrextras` | 1 | MIT |
| `@8thwall/landing-page` | 1 | MIT |
| `@8thwall/engine-binary` | 1 | Limited-use (binário) |

A-Frame 1.5.0 é proposital: é a versão que o 8th Wall espelha no `8frame-1.5.0`,
então é a combinação de menor risco com o XRExtras 1.0.0.

O engine binário **não** é MIT — é uma licença de uso limitado, com exigência de
atribuição. Antes de usar comercialmente, leia:

- Licença: <https://github.com/8thwall/engine/blob/main/LICENSE>
- Uso permitido e atribuição: <https://8thwall.org/docs/open-source>

---

## Se algo não funcionar

| Sintoma | Causa provável |
|---|---|
| Câmera não abre | Origem não é HTTPS nem `localhost` |
| Tela preta, sem erro | Permissão de câmera negada — recarregue e aceite |
| Reconhece mas o vídeo não toca | Host não aceita requisições Range |
| Vídeo desalinhado do pôster | `image-targets/` regenerado com recorte diferente do vídeo |
| Nada é reconhecido | Pouca luz, pôster amassado, ou impresso muito pequeno |
| `manifest.json 404` | Abriu o `index.html` como arquivo; precisa servir por HTTP |

O console do navegador registra tudo com o prefixo `[RA CYF]`, incluindo quantos
alvos foram montados e configurados.

# xpl-f

File explorer TUI, built as a study project for learning Zig.

Written with assistance from Claude Code

<p align="center">
  <img src="screenshots/xpl-f-help.png" width="700" alt="xpl-f help"><br>
  <em>help popup (F1)</em>
</p>

<p align="center">
  <img src="screenshots/xpl-f-split.png" width="700" alt="xpl-f split"><br>
  <em>split panel (Ctrl+S)</em>
</p>

## Quick Start

```sh
zig build run                     # abre no diretório atual
zig build run -- /path/to/dir     # abre em diretório específico
```

Navegue com `j/k`, abra com `Enter`, volte com `-`. Pressione `F1` para ver todos os atalhos.

## Stack

- **Zig 0.15** com **libvaxis** (terminal rendering)
- Zero dependências externas além do libvaxis
- Convention over configuration — sem arquivos de config

## Build & Run

```sh
zig build                         # debug build
zig build -Doptimize=ReleaseSmall # release
zig build run                     # run direto
zig build run -- /path/to/dir     # abrir em diretório específico
```

O binário fica em `zig-out/bin/xpl-f`. Deploy script em `0-deploy`.

### Man page

```sh
sudo cp xpl-f.1 /usr/local/share/man/man1/
man xpl-f
```

## Arquitetura

```
src/
├── main.zig     # Entry point, parse de args, cria App
├── app.zig      # Core: event loop, input handlers, estado da aplicação
├── render.zig   # Renderização: main window, popups (help, confirm, replace, preview)
├── dir.zig      # Estado do diretório: scan síncrono, filtro, edit mode, operações
├── scanner.zig  # Scan assíncrono: background threads, find progressivo, generation counter
├── entry.zig    # FileEntry: tipo, ícone, estilo, formatação de size/date, ordenação
├── mode.zig     # Enums: Mode, PendingKey, ReplaceField
└── style.zig    # Paleta de cores (Catppuccin-like), ícones
```

### Fluxo principal

1. `main.zig` cria `App` com allocator e diretório inicial
2. `App.run()` roda o event loop: `nextEvent() → update() → draw() → render()`
3. `update()` despacha key events para handlers por modo (normal, edit, search, replace, confirm, help, preview)
4. `draw()` chama `render.draw()` com o estado atual, usando um frame arena allocator

### Sistema de modos

| Modo | Propósito |
|------|-----------|
| normal | Navegação e comandos |
| edit | Edição inline de nomes de arquivo |
| search | Filtro fuzzy por nome |
| replace | Search & replace em nomes |
| confirm | Confirmação de operações destrutivas |
| help | Popup de ajuda (F1) |
| preview | Preview flutuante de arquivos |

### Keybindings (normal mode)

**Navegação**
- `j/k` ou setas: navegar
- `>/Enter`: abrir (texto → $EDITOR, binários → xdg-open)
- `</-`: diretório pai
- `0/Home`: topo
- `$/End`: fim
- `Ctrl+s`: toggle dual panel
- `Tab`: trocar foco entre painéis

**Busca & Filtro**
- `/`: busca fuzzy
- `r`: search & replace em nomes
- `?`: busca recursiva
- `\`: tree view

**Operações**
- `Space`: selecionar
- `Ctrl+a`: selecionar tudo (toggle)
- `Ctrl+d`: drag & drop (via ripdrag)
- `n`: novo arquivo/diretório
- `Y`: duplicar arquivo
- `D`: deletar arquivo/seleção
- `x`: cortar para clipboard
- `y`: copiar para clipboard
- `p`: colar (paste)
- `c`: copiar path para clipboard do sistema
- `F2`: renomear (edit mode)
- `F3`: preview flutuante
- `F4`: abrir shell no diretório atual
- `F5`: refresh
- `m`: toggle bookmark no diretório atual
- `b`: abrir lista de bookmarks
- `.`: toggle hidden files
- `q`: sair

### Preview

- Detecta binários por extensão (~50 formatos), magic bytes e análise de conteúdo
- Arquivos texto: mostra com números de linha, scroll com j/k
- Diretórios: tree view recursivo (até 3 níveis) com conectores
- Binários: mostra `[binary file]`

### Abertura de arquivos

- Extensões binárias (pdf, png, mp4, etc.) → `xdg-open` em background
- Arquivos texto → `$EDITOR` (fallback: vi), saindo temporariamente do alt screen

## Convenções de código

- Arena allocator por frame para alocações temporárias de renderização
- Child windows do libvaxis para clipping de colunas
- Popups usam `win.child()` com border e `popup.clear()`
- Commit messages em português

## Ideias futuras

- **Syntax highlighting no preview**: colorir código por linguagem no popup de preview
- **Two-stage loading (Fase 2)**: listar nomes+kind instantaneamente (sem `statx`), renderizar de imediato, e preencher metadata (size, date, permissions) em batches progressivos no background — útil para NFS, HDD lento ou diretórios com dezenas de milhares de arquivos
- **Cache de diretório com inotify**: manter cache de diretórios visitados e invalidar via `inotify`, evitando re-scan ao navegar de volta
- **getdents64 direto**: substituir `std.fs.Dir.iterate()` por syscall `getdents64` direta para travessia ainda mais rápida
- **Pre-fetch de diretórios adjacentes**: carregar em background o conteúdo do diretório sob o cursor, para navegação instantânea ao pressionar Enter


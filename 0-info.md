# 0-info — xpl-f

Caderno interno (não-público). Espelha CLAUDE.md/MEMORY.md do projeto. README é separado.

## Stack

- Zig 0.15 (stdlib path `/usr/lib/zig/std`)
- libvaxis (TUI, deps em `build.zig.zon`)
- Linux-only (`std.os.linux.statx`, `linux.AT.*`)
- Build: `zig build` → `zig-out/bin/xpl-f`

## Arquitetura (resumo)

Ver `ARCHITECTURE.md` para diagramas Mermaid completos. Módulos:

| Módulo | Responsabilidade |
|--------|-----------------|
| `main.zig` | Entry, parse arg (path ou alias bookmark) |
| `app.zig` | Event loop, estado global, handlers por modo |
| `scanner.zig` | I/O async em threads: scan, find, clean |
| `dir.zig` | DirState: scan sync, filtro fuzzy, edit mode |
| `render.zig` | TUI render (stateless) |
| `entry.zig` | FileEntry + formatadores |
| `mode.zig` | Enums de modo |
| `style.zig` | Cores/ícones |
| `utils.zig` | Helpers |

## Modos (enum em `mode.zig`)

`normal | edit | search | replace | confirm | help | preview | create | find | bookmark | clean`

## Async workers (scanner.zig)

Padrão: thread spawnada por request, generation atômica para cancelamento, resultado postado via `loop.postEvent`. Main thread descarta se generation mudou.

- **scanWorker** — list 1 dir, statx por entry, sort
- **findWorker** — walk recursivo, batches de 200 paths, skip `node_modules`/`target`/`__pycache__`
- **cleanWorker** — walk recursivo + filtros estruturais, batches de 100 `CleanItem` (path+size+mtime+kind+reason)

Cada worker tem `generation` separada (`generation`, `find_generation`, `clean_generation`).

## Ownership de strings

- DirState: `name_arena` (ArenaAllocator) dona dos nomes; entries indexam em `all_entries` ArrayList
- find/clean: arena por batch, `find_batch_arenas`/`clean_arenas` em App segura vivas até modo sair
- Sempre `dupe` no thread worker antes de `postEvent` (path original livre)

## Modo CLEAN (adicionado 2026-05-11)

Cleanup BleachBit-style. `Ctrl+K` no normal entra.

**Filtros** (`scanner_mod.CleanFilter`):
- `size: ?SizeCond` (`s` → prompt) — DSL: `=0`, `>=10M`, `<=1K`, `10M` (default op `>=`). Sufixos `K/M/G` binários (1024).
- `age: ?AgeCond` (`a` → prompt) — DSL: `>30d`, `<7d`, `30d` (default op `>`). Sufixo `d` obrigatório.
- `name_patterns` (`n`) — junk: `*~`, `*.bak`, `*.tmp`, `*.swp`, `*.swo`, `*.pyc`, `*.pyo`, `*.class`, `*.orig`, `*.rej`, `.DS_Store`, `Thumbs.db`, `desktop.ini`, `core.<digits>`
- `empty_dirs` (`e`) — dirs sem filhos
- `broken_symlinks` (`l`) — links com target inexistente

**Input sub-mode:** `s` ou `a` abre prompt inline na status bar. Pré-preenche valor atual se já configurado. Enter parse+aplica (erro mostrado em vermelho ao lado), Esc cancela só o prompt. Esc no clean sem prompt aberto sai do modo. Buffer vazio + Enter limpa o filtro.

**Parsers** (`scanner.zig`):
- `parseSizeExpr` → `SizeCond{op: eq|ge|le, value: u64}` ou `ParseError`
- `parseAgeExpr` → `AgeCond{op: gt|lt, days: u32}` ou `ParseError`
- Erros: `Empty`, `BadOperator`, `BadNumber`, `BadSuffix`, `BadUnit`

**Algoritmo (cleanWorker):**
- `dir.walk(allocator)` recursivo
- Por entry: `statx(parent_fd, basename, AT.SYMLINK_NOFOLLOW, ...)` p/ size+mtime
- broken_symlink: 2º statx sem `SYMLINK_NOFOLLOW`, ENOENT → broken
- empty_dir: `parent.openDir(basename).iterate().next() == null`
- name_pattern: lookup tabela exata + suffix + regex caseiro para `core.\d+`
- Reason: primeira match vence (não cumula)

**Diferenças vs findWorker:**
- Não pula `node_modules`/`target`/`__pycache__` (são alvos válidos)
- Skip hidden ainda respeitado se `show_hidden=false`
- max_results = 10000

**MVP é só listar.** Sem delete em massa, sem trash. Enter no item → navega ao parent (ou ao próprio dir se `empty_dir`).

**Keybind:** `Ctrl+K` (Ctrl+L já usado em preview, Ctrl+F = find, Ctrl+S = split panel).

## Convenções

- Mensagens UI em pt-BR (status bar, prompts, comentários históricos)
- Commits em pt-BR informal ("corrigido bug com X", "melhoria em Y", "versao")
- Fragmentos de código sem doc strings; código auto-explicativo
- Usuário mantém código antigo comentado durante migração (aprendendo Zig) — não remover sem confirmar
- Não usar emojis em arquivos
- `git status` mostra modificados — staging manual pelo usuário antes de commit

## Gotchas Zig

- `std.fs.Dir.Walker.Entry.basename` é `[:0]const u8` — `.ptr` direto vira `[*:0]const u8` p/ syscalls. Memória invalida no próximo `next()`.
- `linux.statx` retorna `usize`; testar com `linux.E.init(rc) == .SUCCESS`
- ArenaAllocator `deinit` libera tudo; `reset(.retain_capacity)` reusa capacidade
- ArrayList em Zig 0.15: `Unmanaged`-style, passa allocator nos métodos (`append(alloc, ...)`)
- `loop.postEvent` precisa Event union; cada novo modo async = nova variante em `Event`

## Bugs/incidentes conhecidos

- **Emojis em filenames** (project_emoji_column_shift): libvaxis e terminal divergem em largura → colunas shiftadas. Não resolvido.
- **node_modules em find**: pulado deliberadamente para performance. Em clean é incluído (escolha consciente).

## Lições

- Async com generation atômica + postEvent funciona bem; cuidado p/ descartar resultado stale no main thread (deinit arena dele)
- Adicionar novo modo TUI = mode.zig enum + handler em app.zig + render state struct + 2 lugares em render.zig (draw + status). Roteamento via switch
- Walker invalida memória entre nexts → copia em arena imediatamente

## Workflow

- Sempre `zig build` antes de declarar pronto
- TUI não testável headless; smoke test = `xpl-f /caminho/invalido` (exit 1, sem corromper screen)
- Para testar feature interativa: criar fixture (`/tmp/xpl-clean-test/...`), rodar manualmente

------------------------------------------------------------------------------------------------------------------------------



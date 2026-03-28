# Arquitetura do xpl-f

## Visão geral dos módulos

```mermaid
graph TD
    main[main.zig<br><i>entry point</i>]
    app[app.zig<br><i>event loop, estado, handlers</i>]
    scanner[scanner.zig<br><i>scan async, find progressivo</i>]
    dir[dir.zig<br><i>DirState, filtro, edit mode</i>]
    render[render.zig<br><i>renderização TUI</i>]
    entry[entry.zig<br><i>FileEntry, formatação</i>]
    mode[mode.zig<br><i>enums de modo</i>]
    style_mod[style.zig<br><i>cores, ícones</i>]
    utils[utils.zig<br><i>helpers</i>]
    vaxis[libvaxis<br><i>terminal rendering</i>]

    main --> app
    app --> dir
    app --> scanner
    app --> render
    app --> style_mod
    app --> mode
    app --> vaxis
    scanner --> dir
    scanner --> entry
    scanner -.->|postEvent| app
    dir --> entry
    render --> dir
    render --> entry
    render --> style_mod
    render --> mode
    render --> utils
    entry --> style_mod
    style_mod --> vaxis
    render --> vaxis
```

## Ownership (quem possui o quê)

```mermaid
graph TD
    app[App]
    ds_main[DirState<br><i>painel principal</i>]
    ds_dest[DirState<br><i>painel destino</i>]
    scanner[Scanner]
    entries_m[all_entries<br>ArrayList‹FileEntry›]
    filtered_m[filtered_entries<br>ArrayList‹usize›]
    arena_m[name_arena<br>ArenaAllocator]
    entries_d[all_entries<br>ArrayList‹FileEntry›]
    filtered_d[filtered_entries<br>ArrayList‹usize›]
    arena_d[name_arena<br>ArenaAllocator]
    scan_t[scan_thread]
    find_t[find_thread]
    gen[generation<br>atomic u64]
    find_gen[find_generation<br>atomic u64]
    find_paths[find_all_paths]
    batch_arenas[find_batch_arenas]

    app --> ds_main
    app --> ds_dest
    app --> scanner
    app --> find_paths
    app --> batch_arenas
    ds_main --> entries_m
    ds_main --> filtered_m
    ds_main --> arena_m
    ds_dest --> entries_d
    ds_dest --> filtered_d
    ds_dest --> arena_d
    scanner --> scan_t
    scanner --> find_t
    scanner --> gen
    scanner --> find_gen
```

## Event loop principal

```mermaid
sequenceDiagram
    participant Main as main thread
    participant Loop as vaxis.Loop
    participant Render as render.zig
    participant TTY as Terminal

    loop cada frame
        Loop->>Main: nextEvent() [bloqueia]
        alt key_press
            Main->>Main: update() → handler por modo
        else winsize
            Main->>Main: resize terminal
        else scan_complete
            Main->>Main: handleScanComplete()
        else find_batch
            Main->>Main: handleFindBatch()
        end
        Main->>Render: draw(estado)
        Render->>TTY: vx.render()
    end
```

## Scan assíncrono (navegação)

```mermaid
sequenceDiagram
    participant User as Usuário
    participant App as app.zig
    participant Scanner as scanner.zig
    participant Thread as scan thread
    participant Loop as vaxis.Loop

    User->>App: Enter (entra no diretório)
    App->>App: requestScanAsync(path, .main)
    App->>App: is_scanning = true
    App->>Scanner: requestScan(path, target, uid, hidden)
    Scanner->>Scanner: generation += 1
    Scanner->>Thread: spawn scanWorker

    Note over App: UI continua responsiva<br>[scanning] na status bar

    Thread->>Thread: openDir → iterate → statx → sort

    alt generation ainda válida
        Thread->>Loop: postEvent(.scan_complete)
        Loop->>App: nextEvent() → scan_complete
        App->>App: handleScanComplete()
        App->>App: dir_state.acceptScanResult()
        App->>App: is_scanning = false
    else usuário navegou para outro lugar
        Thread->>Thread: generation mudou → descarta resultado
        Thread->>Thread: deinit arena, free entries
    end
```

## Find progressivo (busca recursiva)

```mermaid
sequenceDiagram
    participant User as Usuário
    participant App as app.zig
    participant Scanner as scanner.zig
    participant Thread as find thread
    participant Loop as vaxis.Loop

    User->>App: ? (enter find mode)
    App->>Scanner: requestFind(path, hidden, 10000)
    Scanner->>Thread: spawn findWorker
    App->>App: mode = .find, find_walking = true

    loop a cada 200 resultados
        Thread->>Thread: walk → filtrar hidden → acumular batch
        Thread->>Loop: postEvent(.find_batch)
        Loop->>App: handleFindBatch()
        App->>App: append paths + atualizar filtro
        Note over App: Usuário já vê resultados<br>e pode digitar/filtrar
    end

    Thread->>Loop: postEvent(.find_batch, is_final=true)
    Loop->>App: handleFindBatch()
    App->>App: find_walking = false

    alt Escape antes de terminar
        User->>App: Escape
        App->>Scanner: cancelFind()
        Scanner->>Scanner: find_generation += 1
        Scanner->>Thread: join (thread checa generation e sai)
    end
```

## Fluxo de dados do FileEntry

```mermaid
flowchart LR
    FS[Sistema de<br>arquivos] -->|iterate + statx| Scanner
    Scanner -->|ScanResult<br>arena + entries| App
    App -->|acceptScanResult<br>swap arena| DirState
    DirState -->|apply_filter| Filtered[filtered_entries<br>índices]
    DirState -->|get_entry| Render
    Render -->|format_size<br>format_date<br>format_perms<br>get_icon| Entry[FileEntry]
    Entry -->|get_style| Style[style.zig]
    Render -->|printSegment| TTY[Terminal]
```

## Transferência de ownership no scan

```mermaid
flowchart TD
    subgraph "scan thread"
        A1[cria ArenaAllocator] --> A2[dupe nomes na arena]
        A2 --> A3[constrói ArrayList‹FileEntry›]
        A3 --> A4[sort entries]
        A4 --> A5[empacota ScanResult]
    end

    A5 -->|postEvent| B1

    subgraph "main thread"
        B1[recebe ScanResult] --> B2{generation válida?}
        B2 -->|sim| B3[deinit arena antiga]
        B3 --> B4[swap: arena e entries<br>passam para DirState]
        B4 --> B5[apply_filter]
        B2 -->|não| B6[deinit arena do resultado<br>descarta entries]
    end
```

## Modelo de filtragem

```mermaid
flowchart TD
    ALL[all_entries<br>todos os arquivos, ordenados]
    HIDDEN{show_hidden?}
    QUERY{search_query?}
    FUZZY[fuzzy_match]
    FILTERED[filtered_entries<br>índices visíveis]
    RENDER[render mostra<br>filtered_entries‹scroll..scroll+height›]

    ALL --> HIDDEN
    HIDDEN -->|não e nome começa com .| SKIP1[pula]
    HIDDEN -->|sim ou nome visível| QUERY
    QUERY -->|vazio| FILTERED
    QUERY -->|não vazio| FUZZY
    FUZZY -->|match| FILTERED
    FUZZY -->|no match| SKIP2[pula]
    FILTERED --> RENDER
```

## Resumo de responsabilidades

| Módulo | Responsabilidade | Estado que possui |
|--------|-----------------|-------------------|
| **main.zig** | Entry point, parse de args | Nenhum |
| **app.zig** | Orquestrador: event loop, handlers, estado global | App, cursores, buffers, modos |
| **scanner.zig** | I/O assíncrono em threads separadas | Threads, generation counters |
| **dir.zig** | Estado do diretório: scan síncrono, filtro, edição | Entries, arena, filtros |
| **render.zig** | Renderização (read-only, sem estado) | Nenhum |
| **entry.zig** | Struct FileEntry + formatação | Dados do arquivo |
| **mode.zig** | Enums puros | Nenhum |
| **style.zig** | Constantes de cor e ícones | Nenhum |
| **utils.zig** | Funções utilitárias | Nenhum |

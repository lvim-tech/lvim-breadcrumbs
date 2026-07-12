# lvim-breadcrumbs

"Where am I in the code" — the symbol path from the document root to the cursor
(`module ➤ class ➤ method`), fed by LSP `textDocument/documentSymbol` with a treesitter
fallback, exposed as **data** for statusline/winbar consumers plus an optional
self-rendered winbar.

- **Data engine** — a per-buffer symbol **tree cache**: hierarchical `DocumentSymbol[]`
  preferred, flat `SymbolInformation[]` upconverted by range containment. One request per
  **edit** (debounced `TextChanged`/`InsertLeave`, the in-flight request cancelled before
  the next is issued), never per cursor move — cursor moves only **binary-search** the
  cached ranges into the ancestor chain.
- **Treesitter fallback** — buffers with no documentSymbol client get the structural
  named-node ancestor chain from the parser tree (function / method / class / struct /
  enum / interface / module / field), in the same output shape.
- **Consumer contract** — `get_data()` is the stable seam: every entry carries `name`,
  `kind` (LSP number), `type` (kind name), `icon`, `hl`, `scope_range` and the jump
  target. `get_location()` renders the `➤`-separated trail with per-kind highlight
  groups.
- **lvim-hud integration** — `hud_segment()` returns a ready-made chrome winbar segment:
  drop it into the hud winbar's segment list and the clickable trail renders **inside**
  the lvim-hud winbar (clicking a segment jumps to that symbol).
- **Self-rendered winbar** — opt-in (`attach_winbar = true`) for setups without a chrome
  winbar; it only ever claims **empty** winbars (a winbar owned by lvim-hud or any other
  plugin is never overwritten).
- **Icons & theming** — the kind glyphs are the same set lvim-lsp's outline uses (read
  live from lvim-lsp when installed, bundled otherwise), and the per-kind colours follow
  the outline's accent mapping, all derived from the lvim-utils palette (they re-theme on
  colorscheme/palette change).

## Requirements

- Neovim >= 0.11
- [lvim-utils](https://github.com/lvim-tech/lvim-utils) (palette theming + config merge)
- Optional: [lvim-lsp](https://github.com/lvim-tech/lvim-lsp) (shared kind-icon table),
  [lvim-icons](https://github.com/lvim-tech/lvim-icons) (the `file_prefix` icon),
  [lvim-ts](https://github.com/lvim-tech/lvim-ts) (parser runtime for the treesitter
  fallback), [lvim-hud](https://github.com/lvim-tech/lvim-hud) (the chrome winbar the
  `hud_segment()` plugs into)

## Installation

With **lvim-installer** the plugin is part of the lvim-tech set. Standalone, with
Neovim's native `vim.pack`:

```lua
vim.pack.add({
    "https://github.com/lvim-tech/lvim-utils",
    "https://github.com/lvim-tech/lvim-breadcrumbs",
})
```

## Setup

The full default configuration (every option at its default):

```lua
require("lvim-breadcrumbs").setup({
    -- Debounce (ms) for the documentSymbol re-request after an edit; the in-flight
    -- request is cancelled before the next is issued. Cursor moves never request.
    refresh_ms = 300,
    -- Cap the rendered chain to the DEEPEST n segments (the elided head is replaced by
    -- depth_limit_indicator). 0 = render the full chain.
    depth_limit = 0,
    depth_limit_indicator = "…",
    -- Lead the rendered path with `icon filename` (icon + colour via lvim-icons).
    file_prefix = true,
    -- Self-rendered winbar for attached buffers. It never overwrites a winbar another
    -- plugin owns; with the lvim-hud chrome winbar use hud_segment() instead.
    attach_winbar = false,
    -- Filetypes never attached (also skipped by the winbar/segment renderers).
    exclude_ft = {},
    -- When a buffer has no documentSymbol source, derive the chain from the treesitter
    -- parser tree (same output shape).
    ts_fallback = true,
})
```

`setup()` installs an `LspAttach` autocmd that attaches every documentSymbol-capable
client automatically (and sweeps clients that started before it ran), so no per-server
wiring is needed. `attach(client, bufnr)` stays available as the manual seam for an
`on_attach` handler:

```lua
require("lvim-breadcrumbs").attach(client, bufnr)
```

## API

```lua
local bc = require("lvim-breadcrumbs")

bc.is_available(bufnr) -- boolean: can a chain be produced here?
bc.get_data(bufnr) -- LvimBreadcrumbsEntry[]|nil — the stable data seam
bc.get_location(opts) -- the rendered trail (statusline-format string)
bc.hud_segment(opts) -- a ready-made lvim-hud chrome winbar segment
```

`get_data()` returns the ancestor chain at the buffer's cursor, root first. Each entry:

| field         | meaning                                                              |
| ------------- | -------------------------------------------------------------------- |
| `name`        | symbol name                                                          |
| `kind`        | LSP `SymbolKind` number                                              |
| `type`        | kind name (`"Function"`, `"Class"`, …)                               |
| `icon`        | the kind glyph (shared lvim-lsp outline set)                         |
| `hl`          | `LvimBreadcrumbs<KindName>` highlight group                          |
| `scope_range` | the symbol's full range (`start`/`end`, LSP positions)               |
| `jump`        | the selection start — where a consumer should place the cursor       |

`get_location(opts)` options (each defaulting to its config value where one exists):
`bufnr`, `highlight` (embed `%#…#` groups; default `true`), `clicks` (wrap segments in
`%N@…@` jump regions — winbar renderers only; default `false`), `file_prefix`,
`depth_limit`, `depth_limit_indicator`.

## lvim-hud winbar segment (recommended)

With the lvim-hud chrome winbar, wire the breadcrumb in as a **segment** — one line in
the winbar's segment list:

```lua
segments[#segments + 1] = require("lvim-breadcrumbs").hud_segment()
```

The segment renders in active windows, follows the cursor on every redraw, and each
symbol is clickable (jumps to its definition). `hud_segment()` options: `name` (segment
cache key, default `"wb_breadcrumbs"`), `inactive = true` to render in inactive windows
too, `file_prefix = true` to prepend the file icon + name (off by default here — a
chrome winbar already has its own file segment).

## Self-rendered winbar

For a setup without a chrome winbar, `attach_winbar = true` sets a window-local winbar
on every window showing an attached buffer — the same clickable trail, with the
`file_prefix` lead. It only ever writes over an **empty** winbar (or its own), so a
winbar owned by lvim-hud or any other plugin is never clobbered, and it only ever clears
its own on detach.

## Highlights

All groups derive from the lvim-utils palette and re-theme automatically. One
`LvimBreadcrumbs<KindName>` group per LSP SymbolKind (`LvimBreadcrumbsFunction`,
`LvimBreadcrumbsClass`, …) with the same accent-per-kind mapping lvim-lsp's outline
uses, plus:

| group                      | role                                        |
| -------------------------- | ------------------------------------------- |
| `LvimBreadcrumbsSeparator` | the `➤` separators and the `…` elision      |
| `LvimBreadcrumbsFile`      | the `file_prefix` filename                  |

## Health

`:checkhealth lvim-breadcrumbs` reports the symbol source of the current buffer (LSP
tree / treesitter fallback / none), the kind-icon source (shared lvim-lsp table vs the
bundled copy, with a drift warning), the optional dependencies and the winbar mode.

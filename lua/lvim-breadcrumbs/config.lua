-- lvim-breadcrumbs: the live configuration table.
-- Holds the defaults; setup() merges user overrides into it in place (via
-- lvim-utils.utils.merge), so every require("lvim-breadcrumbs.config") reader sees the
-- effective values. All options are read live (no snapshot at attach time), so flipping
-- e.g. `depth_limit` at runtime takes effect on the next render.
--
---@module "lvim-breadcrumbs.config"

---@class LvimBreadcrumbsConfig
---@field refresh_ms            integer   Debounce (ms) for the documentSymbol re-request after an edit
---@field depth_limit           integer   Max rendered segments; 0 = unlimited (deepest kept, head elided)
---@field depth_limit_indicator string    Elision marker shown in place of the dropped head segments
---@field file_prefix           boolean   Lead the rendered path with `icon filename` (icon via lvim-icons)
---@field attach_winbar         boolean   Self-render a winbar for attached buffers (OFF: consume get_data/get_location — e.g. the lvim-hud chrome segment)
---@field exclude_ft            string[]  Filetypes never attached (and skipped by the winbar/segment)
---@field ts_fallback           boolean   Derive the chain from the treesitter tree when no LSP symbols exist

---@type LvimBreadcrumbsConfig
return {
    -- An edit (TextChanged / InsertLeave) re-requests the symbol tree after this much quiet
    -- time; the in-flight request is cancelled before the next is issued, so typing never
    -- queues a backlog. Cursor moves never request — they only binary-search the cached tree.
    refresh_ms = 300,
    -- Cap the rendered chain (get_location / winbar) to the DEEPEST n segments; the elided
    -- head is replaced by `depth_limit_indicator`. 0 = render the full chain.
    depth_limit = 0,
    depth_limit_indicator = "…",
    -- Lead with the buffer's `icon filename` (icon + colour from lvim-icons when installed,
    -- name in LvimBreadcrumbsFile). Applies to get_location and the winbar renderers.
    file_prefix = true,
    -- Self-rendered winbar (winbar.lua): opt-in, and it NEVER overwrites a winbar another
    -- plugin owns (e.g. the lvim-hud chrome winbar). With lvim-hud the recommended path is
    -- the ready-made segment — require("lvim-breadcrumbs").hud_segment() — inside
    -- chrome.winbar.segments, not this renderer.
    attach_winbar = false,
    -- Buffers of these filetypes are never attached; the hud segment and the self-rendered
    -- winbar also skip them.
    exclude_ft = {},
    -- When a buffer has no documentSymbol-capable client (or the tree is not yet cached),
    -- fall back to the named-node ancestor chain of the treesitter parser (ts.lua) — same
    -- output shape, so consumers never care which engine produced the chain.
    ts_fallback = true,
}

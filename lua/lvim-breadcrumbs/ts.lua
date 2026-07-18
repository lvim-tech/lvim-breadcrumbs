-- lvim-breadcrumbs.ts: the treesitter fallback chain — for buffers with NO documentSymbol
-- source (no client, or the tree not yet cached). Walks the parser's named-node ancestors at
-- the cursor and keeps only the STRUCTURAL ones (function / method / class / struct / enum /
-- interface / module / field …), classified by node TYPE: an exact node-type map first (the
-- grammar names that don't pattern-match, e.g. rust's `impl_item`), then substring patterns
-- (any grammar's `*function*` / `*class*` / …). Each kept node needs a NAME (its `name` field,
-- or a direct identifier child) — anonymous constructs are skipped, they say nothing in a
-- breadcrumb. The output is the SAME entry shape locate.lua emits, so consumers never care
-- which engine produced the chain. The parser itself is lvim-ts's runtime (installed on
-- demand); this module only reads the tree — no parsing is forced beyond an incremental
-- `parse()`, and the walk is a handful of parent steps per render.
--
---@module "lvim-breadcrumbs.ts"

local kinds = require("lvim-breadcrumbs.kinds")

local M = {}

--- Per-buffer memo of the last computed chain. `M.chain` runs per winbar/statusline redraw (and
--- redraws are frequent — mode changes, focus, `:redrawstatus`), but its inputs only change on an
--- edit or a cursor move; caching gives the treesitter fallback the same "compute once per (edit,
--- cursor)" the LSP path already gets from `locate.update`. Keyed by `changedtick` + cursor, so any
--- edit or move rebuilds; entries are dropped on buffer wipe/delete via `M.forget` (wired from
--- `init.register`). Only successful results are cached — the transient no-parser state (the parser
--- can be installed on demand without bumping `changedtick`) always re-probes.
---@type table<integer, { tick: integer, line: integer, col: integer, chain: LvimBreadcrumbsEntry[] }>
local cache = {}

--- Drop a buffer's memoized chain (on BufDelete / BufWipeout).
---@param bufnr integer
---@return nil
function M.forget(bufnr)
    cache[bufnr] = nil
end

--- Exact node-type → SymbolKind name, for grammar names the patterns below can't catch.
---@type table<string, string>
local EXACT = {
    mod_item = "Module", -- rust
    impl_item = "Class", -- rust: the impl block reads as its type's scope
    trait_item = "Interface", -- rust
    pair = "Field", -- json / yaml key-value entries
}

--- Substring patterns → SymbolKind name, checked in order (specific before generic: "method"
--- must win over "function" for `method_definition`-style names).
---@type { [1]: string, [2]: string }[]
local PATTERNS = {
    { "method", "Method" },
    { "constructor", "Constructor" },
    { "function", "Function" },
    { "interface", "Interface" },
    { "class", "Class" },
    { "struct", "Struct" },
    { "enum", "Enum" },
    { "namespace", "Namespace" },
    { "module", "Module" },
    { "property", "Property" },
    { "field", "Field" },
}

--- SymbolKind name for a node type, or nil when the node is not structural.
---@param node_type string
---@return string|nil
local function classify(node_type)
    local exact = EXACT[node_type]
    if exact then
        return exact
    end
    for _, p in ipairs(PATTERNS) do
        if node_type:find(p[1], 1, true) then
            return p[2]
        end
    end
    return nil
end

--- The display name of a structural node: its `name` field, else a direct identifier-ish
--- child. First line only, capped — a breadcrumb segment, not a code dump.
---@param node TSNode
---@param bufnr integer
---@return string|nil
local function node_name(node, bufnr)
    local named = node:field("name")[1]
    if not named then
        for child in node:iter_children() do
            local t = child:type()
            if child:named() and (t:find("identifier", 1, true) or t == "name" or t:find("declarator", 1, true)) then
                named = child
                break
            end
        end
    end
    if not named then
        return nil
    end
    local ok, text = pcall(vim.treesitter.get_node_text, named, bufnr)
    if not ok or type(text) ~= "string" or text == "" then
        return nil
    end
    text = text:match("^[^\n]*") or text
    if #text > 60 then
        text = text:sub(1, 57) .. "…"
    end
    return text
end

--- Whether the fallback CAN run here: the buffer has a treesitter parser.
---@param bufnr integer
---@return boolean
function M.available(bufnr)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
    return ok and parser ~= nil
end

--- The structural named-node ancestor chain (root → leaf) at (line, col) — 0-based line,
--- byte col. nil when the buffer has no parser.
---@param bufnr integer
---@param line integer
---@param col integer
---@return LvimBreadcrumbsEntry[]|nil
function M.chain(bufnr, line, col)
    local tick = vim.b[bufnr].changedtick
    local hit = cache[bufnr]
    if hit and hit.tick == tick and hit.line == line and hit.col == col then
        return hit.chain
    end
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
    if not ok or not parser then
        return nil
    end
    local trees = parser:parse() -- incremental: a no-op when the tree is current
    local root = trees and trees[1] and trees[1]:root()
    if not root then
        return nil
    end
    local node = root:named_descendant_for_range(line, col, line, col)
    -- collect leaf → root, then reverse: consumers want the path FROM the document root
    local up = {} ---@type LvimBreadcrumbsEntry[]
    while node do
        local kind_name = classify(node:type())
        if kind_name then
            local name = node_name(node, bufnr)
            if name then
                local srow, scol, erow, ecol = node:range()
                local kind = kinds.number(kind_name)
                local icon, hl = kinds.icon(kind)
                up[#up + 1] = {
                    name = name,
                    kind = kind,
                    type = kind_name,
                    icon = icon,
                    hl = hl,
                    scope_range = {
                        start = { line = srow, character = scol },
                        ["end"] = { line = erow, character = ecol },
                    },
                    jump = { line = srow, character = scol }, -- byte column (no `encoding`)
                }
            end
        end
        node = node:parent()
    end
    local chain = {} ---@type LvimBreadcrumbsEntry[]
    for i = #up, 1, -1 do
        chain[#chain + 1] = up[i]
    end
    -- Cache only this success path: an empty chain is a valid "no structural ancestors" result and
    -- is worth memoizing; the earlier nil returns are transient (parser not ready) and are not.
    cache[bufnr] = { tick = tick, line = line, col = col, chain = chain }
    return chain
end

return M

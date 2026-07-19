-- lvim-breadcrumbs.locate: cursor → ancestor chain over the CACHED symbol tree. This is the
-- hot path (it runs on every CursorMoved), so it never talks to the server: per tree level a
-- BINARY SEARCH over the children (sorted by start — lsp.lua's invariant) finds the one
-- candidate that can contain the cursor, checks containment, and descends. Well-nested
-- siblings are disjoint, so the last-started candidate is the only possible container.
--
-- The single cursor position is converted INTO the server's position encoding here (one
-- str_utfindex per move) instead of converting every symbol range out of it per refresh —
-- the cheap side of the encoding seam.
--
-- Also home of `data()` — the public get_data() body: the cached LSP chain when the buffer
-- is attached, else the treesitter fallback chain (ts.lua), both in the same entry shape.
--
---@module "lvim-breadcrumbs.locate"

local config = require("lvim-breadcrumbs.config")
local kinds = require("lvim-breadcrumbs.kinds")
local ts = require("lvim-breadcrumbs.ts")

local api = vim.api

local M = {}

---@class LvimBreadcrumbsEntry
---@field name        string   symbol name (raw — renderers escape it)
---@field kind        integer  LSP SymbolKind number
---@field type        string   SymbolKind NAME ("Function", …) — what kind-keyed consumers switch on
---@field icon        string   the kind glyph (shared lvim-lsp set)
---@field hl          string   `LvimBreadcrumbs<KindName>` highlight group
---@field scope_range { start: { line: integer, character: integer }, ["end"]: { line: integer, character: integer } }
---@field jump        { line: integer, character: integer, encoding?: string }  selection start; `encoding` set = an LSP position (character in that encoding), unset = a byte column (treesitter)

--- Cursor (0-based line, byte col) of the window showing `bufnr` — the current window when
--- it shows the buffer, else the first window that does. nil = the buffer is not displayed.
---@param bufnr integer
---@return integer|nil line, integer|nil col
local function cursor_of(bufnr)
    local win = api.nvim_get_current_win()
    if api.nvim_win_get_buf(win) ~= bufnr then
        win = vim.fn.bufwinid(bufnr)
        if win == -1 then
            return nil, nil
        end
    end
    local pos = api.nvim_win_get_cursor(win)
    return pos[1] - 1, pos[2]
end

--- Position `a` before-or-at `b` (line-major, then character).
---@param a { line: integer, character: integer }
---@param b { line: integer, character: integer }
---@return boolean
local function pos_le(a, b)
    if a.line ~= b.line then
        return a.line < b.line
    end
    return a.character <= b.character
end

--- Position `a` STRICTLY before `b` (line-major, then character).
---@param a { line: integer, character: integer }
---@param b { line: integer, character: integer }
---@return boolean
local function pos_lt(a, b)
    if a.line ~= b.line then
        return a.line < b.line
    end
    return a.character < b.character
end

--- The LAST node (index) in `nodes` (sorted by start) whose start <= `pos`, or nil.
---@param nodes LvimBreadcrumbsNode[]
---@param pos { line: integer, character: integer }
---@return integer|nil
local function last_started(nodes, pos)
    local lo, hi, found = 1, #nodes, nil
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if pos_le(nodes[mid].start, pos) then
            found = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return found
end

--- One public entry from a cached node (+ the client encoding for the jump target).
---@param node LvimBreadcrumbsNode
---@param encoding string
---@return LvimBreadcrumbsEntry
local function to_entry(node, encoding)
    local icon, hl = kinds.icon(node.kind)
    return {
        name = node.name,
        kind = node.kind,
        type = kinds.name(node.kind),
        icon = icon,
        hl = hl,
        scope_range = { start = node.start, ["end"] = node.finish },
        jump = { line = node.sel.line, character = node.sel.character, encoding = encoding },
    }
end

--- Descend the sorted tree at `pos`, collecting the root→leaf ancestor chain.
---@param tree LvimBreadcrumbsNode[]
---@param pos { line: integer, character: integer }
---@param encoding string
---@return LvimBreadcrumbsEntry[]
local function descend(tree, pos, encoding)
    local chain, level = {}, tree
    while level and #level > 0 do
        local i = last_started(level, pos)
        local node = i and level[i]
        if not node or not pos_lt(pos, node.finish) then
            -- finish is the LSP range end (EXCLUSIVE): the cursor sitting exactly on it is already
            -- past this scope, so require a strict less-than — not pos_le, which would keep the symbol
            -- highlighted for one column too long.
            break -- the only possible container at this level does not reach the cursor
        end
        chain[#chain + 1] = to_entry(node, encoding)
        level = node.children
    end
    return chain
end

--- Recompute + cache the cursor chain of an ATTACHED buffer (CursorMoved + after each
--- refresh). Pure cache work: one cursor-encoding conversion, then binary-search descent.
---@param bufnr integer
---@return nil
function M.update(bufnr)
    -- inline require: lsp.lua requires locate (the response handler re-locates), so this
    -- direction must resolve lazily — the canonical circular-require exception.
    local lsp = require("lvim-breadcrumbs.lsp")
    local st = lsp.buffers[bufnr]
    if not st or not st.tree then
        return
    end
    local line, col = cursor_of(bufnr)
    if not line or not col then
        return -- not displayed; keep the last chain
    end
    local text = api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ""
    -- byte col → the server's encoding; clamp first (the cursor can sit past EOL in insert)
    local ok, character = pcall(vim.str_utfindex, text, st.encoding, math.min(col, #text), false)
    st.chain = descend(st.tree, { line = line, character = ok and character or col }, st.encoding)
end

--- The public get_data() body: the ancestor chain at the buffer's cursor — the cached LSP
--- chain when attached (with a tree), else the treesitter fallback (config.ts_fallback).
---@param bufnr? integer
---@return LvimBreadcrumbsEntry[]|nil  nil = no source can produce a chain for this buffer
function M.data(bufnr)
    if bufnr == nil or bufnr == 0 then
        bufnr = api.nvim_get_current_buf()
    end
    local lsp = require("lvim-breadcrumbs.lsp") -- inline: same circular seam as update()
    local st = lsp.buffers[bufnr]
    if st and st.tree then
        return st.chain
    end
    if config.ts_fallback then
        local line, col = cursor_of(bufnr)
        if line and col then
            return ts.chain(bufnr, line, col)
        end
    end
    return nil
end

return M

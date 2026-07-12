-- lvim-breadcrumbs.render: chain → rendered breadcrumb string. One builder for every
-- consumer: get_location(), the lvim-hud chrome segment and the self-rendered winbar all call
-- location() — a statusline-format string (`%#LvimBreadcrumbs<Kind>#` per segment, names
-- %%-escaped) with ` ➤ ` separators (the canonical pointer), the optional `icon filename`
-- prefix (lvim-icons) and the depth-limit elision (`…` for the dropped HEAD — the deepest
-- segments are the informative ones). `highlight = false` strips it down to plain text.
--
-- Clicks: with `clicks = true` every symbol segment becomes a `%N@…@` region whose minwid is
-- its CHAIN INDEX; on_click() resolves the clicked WINDOW from the mouse position, re-reads
-- that buffer's chain and jumps to the segment's selection start — so the ids need no global
-- registry and never go stale (the chain is looked up at click time, not render time).
--
---@module "lvim-breadcrumbs.render"

local config = require("lvim-breadcrumbs.config")
local locate = require("lvim-breadcrumbs.locate")

local api = vim.api

local M = {}

--- Escape statusline-active characters in a symbol name (and flatten newlines).
---@param name string
---@return string
local function escape(name)
    return (name:gsub("%%", "%%%%"):gsub("%s*\n%s*", " "))
end

--- Wrap `text` in a highlight group (no-op when highlighting is off).
---@param group string
---@param text string
---@param highlight boolean
---@return string
local function paint(group, text, highlight)
    if not highlight then
        return text
    end
    return ("%%#%s#%s%%*"):format(group, text)
end

--- The leading `icon filename` segment, or nil for an unnamed buffer. The icon + its colour
--- group come from lvim-icons (soft dependency — no icon without it, the name still shows).
---@param bufnr integer
---@param highlight boolean
---@return string|nil
local function file_segment(bufnr, highlight)
    local name = api.nvim_buf_get_name(bufnr)
    if name == "" then
        return nil
    end
    local tail = vim.fn.fnamemodify(name, ":t")
    local out = paint("LvimBreadcrumbsFile", escape(tail), highlight)
    local ok, icons = pcall(require, "lvim-icons")
    if ok then
        local r = icons.get(name, { filetype = vim.bo[bufnr].filetype })
        if r and r.glyph and r.glyph ~= "" then
            out = paint(r.hl or "LvimBreadcrumbsFile", r.glyph, highlight) .. " " .. out
        end
    end
    return out
end

---@class LvimBreadcrumbsRenderOpts
---@field bufnr?                 integer  buffer to render (default: current)
---@field highlight?             boolean  embed `%#…#` groups (default true)
---@field clicks?                boolean  wrap symbol segments in `%N@…@` jump regions (default false — winbar renderers only)
---@field file_prefix?           boolean  override config.file_prefix for this call
---@field depth_limit?           integer  override config.depth_limit
---@field depth_limit_indicator? string   override config.depth_limit_indicator

--- Render the breadcrumb trail for a buffer. Empty string when no chain is available (so bar
--- consumers can concatenate it unconditionally).
---@param opts? LvimBreadcrumbsRenderOpts
---@return string
function M.location(opts)
    opts = opts or {}
    local bufnr = opts.bufnr
    if bufnr == nil or bufnr == 0 then
        bufnr = api.nvim_get_current_buf()
    end
    local highlight = opts.highlight ~= false
    local chain = locate.data(bufnr) or {}

    local segs = {} ---@type string[]
    local file_prefix = opts.file_prefix
    if file_prefix == nil then
        file_prefix = config.file_prefix
    end
    if file_prefix then
        segs[#segs + 1] = file_segment(bufnr, highlight)
    end

    -- depth limit: keep the DEEPEST n segments, elide the head behind the indicator
    local depth_limit = opts.depth_limit or config.depth_limit or 0
    local first = 1
    if depth_limit > 0 and #chain > depth_limit then
        first = #chain - depth_limit + 1
        segs[#segs + 1] =
            paint("LvimBreadcrumbsSeparator", opts.depth_limit_indicator or config.depth_limit_indicator, highlight)
    end

    for i = first, #chain do
        local entry = chain[i]
        local text = entry.icon ~= "" and (entry.icon .. " " .. escape(entry.name)) or escape(entry.name)
        local seg = paint(entry.hl, text, highlight)
        if opts.clicks then
            seg = ("%%%d@v:lua.require'lvim-breadcrumbs.render'.on_click@%s%%X"):format(i, seg)
        end
        segs[#segs + 1] = seg
    end

    return table.concat(segs, paint("LvimBreadcrumbsSeparator", " ➤ ", highlight))
end

--- Mouse dispatch for the `%N@…@` regions: resolve the clicked WINDOW from the mouse, re-read
--- its buffer's chain and jump to segment `idx`'s selection start (LSP jump columns are
--- converted from the client encoding to bytes here, at click time).
---@param idx integer  the minwid: the clicked segment's chain index
---@return nil
function M.on_click(idx)
    local mouse = vim.fn.getmousepos()
    local win = mouse.winid
    if win == 0 or not api.nvim_win_is_valid(win) then
        return
    end
    local bufnr = api.nvim_win_get_buf(win)
    local chain = locate.data(bufnr)
    local entry = chain and chain[idx]
    if not entry then
        return
    end
    local line, character = entry.jump.line, entry.jump.character
    local col = character
    if entry.jump.encoding then
        local text = api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ""
        local ok, byte = pcall(vim.str_byteindex, text, entry.jump.encoding, character, false)
        col = ok and byte or math.min(character, #text)
    end
    api.nvim_set_current_win(win)
    api.nvim_win_set_cursor(win, { line + 1, col })
end

return M

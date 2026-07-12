-- lvim-breadcrumbs.winbar: the OPT-IN self-rendered winbar (config.attach_winbar). For every
-- window showing an attached buffer it sets a window-local `%{%…%}` winbar that re-evaluates
-- on Neovim's own redraws (cursor moves repaint it for free — no autocmd-driven redraw loop).
-- NO-CLOBBER: a window whose winbar is already owned by something else (the lvim-hud chrome
-- winbar, a plugin panel's keymap bar, …) is left alone — this renderer only ever writes over
-- an EMPTY winbar or its own, and only ever clears its own. With lvim-hud the recommended
-- integration is the ready-made chrome segment (init.hud_segment()) instead of this renderer.
--
---@module "lvim-breadcrumbs.winbar"

local config = require("lvim-breadcrumbs.config")
local render = require("lvim-breadcrumbs.render")

local api = vim.api

local M = {}

--- The window-local winbar expression — `%{%…%}` so the returned string's own `%#…#` groups
--- and `%@…@` click regions are re-parsed as statusline items.
---@type string
local EXPR = "%{%v:lua.require'lvim-breadcrumbs.winbar'.render()%}"

--- Windows we may write: normal (non-floating) windows whose winbar is empty or already ours.
---@param win integer
---@return boolean
local function claimable(win)
    if api.nvim_win_get_config(win).relative ~= "" then
        return false
    end
    local current = vim.wo[win].winbar
    return current == "" or current == EXPR
end

--- Set the winbar on every claimable window showing `bufnr` (called after attach and on
--- BufWinEnter of attached buffers).
---@param bufnr integer
---@return nil
function M.apply(bufnr)
    if vim.tbl_contains(config.exclude_ft, vim.bo[bufnr].filetype) then
        return
    end
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
        if claimable(win) then
            vim.wo[win][0].winbar = EXPR
        end
    end
end

--- Clear OUR winbar (only ours) from every window showing `bufnr` (called on detach).
---@param bufnr integer
---@return nil
function M.clear(bufnr)
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
        if vim.wo[win].winbar == EXPR then
            vim.wo[win][0].winbar = ""
        end
    end
end

--- The `%{%…%}` body: the clickable breadcrumb trail of the DRAWN window's buffer (the
--- statusline evaluator makes it current for the duration). A leading space as air.
---@return string
function M.render()
    local bufnr = api.nvim_get_current_buf()
    if vim.tbl_contains(config.exclude_ft, vim.bo[bufnr].filetype) then
        return ""
    end
    local trail = render.location({ bufnr = bufnr, clicks = true })
    return trail ~= "" and (" " .. trail) or ""
end

return M

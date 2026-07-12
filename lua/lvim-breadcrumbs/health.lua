-- lvim-breadcrumbs: :checkhealth lvim-breadcrumbs.
-- Diagnoses what makes an empty breadcrumb trail look like a bug: no documentSymbol client
-- for the current buffer (and whether the ts fallback covers it), the kind-icon SOURCE
-- (lvim-lsp's shared table vs the bundled copy — with a DRIFT warning when the bundled copy
-- no longer matches lvim-lsp's, so the two get resynced), the soft dependencies (lvim-icons
-- for the file prefix), and the winbar mode (hud segment vs attach_winbar). Read-only
-- reporting — never mutates config or state.
--
---@module "lvim-breadcrumbs.health"

local config = require("lvim-breadcrumbs.config")
local kinds = require("lvim-breadcrumbs.kinds")
local lsp = require("lvim-breadcrumbs.lsp")
local ts = require("lvim-breadcrumbs.ts")

local M = {}

--- Report where the kind glyphs come from, and warn when the bundled copy drifted from
--- lvim-lsp's live table (they must stay byte-identical so outline ⇄ breadcrumbs match).
---@param health table  the vim.health reporter
---@return nil
local function check_icons(health)
    local shared = kinds.shared_icons()
    if not shared then
        health.ok("kind icons: bundled copy (lvim-lsp not installed)")
        return
    end
    local drift = {}
    for name, glyph in pairs(kinds.BUNDLED_ICONS) do
        if shared[name] ~= nil and shared[name] ~= glyph then
            drift[#drift + 1] = name
        end
    end
    if #drift == 0 then
        health.ok("kind icons: shared with lvim-lsp (outline set)")
    else
        table.sort(drift)
        health.warn(
            "kind icons differ from the bundled copy for: "
                .. table.concat(drift, ", ")
                .. " — lvim-lsp's table wins at runtime; resync the bundled copy if the outline defaults changed"
        )
    end
end

--- Run the health report.
---@return nil
function M.check()
    local health = vim.health
    health.start("lvim-breadcrumbs")

    if vim.fn.has("nvim-0.11") == 1 then
        health.ok("Neovim >= 0.11")
    else
        health.error("Neovim >= 0.11 is required (client:request/cancel_request, vim.str_utfindex signature)")
    end

    local ok_utils = pcall(require, "lvim-utils.utils")
    local ok_hl, uhl = pcall(require, "lvim-utils.highlight")
    if ok_utils and ok_hl and type(uhl.bind) == "function" then
        health.ok("lvim-utils found (palette theming + merge)")
    else
        health.error("lvim-utils is required (highlight factory + config merge) — install lvim-tech/lvim-utils")
    end

    check_icons(health)

    if pcall(require, "lvim-icons") then
        health.ok("lvim-icons found (file_prefix icon)")
    elseif config.file_prefix then
        health.warn("lvim-icons not found — file_prefix shows the bare filename (no icon)")
    else
        health.info("lvim-icons not found (file_prefix is off anyway)")
    end

    -- attach + source coverage for the CURRENT buffer, so "why is my trail empty" is
    -- answerable from the report
    local attached = vim.tbl_count(lsp.buffers)
    health.info(("attached buffers: %d"):format(attached))
    local bufnr = vim.api.nvim_get_current_buf()
    if lsp.has_tree(bufnr) then
        health.ok("current buffer: LSP symbol tree cached")
    elseif lsp.buffers[bufnr] then
        health.info("current buffer: attached, first documentSymbol response pending")
    elseif config.ts_fallback and ts.available(bufnr) then
        health.ok("current buffer: no documentSymbol client — treesitter fallback covers it")
    else
        health.warn("current buffer: no documentSymbol client and no treesitter parser — no trail here")
    end

    if config.attach_winbar then
        health.info(
            "attach_winbar = true — the self-rendered winbar claims EMPTY winbars only; with the lvim-hud "
                .. "chrome winbar use hud_segment() in chrome.winbar.segments instead"
        )
    else
        health.info("attach_winbar = false — consume get_data()/get_location() (e.g. hud_segment())")
    end
end

return M

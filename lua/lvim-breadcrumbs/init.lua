-- lvim-breadcrumbs: "where am I in the code" — the symbol path from the document root to the
-- cursor (`module ➤ class ➤ method`), fed by LSP textDocument/documentSymbol with a
-- treesitter fallback, exposed as DATA for statusline/winbar consumers. This module is the
-- public entry point and the whole consumer contract:
--
--   attach(client, bufnr)   -- wire a documentSymbol client to a buffer (idempotent; also
--                           -- done automatically on LspAttach once setup() ran)
--   is_available(bufnr)     -- can a chain be produced here?
--   get_data(bufnr)         -- { { name, kind, type, icon, hl, scope_range, jump } } — the
--                           -- STABLE seam every consumer builds on
--   get_location(opts)      -- the rendered `➤`-separated trail (statusline-format string)
--   hud_segment(opts)       -- a ready-made lvim-hud chrome winbar SEGMENT — drop it into
--                           -- chrome.winbar.segments and the trail renders inside the hud
--                           -- winbar (per-kind colours + click-to-jump). The recommended
--                           -- integration with lvim-hud; `attach_winbar` is the standalone
--                           -- self-rendered alternative and never overwrites a hud winbar.
--
-- Data discipline: one request per EDIT (debounced, in-flight cancelled), never per cursor
-- move — cursor moves only binary-search the cached tree (lsp.lua / locate.lua).
--
---@module "lvim-breadcrumbs"

local config = require("lvim-breadcrumbs.config")
local lsp = require("lvim-breadcrumbs.lsp")
local ts = require("lvim-breadcrumbs.ts")
local locate = require("lvim-breadcrumbs.locate")
local render = require("lvim-breadcrumbs.render")
local winbar = require("lvim-breadcrumbs.winbar")
local merge = require("lvim-utils.utils").merge

local api = vim.api
local ms = vim.lsp.protocol.Methods

local M = {}

---@type boolean  one-time registration (highlight bind, autocmds) done
local registered = false

--- `bufnr or 0` → a concrete buffer number.
---@param bufnr? integer
---@return integer
local function resolve_buf(bufnr)
    if bufnr == nil or bufnr == 0 then
        return api.nvim_get_current_buf()
    end
    return bufnr
end

--- The buffer's filetype is on the exclusion list.
---@param bufnr integer
---@return boolean
local function excluded(bufnr)
    return vim.tbl_contains(config.exclude_ft, vim.bo[bufnr].filetype)
end

--- Attach `client`'s symbol tree to `bufnr` — the navic-contract seam for a manual
--- on_attach wiring. Idempotent; capability-checked (a client without documentSymbol is
--- refused). setup()'s LspAttach autocmd calls this automatically, so with setup() in place
--- no per-server wiring is needed.
---@param client vim.lsp.Client
---@param bufnr? integer
---@return boolean attached
function M.attach(client, bufnr)
    bufnr = resolve_buf(bufnr)
    if excluded(bufnr) then
        return false
    end
    local ok = lsp.attach(client, bufnr)
    if ok and config.attach_winbar then
        winbar.apply(bufnr)
    end
    return ok
end

--- A chain can be produced for `bufnr`: an attached client's tree is cached, or the
--- treesitter fallback has a parser (config.ts_fallback).
---@param bufnr? integer
---@return boolean
function M.is_available(bufnr)
    bufnr = resolve_buf(bufnr)
    if excluded(bufnr) then
        return false
    end
    return lsp.has_tree(bufnr) or (config.ts_fallback and ts.available(bufnr))
end

--- The ancestor chain at the buffer's cursor — the STABLE data seam (see
--- LvimBreadcrumbsEntry in locate.lua). nil when no source can produce one.
---@param bufnr? integer
---@return LvimBreadcrumbsEntry[]|nil
function M.get_data(bufnr)
    bufnr = resolve_buf(bufnr)
    if excluded(bufnr) then
        return nil
    end
    return locate.data(bufnr)
end

--- The rendered breadcrumb trail (statusline-format string, `➤` separators, per-kind
--- highlight groups; see LvimBreadcrumbsRenderOpts in render.lua).
---@param opts? LvimBreadcrumbsRenderOpts
---@return string
function M.get_location(opts)
    return render.location(opts)
end

--- A ready-made lvim-hud chrome winbar SEGMENT: the clickable breadcrumb trail of the drawn
--- window's buffer, shown in ACTIVE windows. Drop it into the chrome winbar definition —
---
---   segments[#segments + 1] = require("lvim-breadcrumbs").hud_segment()
---
--- The spec is volatile (no `events`) — the winbar engine re-renders it per redraw, so the
--- trail follows the cursor with no extra autocmds. `file_prefix` defaults to FALSE here
--- (unlike get_location): a chrome winbar already carries its own file segment, so the
--- breadcrumb segment ships only the symbol trail — pass `file_prefix = true` to override.
---@param opts? { name?: string, inactive?: boolean, file_prefix?: boolean }  segment name override; `inactive = true` renders in inactive windows too
---@return table  an lvim-hud LvimChromeSegment spec
function M.hud_segment(opts)
    opts = opts or {}
    return {
        name = opts.name or "wb_breadcrumbs",
        when = function(ctx)
            if not (opts.inactive or ctx.active) then
                return false
            end
            return M.is_available(ctx.buf)
        end,
        content = function(ctx)
            return render.location({ bufnr = ctx.buf, clicks = true, file_prefix = opts.file_prefix or false })
        end,
    }
end

--- Configure lvim-breadcrumbs: merge user opts into the live config, self-theme the
--- `LvimBreadcrumbs*` groups from the lvim-utils palette, and install the lifecycle
--- autocmds (attach on LspAttach, hand over / detach on LspDetach). Clients already running
--- are swept, so a late setup() still attaches everything.
---@param opts? LvimBreadcrumbsConfig
---@return nil
function M.setup(opts)
    merge(config, opts or {})
    if registered then
        return
    end
    registered = true

    require("lvim-utils.highlight").bind(require("lvim-breadcrumbs.highlights").build)

    local group = api.nvim_create_augroup("LvimBreadcrumbs", { clear = true })
    api.nvim_create_autocmd("LspAttach", {
        group = group,
        desc = "lvim-breadcrumbs: attach documentSymbol clients",
        callback = function(args)
            local client = vim.lsp.get_client_by_id(args.data.client_id)
            if client then
                M.attach(client, args.buf)
            end
        end,
    })
    api.nvim_create_autocmd("LspDetach", {
        group = group,
        desc = "lvim-breadcrumbs: hand the buffer to another capable client, or detach",
        callback = function(args)
            local st = lsp.buffers[args.buf]
            if not st or st.client_id ~= args.data.client_id then
                return
            end
            -- the source client is leaving: another still-attached documentSymbol client
            -- takes over; with none left the buffer state is dropped (the ts fallback and
            -- the winbar's no-chain empty string take it from there).
            for _, client in ipairs(vim.lsp.get_clients({ bufnr = args.buf })) do
                if client.id ~= args.data.client_id and lsp.attach(client, args.buf) then
                    return
                end
            end
            lsp.detach(args.buf)
            winbar.clear(args.buf)
        end,
    })
    api.nvim_create_autocmd("BufWinEnter", {
        group = group,
        desc = "lvim-breadcrumbs: claim the winbar of newly shown attached buffers",
        callback = function(args)
            if config.attach_winbar and lsp.buffers[args.buf] then
                winbar.apply(args.buf)
            end
        end,
    })

    -- late setup: clients that attached before us are swept once
    for _, client in ipairs(vim.lsp.get_clients()) do
        for bufnr in pairs(client.attached_buffers or {}) do
            if api.nvim_buf_is_valid(bufnr) then
                M.attach(client, bufnr)
            end
        end
    end
end

return M

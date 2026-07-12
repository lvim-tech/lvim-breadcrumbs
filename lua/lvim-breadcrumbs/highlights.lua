-- lvim-breadcrumbs.highlights: one fg-only group per SymbolKind — `LvimBreadcrumbs<KindName>`
-- — coloured with the SAME accent-per-kind mapping lvim-lsp's outline uses (kinds.ACCENTS), so
-- the breadcrumb trail and the outline read as one legend. Plus the chrome groups: the ➤
-- separator (the fg dimmed 0.6 toward bg) and the file-prefix name (blue). All fg-only, no
-- background — the segments sit on whatever bar hosts them (the lvim-hud chrome winbar, the
-- self-rendered winbar, a statusline). build() reads the LIVE palette on every call; init.lua
-- binds it via lvim-utils.highlight.bind, so the groups re-derive on ColorScheme/palette sync.
--
---@module "lvim-breadcrumbs.highlights"

local c = require("lvim-utils.colors")
local hl = require("lvim-utils.highlight")
local kinds = require("lvim-breadcrumbs.kinds")

local M = {}

--- The breadcrumb groups from the live palette.
---@return table<string, table>
function M.build()
    local groups = {
        -- ➤ between segments (and the depth-limit "…"): the fg kept at 60% toward bg, so the
        -- pointers recede behind the coloured segments.
        LvimBreadcrumbsSeparator = { fg = hl.blend(c.fg, c.bg, 0.6) },
        -- the leading filename of `file_prefix` (its icon wears the lvim-icons group instead)
        LvimBreadcrumbsFile = { fg = c.blue },
    }
    for name, accent in pairs(kinds.ACCENTS) do
        groups["LvimBreadcrumbs" .. name] = { fg = c[accent] or c.fg }
    end
    return groups
end

return M

-- lvim-breadcrumbs.kinds: SymbolKind → glyph + highlight group + palette accent.
-- The glyph set is the SAME one lvim-lsp's outline uses, sourced from ONE place: when
-- lvim-lsp is installed its live table (`lvim-lsp.state` → config.outline.icons) is read —
-- so a user override there restyles the breadcrumbs too — and the bundled copy below is the
-- standalone fallback (kept byte-identical; :checkhealth warns on drift). The accent-per-kind
-- mapping mirrors the outline's KIND_HL grouping 1:1, so outline ⇄ breadcrumbs read as one
-- legend.
--
---@module "lvim-breadcrumbs.kinds"

local SymbolKind = vim.lsp.protocol.SymbolKind

local M = {}

--- Bundled SymbolKind → glyph table — byte-identical to lvim-lsp's outline defaults
--- (lvim-lsp/lua/lvim-lsp/config/ui.lua). Used when lvim-lsp is absent; health compares the
--- two when both exist.
---@type table<string, string>
M.BUNDLED_ICONS = {
    File = "󰈙",
    Module = "󰏗",
    Namespace = "󰦮",
    Package = "󰏖",
    Class = "󰠱",
    Method = "󰆧",
    Property = "󰜢",
    Field = "󰜢",
    Constructor = "󰙴",
    Enum = "󰕘",
    Interface = "󰜰",
    Function = "󰊕",
    Variable = "󰀫",
    Constant = "󰏿",
    String = "󰉿",
    Number = "󰎠",
    Boolean = "󰐾",
    Array = "󰅪",
    Object = "󰅩",
    Key = "󰌋",
    Null = "󰟢",
    EnumMember = "󰦨",
    Struct = "󰙅",
    Event = "󰉁",
    Operator = "󰆕",
    TypeParameter = "󰫣",
}

--- SymbolKind name → lvim-utils palette key — the outline's accent grouping 1:1
--- (Func=blue, Type=yellow, Iface=orange, Var=cyan, Field=teal, Const=red, Module=purple,
--- Value=green, Object=magenta; Event/Operator and anything unmapped read as `comment`).
---@type table<string, string>
M.ACCENTS = {
    Function = "blue",
    Method = "blue",
    Constructor = "blue",
    Class = "yellow",
    Struct = "yellow",
    Interface = "orange",
    Enum = "orange",
    EnumMember = "orange",
    TypeParameter = "orange",
    Variable = "cyan",
    Field = "teal",
    Property = "teal",
    Constant = "red",
    Module = "purple",
    Namespace = "purple",
    Package = "purple",
    File = "purple",
    String = "green",
    Number = "green",
    Boolean = "green",
    Array = "magenta",
    Object = "magenta",
    Key = "magenta",
    Null = "magenta",
    Event = "comment",
    Operator = "comment",
}

--- lvim-lsp's LIVE outline icon table when the plugin is installed, else nil. Read through
--- `lvim-lsp.state` (defaults are populated at require time, before any setup()), so a user
--- override of the outline icons flows into the breadcrumbs automatically.
---@return table<string, string>|nil
function M.shared_icons()
    local ok, lsp_state = pcall(require, "lvim-lsp.state")
    if not ok or type(lsp_state) ~= "table" then
        return nil
    end
    local icons = vim.tbl_get(lsp_state, "config", "outline", "icons")
    return type(icons) == "table" and icons or nil
end

--- The effective SymbolKind-name → glyph table (shared lvim-lsp source, else bundled).
---@return table<string, string>
function M.icons()
    return M.shared_icons() or M.BUNDLED_ICONS
end

--- The canonical kind NAME for an LSP SymbolKind number ("Variable" for unknown numbers,
--- matching the outline's fallback).
---@param kind integer
---@return string
function M.name(kind)
    local name = SymbolKind[kind]
    return type(name) == "string" and name or "Variable"
end

--- Glyph + highlight group for a SymbolKind number. The group is the factory-built
--- `LvimBreadcrumbs<KindName>` (highlights.lua defines one per kind).
---@param kind integer
---@return string icon, string hl
function M.icon(kind)
    local name = M.name(kind)
    return M.icons()[name] or "", "LvimBreadcrumbs" .. name
end

--- The SymbolKind NUMBER for a kind name (used by the treesitter fallback to emit the same
--- numeric `kind` the LSP path does). Falls back to Variable (13).
---@param name string
---@return integer
function M.number(name)
    local n = SymbolKind[name]
    return type(n) == "number" and n or SymbolKind.Variable
end

return M

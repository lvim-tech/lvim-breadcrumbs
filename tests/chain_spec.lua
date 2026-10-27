-- Which symbol the cursor is inside, and how that chain reads.
--
-- locate.lua is the CursorMoved hot path: per tree level a binary search over the children
-- finds the one sibling that can contain the cursor, checks containment and descends. Two
-- things in that sentence are easy to get wrong and invisible when you do. The range end is
-- EXCLUSIVE (LSP semantics), so the cursor sitting exactly on it is already past the scope --
-- get that wrong and a symbol stays highlighted for one column too long. And the cursor column
-- is converted INTO the server's encoding, which is the whole reason a Cyrillic line does not
-- shift the chain.

local locate = require("lvim-breadcrumbs.locate")
local lsp = require("lvim-breadcrumbs.lsp")
local render = require("lvim-breadcrumbs.render")
local config = require("lvim-breadcrumbs.config")

--- A node of the cached symbol tree.
---@param name string
---@param kind integer
---@param s integer[]  { line, character } scope start
---@param e integer[]  { line, character } scope end (EXCLUSIVE)
---@param children? table[]
---@return table
local function node(name, kind, s, e, children)
    return {
        name = name,
        kind = kind,
        start = { line = s[1], character = s[2] },
        finish = { line = e[1], character = e[2] },
        sel = { line = s[1], character = s[2] },
        children = children or {},
    }
end

--- A buffer holding `lines` with a pretend-attached state carrying `tree`, and the cursor at
--- (row1, col0). Returns the buffer and the chain locate computes.
---@param lines string[]
---@param tree table[]
---@param row integer  1-based
---@param col integer  0-based BYTE column
---@param encoding? string
---@return integer buf
---@return table[] chain
local function chain_at(lines, tree, row, col, encoding)
    vim.cmd("enew!")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(0, { row, col })
    lsp.buffers[buf] = { tree = tree, encoding = encoding or "utf-16", chain = {} }
    locate.update(buf)
    return buf, locate.data(buf) or {}
end

--- Just the names of a chain.
---@param chain table[]
---@return string[]
local function names(chain)
    return vim.tbl_map(function(e)
        return e.name
    end, chain)
end

local FUNCTION, CLASS, METHOD = 12, 5, 6

--- Eight lines, each wide enough for any column these cases name. The cursor column is CLAMPED
--- to the line's length before it is converted, so a one-character line silently moves a cursor
--- that was meant to sit at column 4 -- which is how the first version of this spec "failed".
---@return string[]
local function wide_lines()
    local out = {}
    for i = 1, 8 do
        out[i] = ("line %d padded out"):format(i)
    end
    return out
end

describe("lvim-breadcrumbs: which symbol contains the cursor")

it("the chain runs root to leaf", function()
    local tree = {
        node("Outer", CLASS, { 0, 0 }, { 10, 0 }, {
            node("inner", METHOD, { 2, 2 }, { 5, 0 }, {
                node("nested", FUNCTION, { 3, 4 }, { 4, 0 }),
            }),
        }),
    }
    local _, chain = chain_at(wide_lines(), tree, 4, 4)
    eq({ "Outer", "inner", "nested" }, names(chain))
end)

it("the cursor above everything has no chain", function()
    local tree = { node("Later", FUNCTION, { 5, 0 }, { 9, 0 }) }
    local _, chain = chain_at(wide_lines(), tree, 1, 0)
    eq({}, names(chain))
end)

it("the cursor past a symbol's end has no chain", function()
    local tree = { node("Early", FUNCTION, { 0, 0 }, { 2, 0 }) }
    local _, chain = chain_at(wide_lines(), tree, 4, 0)
    eq({}, names(chain))
end)

it("the scope end is exclusive, to the column", function()
    local tree = { node("Fn", FUNCTION, { 0, 0 }, { 0, 5 }) }
    local _, inside = chain_at({ "abcdefgh" }, tree, 1, 4)
    eq({ "Fn" }, names(inside), "column 4 is the last one inside")

    local _, on_end = chain_at({ "abcdefgh" }, tree, 1, 5)
    eq({}, names(on_end), "column 5 IS the end: already past the scope, not highlighted for one column more")
end)

it("the last-started sibling is the one that can contain the cursor", function()
    local tree = {
        node("first", FUNCTION, { 0, 0 }, { 2, 0 }),
        node("second", FUNCTION, { 2, 0 }, { 4, 0 }),
        node("third", FUNCTION, { 4, 0 }, { 6, 0 }),
    }
    local _, c1 = chain_at(wide_lines(), tree, 1, 0)
    eq({ "first" }, names(c1))
    local _, c2 = chain_at(wide_lines(), tree, 3, 0)
    eq({ "second" }, names(c2))
    local _, c3 = chain_at(wide_lines(), tree, 5, 0)
    eq({ "third" }, names(c3))
end)

it("a gap between siblings has no chain, and does not pick the one before it", function()
    local tree = {
        node("first", FUNCTION, { 0, 0 }, { 1, 0 }),
        node("second", FUNCTION, { 4, 0 }, { 6, 0 }),
    }
    local _, chain = chain_at(wide_lines(), tree, 3, 0)
    eq({}, names(chain))
end)

it("descent stops where the nesting stops", function()
    local tree = {
        node("Outer", CLASS, { 0, 0 }, { 10, 0 }, {
            node("inner", METHOD, { 2, 0 }, { 4, 0 }),
        }),
    }
    local _, chain = chain_at(wide_lines(), tree, 6, 0)
    eq({ "Outer" }, names(chain), "inside the class but past the method")
end)

it("the cursor column is converted into the server's encoding", function()
    -- "абв" is three characters: 6 bytes, and 3 units in utf-16. A symbol that starts at
    -- character 3 begins right after them, so a cursor at byte 6 is exactly on its start.
    local tree = { node("Fn", FUNCTION, { 0, 3 }, { 0, 20 }) }

    local _, utf16 = chain_at({ "абвfoo" }, tree, 1, 6, "utf-16")
    eq({ "Fn" }, names(utf16), "byte 6 is character 3 in utf-16")

    local _, before = chain_at({ "абвfoo" }, tree, 1, 4, "utf-16")
    eq({}, names(before), "byte 4 is character 2, still before the symbol")

    -- With a utf-8 server the units ARE bytes, so the same symbol starts three bytes in.
    local _, utf8 = chain_at({ "абвfoo" }, tree, 1, 4, "utf-8")
    eq({ "Fn" }, names(utf8))
end)

it("an entry carries what a consumer switches on", function()
    local tree = { node("Thing", FUNCTION, { 0, 0 }, { 5, 0 }) }
    local _, chain = chain_at(wide_lines(), tree, 1, 0)
    eq(1, #chain)
    local e = chain[1]
    eq("Thing", e.name)
    eq(FUNCTION, e.kind)
    eq("Function", e.type, "the kind NAME, which is what kind-keyed consumers use")
    truthy(type(e.icon) == "string")
    truthy(type(e.hl) == "string" and e.hl:match("^LvimBreadcrumbs"), e.hl)
    eq({ line = 0, character = 0 }, { line = e.scope_range.start.line, character = e.scope_range.start.character })
    eq("utf-16", e.jump.encoding, "a jump from an LSP chain carries the encoding its column is in")
end)

it("a buffer with no tree and no treesitter chain has no data at all", function()
    vim.cmd("enew!")
    local buf = vim.api.nvim_get_current_buf()
    lsp.buffers[buf] = nil
    local was = config.ts_fallback
    config.ts_fallback = false
    eq(nil, locate.data(buf), "nil, not an empty list: no source could answer")
    config.ts_fallback = was
end)

describe("lvim-breadcrumbs: how the chain renders")

--- Render with a hand-built chain in place.
---@param tree table[]
---@param row integer
---@param col integer
---@param opts table
---@return string
local function rendered(tree, row, col, opts)
    local buf = chain_at(wide_lines(), tree, row, col)
    return render.location(vim.tbl_extend("force", { bufnr = buf }, opts))
end

local NESTED = {
    node("Outer", CLASS, { 0, 0 }, { 10, 0 }, {
        node("inner", METHOD, { 1, 0 }, { 8, 0 }, {
            node("deep", FUNCTION, { 2, 0 }, { 6, 0 }),
        }),
    }),
}

it("plain text is the names, pointer-separated", function()
    local out = rendered(NESTED, 4, 0, { highlight = false, file_prefix = false })
    eq(2, select(2, out:gsub("➤", "")), "three segments carry two separators")
    truthy(out:match("Outer"), out)
    truthy(out:match("deep"), out)
    eq(nil, out:match("%%#"), "no highlight groups were asked for")
end)

it("highlighting wraps every segment in its kind group", function()
    local out = rendered(NESTED, 4, 0, { highlight = true, file_prefix = false })
    truthy(out:match("%%#LvimBreadcrumbsClass#"), out)
    truthy(out:match("%%#LvimBreadcrumbsSeparator#"), out)
end)

it("a name containing a percent sign cannot break the statusline", function()
    local tree = { node("100%done", FUNCTION, { 0, 0 }, { 5, 0 }) }
    local out = rendered(tree, 1, 0, { highlight = false, file_prefix = false })
    truthy(out:match("100%%%%done"), "a bare %% would be read as a statusline item: " .. out)
end)

it("a name spanning lines is flattened", function()
    local tree = { node("two\n  lines", FUNCTION, { 0, 0 }, { 5, 0 }) }
    local out = rendered(tree, 1, 0, { highlight = false, file_prefix = false })
    eq(nil, out:match("\n"), out)
    truthy(out:match("two lines"), out)
end)

it("the depth limit keeps the DEEPEST segments and elides the head", function()
    local out = rendered(NESTED, 4, 0, { highlight = false, file_prefix = false, depth_limit = 2 })
    truthy(out:match("…"), "the dropped head is announced: " .. out)
    truthy(out:match("inner"), out)
    truthy(out:match("deep"), out)
    eq(nil, out:match("Outer"), "the shallowest segment is the one worth dropping: " .. out)
end)

it("a chain inside the limit is rendered whole, with no indicator", function()
    local out = rendered(NESTED, 4, 0, { highlight = false, file_prefix = false, depth_limit = 5 })
    eq(nil, out:match("…"), out)
    truthy(out:match("Outer"), out)
end)

it("the indicator is configurable", function()
    local out = rendered(NESTED, 4, 0, {
        highlight = false,
        file_prefix = false,
        depth_limit = 1,
        depth_limit_indicator = "<<",
    })
    truthy(out:match("<<"), out)
end)

it("clicks wrap each segment in a region carrying its chain index", function()
    local out = rendered(NESTED, 4, 0, { highlight = false, file_prefix = false, clicks = true })
    truthy(out:match("%%1@"), "segment 1 -> index 1: " .. out)
    truthy(out:match("%%3@"), "segment 3 -> index 3: " .. out)
    truthy(out:match("%%X"), "and each region is closed")
end)

it("no chain renders as an empty string, so a bar can concatenate it unconditionally", function()
    vim.cmd("enew!")
    local buf = vim.api.nvim_get_current_buf()
    lsp.buffers[buf] = { tree = {}, encoding = "utf-16", chain = {} }
    eq("", render.location({ bufnr = buf, file_prefix = false }))
end)

it("the file prefix leads with the file's tail, not its path", function()
    vim.cmd("enew!")
    local buf = vim.api.nvim_get_current_buf()
    local path = vim.fn.tempname() .. "/sub/dir/subject.lua"
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.api.nvim_buf_set_name(buf, path)
    lsp.buffers[buf] = { tree = {}, encoding = "utf-16", chain = {} }

    local out = render.location({ bufnr = buf, highlight = false, file_prefix = true })
    truthy(out:match("subject%.lua"), out)
    eq(nil, out:match("sub/dir"), "the path is not the breadcrumb: " .. out)
end)

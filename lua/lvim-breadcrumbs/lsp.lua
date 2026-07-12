-- lvim-breadcrumbs.lsp: the per-buffer symbol-tree cache over textDocument/documentSymbol.
-- One request per EDIT, never per cursor move: TextChanged/InsertLeave re-request through ONE
-- persistent uv timer per buffer (config.refresh_ms), the previous in-flight request is
-- CANCELLED before the next is issued, and a late response for an older edit is dropped by a
-- per-buffer GENERATION counter (the lightbulb discipline). The response is normalized into a
-- nested node tree with children SORTED by start position — the invariant locate.lua's binary
-- search relies on. Hierarchical DocumentSymbol[] is preferred; a flat SymbolInformation[]
-- (older servers) is upconverted into the same tree by range containment.
--
-- Columns in the cached ranges stay in the SERVER's position encoding (never converted per
-- symbol); locate.lua converts the single cursor position instead — one conversion per move
-- beats thousands per refresh.
--
---@module "lvim-breadcrumbs.lsp"

local config = require("lvim-breadcrumbs.config")
local locate = require("lvim-breadcrumbs.locate")

local api = vim.api
local uv = vim.uv
local ms = vim.lsp.protocol.Methods

local M = {}

---@class LvimBreadcrumbsNode
---@field name     string                LSP-reported symbol name
---@field kind     integer               LSP SymbolKind number
---@field start    { line: integer, character: integer }  scope start (0-based; character in the server encoding)
---@field finish   { line: integer, character: integer }  scope end (exclusive, LSP semantics)
---@field sel      { line: integer, character: integer }  selectionRange start — the jump target
---@field children LvimBreadcrumbsNode[] nested symbols, sorted by `start`

---@class LvimBreadcrumbsBufState
---@field client_id  integer               the documentSymbol client the cache is built from
---@field encoding   string                that client's position encoding ("utf-8"|"utf-16"|"utf-32")
---@field tree       LvimBreadcrumbsNode[]|nil  root symbols, sorted by `start`; nil until the first response
---@field chain      table[]               cached cursor→root ancestor chain (locate.lua entries)
---@field timer      uv.uv_timer_t         persistent edit-debounce timer (closed on detach)
---@field generation integer               bumped per issued request; stale responses compare against it
---@field cancel     fun()|nil             cancels the in-flight request, if any
---@field augroup    integer               buffer-local autocmd group (deleted on detach)

--- Per-buffer runtime state, keyed by bufnr. Presence = the buffer is attached.
---@type table<integer, LvimBreadcrumbsBufState>
M.buffers = {}

--- Position `a` is before-or-at `b` (line-major, then encoded character).
---@param a { line: integer, character: integer }
---@param b { line: integer, character: integer }
---@return boolean
local function pos_le(a, b)
    if a.line ~= b.line then
        return a.line < b.line
    end
    return a.character <= b.character
end

--- Sort nodes in place by start position and recurse — the binary-search invariant.
---@param nodes LvimBreadcrumbsNode[]
---@return nil
local function sort_tree(nodes)
    table.sort(nodes, function(x, y)
        if x.start.line ~= y.start.line then
            return x.start.line < y.start.line
        end
        return x.start.character < y.start.character
    end)
    for _, n in ipairs(nodes) do
        sort_tree(n.children)
    end
end

--- Normalize a hierarchical DocumentSymbol[] into the node tree.
---@param symbols table[]
---@return LvimBreadcrumbsNode[]
local function from_document_symbols(symbols)
    local out = {}
    for _, s in ipairs(symbols) do
        if type(s.name) == "string" and type(s.range) == "table" then
            out[#out + 1] = {
                name = s.name,
                kind = s.kind or 13, -- Variable when a server omits the kind
                start = s.range.start,
                finish = s.range["end"],
                sel = (s.selectionRange or s.range).start,
                children = type(s.children) == "table" and from_document_symbols(s.children) or {},
            }
        end
    end
    return out
end

--- Upconvert a flat SymbolInformation[] into the same tree by RANGE CONTAINMENT: sorted by
--- start ascending (end descending on ties, so a container precedes the children it starts
--- with), each symbol nests under the deepest open symbol whose range still contains it.
---@param symbols table[]
---@return LvimBreadcrumbsNode[]
local function from_symbol_information(symbols)
    ---@type LvimBreadcrumbsNode[]
    local nodes = {}
    for _, s in ipairs(symbols) do
        local range = s.location and s.location.range
        if type(s.name) == "string" and type(range) == "table" then
            nodes[#nodes + 1] = {
                name = s.name,
                kind = s.kind or 13,
                start = range.start,
                finish = range["end"],
                sel = range.start,
                children = {},
            }
        end
    end
    table.sort(nodes, function(x, y)
        if x.start.line ~= y.start.line then
            return x.start.line < y.start.line
        end
        if x.start.character ~= y.start.character then
            return x.start.character < y.start.character
        end
        -- same start: the LARGER range is the container → first
        if x.finish.line ~= y.finish.line then
            return x.finish.line > y.finish.line
        end
        return x.finish.character > y.finish.character
    end)
    local roots, stack = {}, {} ---@type LvimBreadcrumbsNode[], LvimBreadcrumbsNode[]
    for _, n in ipairs(nodes) do
        while #stack > 0 and not (pos_le(stack[#stack].start, n.start) and pos_le(n.finish, stack[#stack].finish)) do
            stack[#stack] = nil
        end
        local parent = stack[#stack]
        if parent then
            parent.children[#parent.children + 1] = n
        else
            roots[#roots + 1] = n
        end
        stack[#stack + 1] = n
    end
    return roots
end

--- Cancel the in-flight request of a buffer, if any.
---@param st LvimBreadcrumbsBufState
---@return nil
local function cancel_request(st)
    if st.cancel then
        pcall(st.cancel)
        st.cancel = nil
    end
end

--- Issue the documentSymbol request for `bufnr` NOW (the debounce already elapsed). The
--- response is normalized + sorted into `st.tree`, the cursor chain refreshed, and the bars
--- repainted; a response that lost the generation race (a newer edit re-requested) is dropped.
---@param bufnr integer
---@return nil
local function request(bufnr)
    local st = M.buffers[bufnr]
    if not st or not api.nvim_buf_is_valid(bufnr) then
        return
    end
    local client = vim.lsp.get_client_by_id(st.client_id)
    if not client then
        return
    end
    cancel_request(st)
    st.generation = st.generation + 1
    local gen = st.generation
    local ok, request_id = client:request(ms.textDocument_documentSymbol, {
        textDocument = vim.lsp.util.make_text_document_params(bufnr),
    }, function(err, result)
        local cur = M.buffers[bufnr]
        if not cur or cur.generation ~= gen or not api.nvim_buf_is_valid(bufnr) then
            return -- detached, or a newer request superseded this response
        end
        cur.cancel = nil
        if err or type(result) ~= "table" then
            return -- keep the previous tree; a transient server error must not blank the trail
        end
        -- DocumentSymbol has `range`, SymbolInformation has `location` — sniff the first entry.
        local first = result[1]
        if first == nil then
            cur.tree = {}
        elseif first.range ~= nil then
            cur.tree = from_document_symbols(result)
        else
            cur.tree = from_symbol_information(result)
        end
        sort_tree(cur.tree)
        locate.update(bufnr)
        -- repaint the winbar/statusline consumers now — the tree changed under a still cursor
        vim.cmd.redrawstatus({ bang = true })
    end, bufnr)
    if ok and request_id then
        st.cancel = function()
            client:cancel_request(request_id)
        end
    end
end

--- Debounced refresh: (re)arm the buffer's persistent timer for config.refresh_ms.
---@param bufnr integer
---@return nil
local function schedule(bufnr)
    local st = M.buffers[bufnr]
    if not st or st.timer:is_closing() then
        return
    end
    st.timer:stop()
    st.timer:start(
        math.max(0, config.refresh_ms or 300),
        0,
        vim.schedule_wrap(function()
            request(bufnr)
        end)
    )
end

--- Attach `client`'s symbol tree to `bufnr` (idempotent; the navic-contract seam called from
--- an on_attach / LspAttach). Verifies the documentSymbol capability, issues the first
--- request immediately and installs the buffer-local autocmds: edits re-request (debounced),
--- cursor moves only re-locate over the cache.
---@param client vim.lsp.Client
---@param bufnr integer
---@return boolean attached
function M.attach(client, bufnr)
    if not (client and client:supports_method(ms.textDocument_documentSymbol, bufnr)) then
        return false
    end
    if not api.nvim_buf_is_valid(bufnr) then
        return false
    end
    local st = M.buffers[bufnr]
    if st then
        st.client_id = client.id -- re-attach (e.g. a restarted server): reuse the state, refresh
        st.encoding = client.offset_encoding or "utf-16"
        request(bufnr)
        return true
    end
    local augroup = api.nvim_create_augroup("LvimBreadcrumbsBuf" .. bufnr, { clear = true })
    M.buffers[bufnr] = {
        client_id = client.id,
        encoding = client.offset_encoding or "utf-16",
        tree = nil,
        chain = {},
        timer = assert(uv.new_timer()),
        generation = 0,
        cancel = nil,
        augroup = augroup,
    }
    api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
        group = augroup,
        buffer = bufnr,
        desc = "lvim-breadcrumbs: re-request the symbol tree (debounced)",
        callback = function()
            schedule(bufnr)
        end,
    })
    api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = augroup,
        buffer = bufnr,
        desc = "lvim-breadcrumbs: re-locate the cursor chain (cache only, no request)",
        callback = function()
            locate.update(bufnr)
        end,
    })
    api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
        group = augroup,
        buffer = bufnr,
        desc = "lvim-breadcrumbs: drop the buffer state",
        callback = function()
            M.detach(bufnr)
        end,
    })
    request(bufnr)
    return true
end

--- Tear a buffer's state down: cancel the in-flight request, close the timer, remove the
--- buffer-local autocmds. Called on LspDetach (when the LAST capable client leaves) and on
--- buffer deletion.
---@param bufnr integer
---@return nil
function M.detach(bufnr)
    local st = M.buffers[bufnr]
    if not st then
        return
    end
    M.buffers[bufnr] = nil
    cancel_request(st)
    st.timer:stop()
    if not st.timer:is_closing() then
        st.timer:close()
    end
    pcall(api.nvim_del_augroup_by_id, st.augroup)
end

--- Whether `bufnr` has an attached client AND a cached symbol tree already.
---@param bufnr integer
---@return boolean
function M.has_tree(bufnr)
    local st = M.buffers[bufnr]
    return st ~= nil and st.tree ~= nil
end

return M

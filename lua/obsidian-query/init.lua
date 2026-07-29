-- Render Obsidian query-style fences (```query, ```dataview) inline via a
-- render-markdown custom handler, with a snacks.picker jump on <CR>.
local render = require("obsidian-query.render")

local M = {}

---@param opts obsidian-query.Opts?
function M.setup(opts)
  require("obsidian-query.config").set(opts)
  -- obsidian.nvim re-maps <CR> on every BufEnter and then fires
  -- ObsidianNoteEnter — hooking that event is the only ordering that lets
  -- these wrappers win over its own mapping.
  vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("obsidian_query_keymaps", { clear = true }),
    pattern = "ObsidianNoteEnter",
    callback = function(ev)
      vim.keymap.set("n", "<CR>", function()
        if M.cursor_in_query() then
          return "<cmd>lua require('obsidian-query').open_picker()<CR>"
        end
        return require("obsidian.actions").smart_action()
      end, { expr = true, buffer = ev.buf, desc = "Query results / Obsidian Smart Action" })
      -- unhandled keys must behave normally: replay them (noremap, so the
      -- mapping can't recurse)
      local function fallthrough(lhs)
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), "n", false)
      end
      -- NOT expr: opening windows is forbidden during expr evaluation (E565).
      -- Single click activates result targets; the double-click mapping keeps
      -- the second click of a real double-click from falling through.
      for _, lhs in ipairs({ "<LeftMouse>", "<2-LeftMouse>" }) do
        vim.keymap.set("n", lhs, function()
          if not M.click() then
            fallthrough(lhs)
          end
        end, { buffer = ev.buf, desc = "Query result click" })
      end
      for lhs, delta in pairs({ ["<Left>"] = -1, ["<Right>"] = 1 }) do
        vim.keymap.set("n", lhs, function()
          if not M.shift(delta) then
            fallthrough(lhs)
          end
        end, { buffer = ev.buf, desc = "Calendar month back/forward" })
      end
      vim.keymap.set("n", "<Home>", function()
        if not M.shift(nil) then
          fallthrough("<Home>")
        end
      end, { buffer = ev.buf, desc = "Calendar back to today" })
    end,
  })
end

-- fence language -> engine (see obsidian-query.search for the interface)
local engines = {
  query = require("obsidian-query.search"),
  dataview = require("obsidian-query.dataview"),
}

-- key -> { result?: table, fetching?: boolean, stale?: boolean, bufs: table<integer, true> }
local cache = {}
local stale_au ---@type integer?

---Workspace root for a buffer, from the buffer's own path — NOT the globally
---active workspace, which changes as other vaults' notes are visited and
---would contaminate this buffer's queries.
---@return string? root
function M.buf_root(buf)
  if not _G.Obsidian then
    return nil
  end
  local path = vim.api.nvim_buf_get_name(buf)
  local ok, ws = pcall(function()
    return require("obsidian.api").find_workspace(path)
  end)
  ws = (ok and ws) or Obsidian.workspace
  return ws and vim.fs.normalize(tostring(ws.path)) or nil
end

-- Workspace context for a fence; nil outside an Obsidian workspace
local function get_ctx(buf)
  local root = M.buf_root(buf)
  return root and { root = root, buf = buf } or nil
end

local function mark_stale_on_change()
  if stale_au then
    return
  end
  stale_au = vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
    group = vim.api.nvim_create_augroup("obsidian_query_stale", { clear = true }),
    pattern = "*.md",
    callback = function()
      for _, entry in pairs(cache) do
        entry.stale = true
      end
    end,
  })
end

local function refetch(engine, key, spec, ctx)
  local entry = cache[key]
  entry.fetching = true
  engine.run(spec, ctx, function(result)
    if not cache[key] then
      return
    end
    if result == nil then
      -- transient failure (e.g. this vault's cache not active right now):
      -- keep showing the previous result, stay stale, retry on a later parse
      entry.fetching = false
      return
    end
    -- engines may park view state on the result (calendar month); a refetch
    -- must not snap the user back to the current month
    result.view = entry.result and entry.result.view or nil
    entry.result, entry.fetching, entry.stale = result, false, false
    entry.result_id = (entry.result_id or 0) + 1
    -- keep nudging render-markdown until a parse pass consumes this result
    -- (M.parse stamps shown_id)
    local id = entry.result_id
    render.retry(function()
      return entry.shown_id == id or entry.result_id ~= id
    end, function()
      for buf in pairs(entry.bufs) do
        if vim.api.nvim_buf_is_valid(buf) then
          require("render-markdown.api").render({ buf = buf, event = "ObsidianQuery" })
        else
          entry.bufs[buf] = nil
        end
      end
    end)
  end)
end

local ts_query ---@type vim.treesitter.Query?
---Shared fence query (also consumed by obsidian-query.highlight)
function M.fence_query()
  if not ts_query then
    ts_query = vim.treesitter.query.parse(
      "markdown",
      [[(fenced_code_block (info_string (language) @lang) (code_fence_content) @body) @block]]
    )
  end
  return ts_query
end

local get_query = M.fence_query

---render-markdown custom-handler parse
---@param ctx render.md.handler.Context
---@return render.md.Mark[]
function M.parse(ctx)
  mark_stale_on_change()
  require("obsidian-query.highlight").attach(ctx.buf)
  local query = get_query()
  local marks = {}
  for _, match in query:iter_matches(ctx.root, ctx.buf) do
    local lang, body, block
    -- iter_matches yields TSNode[] per capture (nvim 0.11+); the fence query
    -- captures each name once, so the last node is the node
    for id, nodes in pairs(match) do
      local name = query.captures[id]
      if name == "lang" then
        lang = nodes[#nodes]
      elseif name == "body" then
        body = nodes[#nodes]
      elseif name == "block" then
        block = nodes[#nodes]
      end
    end
    local engine = lang and engines[vim.treesitter.get_node_text(lang, ctx.buf)]
    if engine and body and block then
      local qctx = get_ctx(ctx.buf)
      local spec = qctx and engine.parse(vim.treesitter.get_node_text(body, ctx.buf))
      local key = spec and engine.key(spec, qctx)
      if key then
        local entry = cache[key]
        if not entry then
          entry = { bufs = {} }
          cache[key] = entry
        end
        entry.bufs[ctx.buf] = true
        if not entry.fetching and (not entry.result or entry.stale) then
          refetch(engine, key, spec, qctx)
        end
        local lines = entry.result and engine.lines(entry.result) or render.pending()
        if entry.result then
          entry.shown_id = entry.result_id -- current result reached a render pass
        end
        local mark = render.anchored_mark(block, ctx.buf, lines)
        -- geometry for the mouse handler (M.click): which screen rows/cols
        -- of this virt block map to what is engine business
        entry.engine = engine
        entry.anchor = {
          buf = ctx.buf,
          row = mark.start_row,
          above = mark.opts.virt_lines_above,
          nlines = #lines,
        }
        marks[#marks + 1] = mark
      end
    end
  end
  return marks
end

M.handler = { extends = true, parse = M.parse }

-- Engine + parsed spec of the fence under the cursor, or nil
local function fence_at_cursor()
  local ok, node = pcall(vim.treesitter.get_node, { ignore_injections = true })
  if not ok then
    return nil
  end
  while node and node:type() ~= "fenced_code_block" do
    node = node:parent()
  end
  if not node then
    return nil
  end
  local engine, body
  for child in node:iter_children() do
    if child:type() == "info_string" then
      engine = engines[vim.trim(vim.treesitter.get_node_text(child, 0))]
    elseif child:type() == "code_fence_content" then
      body = vim.treesitter.get_node_text(child, 0)
    end
  end
  if not engine or not body then
    return nil
  end
  local spec = engine.parse(body)
  return spec and { engine = engine, spec = spec } or nil
end

function M.cursor_in_query()
  return fence_at_cursor() ~= nil
end

---Mouse entry point (<LeftMouse>): resolve which virt line/column of which
---rendered block was clicked and let the owning engine handle it.
---@return boolean handled
function M.click()
  local mpos = vim.fn.getmousepos()
  if not mpos or mpos.winid == 0 then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(mpos.winid)
  for _, entry in pairs(cache) do
    local a = entry.anchor
    if a and a.buf == buf and entry.result and entry.engine and entry.engine.click then
      local sp = vim.fn.screenpos(mpos.winid, a.row + 1, 1)
      if sp and sp.row > 0 then
        -- virt block occupies the rows above (virt_lines_above) or below the anchor
        local top = a.above and (sp.row - a.nlines) or (sp.row + 1)
        local vidx = mpos.screenrow - top + 1
        if vidx >= 1 and vidx <= a.nlines then
          local textoff = vim.fn.getwininfo(mpos.winid)[1].textoff
          local col = mpos.wincol - textoff
          if entry.engine.click(entry.result, vidx, col) then
            -- a click may have changed view state (calendar arrows)
            require("render-markdown.api").render({ buf = buf, event = "ObsidianQuery" })
            return true
          end
        end
      end
    end
  end
  return false
end

---<Left>/<Right>/<Home> on a fence: shift its view (calendar month) and
---re-render; a nil delta means "back to the current month".
---@return boolean handled — false lets the key fall through to its default
function M.shift(delta)
  local fence = fence_at_cursor()
  local buf = vim.api.nvim_get_current_buf()
  local ctx = fence and fence.engine.shift and get_ctx(buf)
  if not ctx then
    return false
  end
  local entry = cache[fence.engine.key(fence.spec, ctx)]
  if not (entry and entry.result and fence.engine.shift(entry.result, delta)) then
    return false
  end
  require("render-markdown.api").render({ buf = buf, event = "ObsidianQuery" })
  return true
end

-- Jump entry point: virt_lines can't hold the cursor, so results open in a picker
function M.open_picker()
  local fence = fence_at_cursor()
  local ctx = fence and get_ctx(vim.api.nvim_get_current_buf())
  if not ctx then
    return
  end
  local entry = cache[fence.engine.key(fence.spec, ctx)]
  if entry and entry.result then
    fence.engine.pick(fence.spec, ctx, entry.result)
  end
end

return M

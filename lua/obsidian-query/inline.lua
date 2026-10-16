-- Inline `= expr` queries: markdown_inline custom handler evaluating dataview
-- expressions in code spans against the note's own page. Result overlays the
-- span as inline virt_text; raw span reappears on the cursor row (anti-conceal)
-- and errors/null render nothing — prose never grows error banners.
local M = {}

local idx ---@type table? cached obsidian-query.index result
local idx_root ---@type string? vault the cached index belongs to
local idx_stale, idx_pending = false, false
local idx_gen, shown_gen = 0, 0
local stale_gen = 0 -- bumped per invalidation: a request begun before one stays stale
local request ---@type table? token of the in-flight index request
local bufs = {} ---@type table<integer, true> buffers showing inline values
local stale_au ---@type integer?
local expr_cache = setmetatable({}, { __mode = "v" }) ---@type table<string, table> parsed ASTs

local function mark_stale_on_change()
  if stale_au then
    return
  end
  stale_au = vim.api.nvim_create_autocmd({ "BufWritePost" }, {
    group = vim.api.nvim_create_augroup("obsidian_inline_stale", { clear = true }),
    pattern = "*.md",
    callback = function()
      require("obsidian-query.index").invalidate()
      idx_stale, stale_gen = true, stale_gen + 1
    end,
  })
end

local function nudge()
  for buf in pairs(bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      require("render-markdown.api").render({ buf = buf, event = "ObsidianInline" })
    else
      bufs[buf] = nil
    end
  end
end

-- nudge render-markdown until a parse pass has consumed the fresh index
local function rerender()
  local id = idx_gen
  require("obsidian-query.render").retry(function()
    return shown_gen >= id or idx_gen ~= id
  end, nudge)
end

---Notes changed (obsidian's file watcher: writes from nvim or outside):
---refetch on the next parse, and drive one for every inline buffer.
function M.mark_stale()
  idx_stale, stale_gen = true, stale_gen + 1
  if next(bufs) then
    require("obsidian-query.render").retry(function()
      return not idx_stale
    end, nudge)
  end
end

---Drop the cached index (workspace switched): old-vault values must not
---render against the new vault. An in-flight request is forgotten too — its
---callback may never come (obsidian.nvim drops queued cache callbacks on a
---switch) and must not land if it does.
function M.invalidate()
  idx, idx_root, idx_stale = nil, nil, false
  idx_pending, request = false, nil
end

local function ensure_index(root)
  if idx and idx_root ~= root then
    M.invalidate() -- different vault: never serve the old index
  end
  if idx and not idx_stale then
    return idx
  end
  if not idx_pending then
    idx_pending = true
    local token, start_gen = {}, stale_gen
    request = token
    require("obsidian-query.index").get({ root = root }, function(result)
      if request ~= token then
        return -- superseded by invalidate()
      end
      idx_pending, request = false, nil
      if result then
        -- a change that landed mid-request leaves the index stale: refetch
        idx, idx_root, idx_stale = result, root, stale_gen ~= start_gen
        idx_gen = idx_gen + 1
        rerender()
      end
    end)
  end
  return idx -- possibly stale (still render) or nil (pending)
end

local ts_query ---@type vim.treesitter.Query?
local function get_query()
  if not ts_query then
    ts_query = vim.treesitter.query.parse("markdown_inline", [[(code_span) @span]])
  end
  return ts_query
end

---render-markdown custom-handler parse for markdown_inline
---@param ctx render.md.handler.Context
---@return render.md.Mark[]
function M.parse(ctx)
  mark_stale_on_change()
  local root = require("obsidian-query").buf_root(ctx.buf)
  if not root then
    return {}
  end
  local settings = require("obsidian-query.dataview.settings").get(root)
  if not settings.enableInlineDataview then
    return {}
  end
  local path = vim.api.nvim_buf_get_name(ctx.buf)
  if not vim.startswith(path, root .. "/") then
    return {}
  end
  local marks = {}
  local query = get_query()
  local spans = {}
  for _, match in query:iter_matches(ctx.root, ctx.buf) do
    for _, nodes in pairs(match) do
      local node = nodes[#nodes] -- TSNode[] per capture (nvim 0.11+)
      local text = vim.treesitter.get_node_text(node, ctx.buf)
      local prefix = "`" .. settings.inlineQueryPrefix
      local expr = vim.startswith(text, prefix) and text:sub(-1) == "`" and vim.trim(text:sub(#prefix + 1, -2)) or nil
      if expr then
        spans[#spans + 1] = { node = node, expr = expr }
      end
    end
  end
  if #spans == 0 then
    bufs[ctx.buf] = nil
    return {}
  end
  bufs[ctx.buf] = true
  local index = ensure_index(root)
  if not index then
    return {} -- index loading; rerender() will bring the results in
  end
  local page = require("obsidian-query.index").this_page(index, ctx.buf, root)
  if not page then
    return {}
  end
  shown_gen = idx_gen
  local eval = require("obsidian-query.dataview.eval")
  local value = require("obsidian-query.dataview.value")
  for _, span in ipairs(spans) do
    local ast = expr_cache[span.expr]
    if ast == nil then
      ast = require("obsidian-query.dataview.parser").parse_expr(span.expr) or false
      if ast then
        expr_cache[span.expr] = ast
      end
    end
    if ast then
      local qctx = {
        settings = settings,
        index = index.rows,
        pages = index.pages,
        root = root,
        sup = index.sup,
        inlinks = index.inlinks,
        starred = index.starred,
        this_path = path,
        this = page,
        resolve = index.resolve or require("obsidian-query.index").make_resolver(index.rows),
      }
      local result = eval.expr(ast, require("obsidian-query.dataview.query").env(page, qctx))
      local display = value.to_display(result, settings)
      if display ~= "" then
        local srow, scol, erow, ecol = span.node:range()
        marks[#marks + 1] = {
          conceal = true, -- raw `= expr` back on the cursor row
          start_row = srow,
          start_col = scol,
          opts = {
            end_row = erow,
            end_col = ecol,
            conceal = "",
            virt_text = { { display, "Special" } },
            virt_text_pos = "inline",
          },
        }
      end
    end
  end
  return marks
end

M.handler = { extends = true, parse = M.parse }

return M

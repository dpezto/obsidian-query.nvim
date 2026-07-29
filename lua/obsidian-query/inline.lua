-- Inline `= expr` queries: markdown_inline custom handler evaluating dataview
-- expressions in code spans against the note's own page. Result overlays the
-- span as inline virt_text; raw span reappears on the cursor row (anti-conceal)
-- and errors/null render nothing — prose never grows error banners.
local M = {}

local idx ---@type table? cached obsidian-query.index result
local idx_stale, idx_pending = false, false
local idx_gen, shown_gen = 0, 0
local stale_au ---@type integer?
local expr_cache = {} ---@type table<string, table|false> parsed ASTs
local page_cache = {} ---@type table<string, {gen: integer, page: table}>

local function mark_stale_on_change()
  if stale_au then
    return
  end
  stale_au = vim.api.nvim_create_autocmd({ "BufWritePost" }, {
    group = vim.api.nvim_create_augroup("obsidian_inline_stale", { clear = true }),
    pattern = "*.md",
    callback = function()
      idx_stale = true
    end,
  })
end

-- same decorator-drop dance as init.refetch: retry with exponential backoff
-- until a parse pass has consumed the freshly loaded index
local function rerender(buf)
  local id, tries, delay = idx_gen, 0, 150
  local function attempt()
    if shown_gen >= id or idx_gen ~= id or tries >= 5 then
      return
    end
    tries = tries + 1
    if vim.api.nvim_buf_is_valid(buf) then
      require("render-markdown.api").render({ buf = buf, event = "ObsidianInline" })
    end
    delay = delay * 2
    vim.defer_fn(attempt, delay)
  end
  vim.defer_fn(attempt, delay)
end

local function ensure_index(root, buf)
  if idx and not idx_stale then
    return idx
  end
  if not idx_pending then
    idx_pending = true
    require("obsidian-query.index").get({ root = root }, function(result)
      idx_pending = false
      if result then
        idx, idx_stale = result, false
        idx_gen = idx_gen + 1
        page_cache = {}
        rerender(buf)
      end
    end)
  end
  return idx -- possibly stale (still render) or nil (pending)
end

local function get_page(path, root)
  local hit = page_cache[path]
  if hit and hit.gen == idx_gen then
    return hit.page
  end
  local row = idx.rows[path]
  if not row then
    return nil
  end
  local page = require("obsidian-query.dataview.page").build(path, row, {
    root = root,
    sup = idx.sup,
    inlinks = idx.inlinks,
  })
  page_cache[path] = { gen = idx_gen, page = page }
  return page
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
  local path = vim.api.nvim_buf_get_name(ctx.buf)
  if not vim.startswith(path, root .. "/") then
    return {}
  end
  local marks = {}
  local to_node = require("obsidian-query").to_node
  local query = get_query()
  local spans = {}
  for _, match in query:iter_matches(ctx.root, ctx.buf) do
    for _, nodes in pairs(match) do
      local node = to_node(nodes)
      local text = vim.treesitter.get_node_text(node, ctx.buf)
      local expr = text:match("^`=%s+(.-)`$")
      if expr then
        spans[#spans + 1] = { node = node, expr = expr }
      end
    end
  end
  if #spans == 0 then
    return {}
  end
  local index = ensure_index(root, ctx.buf)
  if not index then
    return {} -- index loading; rerender() will bring the results in
  end
  local page = get_page(path, root)
  if not page then
    return {}
  end
  shown_gen = idx_gen
  local eval = require("obsidian-query.dataview.eval")
  local value = require("obsidian-query.dataview.value")
  local functions = require("obsidian-query.dataview.functions")
  for _, span in ipairs(spans) do
    local ast = expr_cache[span.expr]
    if ast == nil then
      ast = require("obsidian-query.dataview.parser").parse_expr(span.expr) or false
      expr_cache[span.expr] = ast
    end
    if ast then
      local result = eval.expr(ast, { page = page, this = page, funcs = functions.registry })
      local display = value.to_display(result)
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

-- Vault index for the dataview engine.
--
-- Primary data: obsidian.nvim's cache rows
--   { mtime, size, aliases[], tags[], properties, links_out[], tasks[] }.
-- Supplement (built here, mtime-keyed per note, in-memory):
--   fields  : inline `Key:: value` fields (full-line and [key:: v]/(key:: v))
--   headers : { {line, level, text} } (1-indexed lines)
-- Plus inlinks: inversion of links_out (recomputed per refresh; cheap).
--
-- M.get(ctx, cb) -> cb(index|nil, err)
--   index = { rows = table<abs_path, row>, sup = table<abs_path, {mtime, fields, headers}>,
--             inlinks = table<abs_path, abs_path[]>, root = ctx.root }
local M = {}

local sup = {} ---@type table<string, {mtime: integer, fields: table, headers: table}>
local BATCH = 25

local function extract_sup(path)
  local fd = io.open(path, "r")
  if not fd then
    return { fields = {}, headers = {} }
  end
  local fields, headers = {}, {}
  local lnum, in_fence = 0, false
  for line in fd:lines() do
    lnum = lnum + 1
    if line:match("^%s*```") then
      in_fence = not in_fence
    elseif not in_fence then
      local hashes, text = line:match("^(#+)%s+(.*)$")
      if hashes then
        headers[#headers + 1] = { line = lnum, level = #hashes, text = text }
      end
      -- full-line field: `Key:: value`
      local k, v = line:match("^([%w][%w%s_/%-]-)::%s*(.*)$")
      if k then
        fields[vim.trim(k):lower():gsub("%s+", "-")] = v
      end
      -- bracketed inline fields: [key:: v] / (key:: v)
      for bk, bv in line:gmatch("[%[%(]([%w][%w%s_/%-]-)::%s*([^%]%)]*)[%]%)]") do
        fields[vim.trim(bk):lower():gsub("%s+", "-")] = vim.trim(bv)
      end
    end
  end
  fd:close()
  return { fields = fields, headers = headers }
end

---Resolve a links_out target (note name or rel path) to an absolute path.
local function make_resolver(rows)
  local by_name = {}
  for path in pairs(rows) do
    by_name[vim.fn.fnamemodify(path, ":t:r"):lower()] = path
    by_name[vim.fn.fnamemodify(path, ":t"):lower()] = path
  end
  return function(target, root)
    if not target or target == "" then
      return nil
    end
    target = target:gsub("#.*$", ""):gsub("%s+$", "")
    local direct = root .. "/" .. target
    if rows[direct] or rows[direct .. ".md"] then
      return rows[direct] and direct or (direct .. ".md")
    end
    return by_name[vim.fn.fnamemodify(target, ":t:r"):lower()]
  end
end

---@param ctx {root: string}
---@param cb fun(index: table?, err: string?)
function M.get(ctx, cb)
  local ok, cache = pcall(require, "obsidian.cache")
  if not ok or not cache.is_enabled() then
    cb(nil, "obsidian.nvim cache disabled")
    return
  end
  cache.when_ready(function()
    local all = cache.notes.all()
    -- restrict to this workspace
    local rows = {}
    for path, row in pairs(all) do
      if vim.startswith(path, ctx.root .. "/") then
        rows[path] = row
      end
    end
    -- inlinks inversion (cache rows only, no IO)
    local resolve = make_resolver(rows)
    local inlinks = {}
    for path, row in pairs(rows) do
      for _, l in ipairs(row.links_out or {}) do
        local target = resolve(l.target, ctx.root)
        if target then
          inlinks[target] = inlinks[target] or {}
          table.insert(inlinks[target], path)
        end
      end
    end
    -- refresh stale supplements in batches off the fast path
    local stale = {}
    for path, row in pairs(rows) do
      local s = sup[path]
      if not s or s.mtime ~= row.mtime then
        stale[#stale + 1] = { path = path, mtime = row.mtime }
      end
    end
    local i = 1
    local function step()
      local stop = math.min(i + BATCH - 1, #stale)
      while i <= stop do
        local e = stale[i]
        i = i + 1
        local data = extract_sup(e.path)
        sup[e.path] = { mtime = e.mtime, fields = data.fields, headers = data.headers }
      end
      if i <= #stale then
        vim.schedule(step)
      else
        cb({ rows = rows, sup = sup, inlinks = inlinks, root = ctx.root })
      end
    end
    step()
  end)
end

return M

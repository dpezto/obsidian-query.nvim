-- Vault index for the dataview engine.
--
-- Primary data: obsidian.nvim's cache rows
--   { stat = {mtime_sec, mtime_nsec, size}, aliases[], tags[], properties,
--     links_out[], tasks[] } (pre-v3.16 rows keep mtime/mtime_nsec/size flat).
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
local generation = 0
local cached, pending = {}, {}

function M.invalidate()
  generation = generation + 1
  cached, pending = {}, {}
end

---Obsidian bookmarks (.obsidian/bookmarks.json) -> set of vault-relative paths
local function read_starred(root)
  local fd = io.open(root .. "/.obsidian/bookmarks.json", "r")
  if not fd then
    return {}
  end
  local raw = fd:read("*a")
  fd:close()
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" then
    return {}
  end
  local starred = {}
  local function walk(items)
    for _, item in ipairs(items or {}) do
      if item.type == "file" and item.path then
        starred[item.path] = true
      elseif item.type == "group" then
        walk(item.items)
      end
    end
  end
  walk(data.items)
  return starred
end
M._read_starred = read_starred -- test hook

---Code-fence tracking (CommonMark: ``` or ~~~, 3+ long; closed only by the
---same char at least as long, nothing else on the line).
---@param line string
---@param open string? fence marker currently open, nil outside fences
---@return string? open marker after this line
function M.fence(line, open)
  local marker = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
  if not open then
    return marker
  end
  if marker and marker:sub(1, 1) == open:sub(1, 1) and #marker >= #open and line:match("^%s*[`~]+%s*$") then
    return nil
  end
  return open
end

local function extract_sup(path, lines)
  local fd = not lines and io.open(path, "r") or nil
  if not lines and not fd then
    return { fields = {}, headers = {}, lists = {} }
  end
  local fields, headers, lists = {}, {}, {}
  local lnum, fence, in_fm = 0, nil, false
  local iterator = fd and fd:lines() or function()
    return lines[lnum + 1]
  end
  for line in iterator do
    lnum = lnum + 1
    local body = false
    -- frontmatter delimiters: YAML `- item` lines must not count as lists
    if lnum == 1 and line == "---" then
      in_fm = true
    elseif in_fm and (line:match("^%-%-%-%s*$") or line:match("^%.%.%.%s*$")) then
      in_fm = false
    elseif not in_fm then
      local was_fence = fence
      fence = M.fence(line, fence)
      body = not was_fence and not fence
    end
    if body then
      local hashes, text = line:match("^(#+)%s+(.*)$")
      if hashes then
        headers[#headers + 1] = { line = lnum, level = #hashes, text = text }
      end
      -- repeated keys accumulate into arrays (dataview merges duplicates)
      local function add_field(key, val)
        local cur = fields[key]
        if cur == nil then
          fields[key] = val
        elseif type(cur) == "table" then
          table.insert(cur, val)
        else
          fields[key] = { cur, val }
        end
      end
      -- full-line field: `Key:: value`
      local k, v = line:match("^([%w][%w%s_/%-]-)::%s*(.*)$")
      if k then
        add_field(vim.trim(k):lower():gsub("%s+", "-"), v)
      end
      -- bracketed inline fields: [key:: v] / (key:: v)
      for bk, bv in line:gmatch("[%[%(]([%w][%w%s_/%-]-)::%s*([^%]%)]*)[%]%)]") do
        add_field(vim.trim(bk):lower():gsub("%s+", "-"), vim.trim(bv))
      end
      -- list items (bulleted or numbered); the cache only indexes checkboxes
      local ws, text = line:match("^(%s*)[%-%*%+]%s+(.+)$")
      if not ws then
        ws, text = line:match("^(%s*)%d+[%.%)]%s+(.+)$")
      end
      if ws then
        lists[#lists + 1] = { line = lnum, indent = #ws, text = text }
      end
    end
  end
  if fd then
    fd:close()
  end
  return { fields = fields, headers = headers, lists = lists }
end
M._extract_sup = extract_sup

---Resolve a links_out target (note name or rel path) to an absolute path.
function M.make_resolver(rows)
  local by_name, by_path = {}, {}
  for path in pairs(rows) do
    local name = vim.fn.tolower(vim.fn.fnamemodify(path, ":t"))
    by_name[name] = by_name[name] or {}
    by_name[name][#by_name[name] + 1] = path
    by_path[vim.fn.tolower(path)] = path
  end
  for _, paths in pairs(by_name) do
    table.sort(paths, function(a, b)
      return #a < #b or (#a == #b and a < b)
    end)
  end
  local function exact(path)
    path = vim.fn.tolower(vim.fs.normalize(path))
    return by_path[path] or by_path[path .. ".md"]
  end
  return function(target, root, source, relative)
    if not target then
      return nil
    end
    target = vim.trim(target:gsub("[|#].*$", ""))
    if target == "" then
      return source and rows[source] and source or nil
    end
    if target:match("^%a[%w+%.%-]*:") then
      return nil
    end
    if relative then
      target = vim.uri_decode(target)
    end
    if source and (relative or target:match("^%.%./") or target:match("^%./")) then
      local path = exact(vim.fs.dirname(source) .. "/" .. target)
      if path then
        return path
      end
    end
    local path = exact(root .. "/" .. target:gsub("^/", ""))
    if path then
      return path
    end
    if target:sub(1, 1) == "/" then
      return nil
    end
    target = vim.fn.tolower(target)
    local name = vim.fn.fnamemodify(target, ":t")
    local paths = by_name[name]
    if not paths then
      target, paths = target .. ".md", by_name[name .. ".md"]
    end
    local fallback
    local folder = source and vim.fn.tolower(vim.fs.dirname(source) .. "/")
    for _, candidate in ipairs(paths or {}) do
      local lower = vim.fn.tolower(candidate)
      if vim.endswith(lower, "/" .. target) then
        if folder and vim.startswith(lower, folder) then
          return candidate
        end
        fallback = fallback or candidate
      end
    end
    return fallback
  end
end

---Only the containing note uses unsaved content; shared saved pages stay immutable.
function M.this_page(idx, buf, root)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local path = vim.api.nvim_buf_get_name(buf)
  local ctx = {
    root = root,
    index = idx.rows,
    pages = idx.pages,
    sup = idx.sup,
    inlinks = idx.inlinks,
    starred = idx.starred,
    resolve = idx.resolve,
  }
  local page = require("obsidian-query.dataview.page")
  if not vim.bo[buf].modified then
    return page.get(path, ctx)
  end
  idx.buffer_pages = idx.buffer_pages or {}
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local hit = idx.buffer_pages[buf]
  if hit and hit.tick == tick and hit.path == path then
    return hit.page
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local supplement = extract_sup(path, lines)
  local note = require("obsidian-query.search.eval").note(path, path, table.concat(lines, "\n"))
  local row = vim.tbl_extend("force", {}, idx.rows[path] or {})
  row.properties = note:frontmatter()
  row.aliases = row.properties.aliases or row.properties.alias or {}
  if type(row.aliases) == "string" then
    row.aliases = { row.aliases }
  end
  row.tags, row.tasks, row.links_out = {}, {}, {}
  local seen = {}
  for _, tag in ipairs(note:tags()) do
    if not seen[tag.tag] then
      row.tags[#row.tags + 1], seen[tag.tag] = tag.tag, true
    end
  end
  for _, li in ipairs(supplement.lists) do
    local state, text = li.text:match("^%[([^%]])%]%s*(.*)$")
    if state then
      row.tasks[#row.tasks + 1] = { line = li.line, indent = li.indent, state = state, text = text }
    end
  end
  local ok, refs = pcall(require, "obsidian.parse.refs")
  for i, line in ipairs(lines) do
    if ok then
      for _, ref in ipairs(refs.extract(line, { row = i - 1, lexical = true })) do
        if ref.kind == "wiki" or ref.kind == "markdown" then
          row.links_out[#row.links_out + 1] = ref
        end
      end
    else
      for target in line:gmatch("%[%[([^|%]]+)[^%]]*%]%]") do
        row.links_out[#row.links_out + 1] = { target = target, kind = "wiki" }
      end
    end
  end
  ctx.sup = { [path] = supplement }
  local result = page.build(path, row, ctx)
  idx.buffer_pages[buf] = { tick = tick, path = path, page = result }
  return result
end

---@param ctx {root: string}
---@param cb fun(index: table?, err: string?, transient: boolean?)
function M.get(ctx, cb)
  local ok, cache = pcall(require, "obsidian.cache")
  if not ok or not cache.is_enabled() then
    cb(nil, "obsidian.nvim cache disabled")
    return
  end
  -- the cache holds only the ACTIVE vault; a buffer from another workspace
  -- must not be re-evaluated against it (results would empty out)
  local active = _G.Obsidian and Obsidian.dir and vim.fs.normalize(tostring(Obsidian.dir))
  if active and vim.fs.normalize(ctx.root) ~= active then
    cb(nil, "workspace not active", true)
    return
  end
  if cached[ctx.root] then
    cb(cached[ctx.root])
    return
  end
  if pending[ctx.root] then
    table.insert(pending[ctx.root], cb)
    return
  end
  local callbacks, gen = { cb }, generation
  pending[ctx.root] = callbacks
  local function finish(result, err, transient)
    if pending[ctx.root] == callbacks then
      pending[ctx.root] = nil
    end
    if generation ~= gen then
      result, err, transient = nil, "index invalidated", true
    elseif result then
      cached[ctx.root] = result
    end
    for _, callback in ipairs(callbacks) do
      callback(result, err, transient)
    end
  end
  cache.when_ready(function()
    local current = _G.Obsidian and Obsidian.dir and vim.fs.normalize(tostring(Obsidian.dir))
    if generation ~= gen or (current and current ~= vim.fs.normalize(ctx.root)) then
      finish(nil, "workspace not active", true)
      return
    end
    local all = cache.notes.all()
    -- restrict to this workspace
    local rows = {}
    for path, row in pairs(all) do
      if vim.startswith(path, ctx.root .. "/") then
        rows[path] = row
      end
    end
    -- inlinks inversion (cache rows only, no IO)
    local resolve = M.make_resolver(rows)
    local inlinks = {}
    for path, row in pairs(rows) do
      local seen = {}
      for _, l in ipairs(row.links_out or {}) do
        local target = resolve(l.target, ctx.root, path, l.kind == "markdown")
        if target and not seen[target] then
          seen[target] = true
          inlinks[target] = inlinks[target] or {}
          table.insert(inlinks[target], path)
        end
      end
    end
    -- refresh stale supplements in batches off the fast path
    local function fresh(s, e)
      return s and s.mtime == e.mtime and s.mtime_nsec == e.mtime_nsec and s.size == e.size
    end
    local stale = {}
    for path, row in pairs(rows) do
      local st = row.stat or row -- v3.16+ nests stats; older rows were flat
      local e = { path = path, mtime = st.mtime_sec or st.mtime, mtime_nsec = st.mtime_nsec, size = st.size }
      if not fresh(sup[path], e) then
        stale[#stale + 1] = e
      end
    end
    local i = 1
    local function step()
      local stop = math.min(i + BATCH - 1, #stale)
      while i <= stop do
        local e = stale[i]
        i = i + 1
        -- a concurrent request (another fence) may have refreshed it meanwhile
        if not fresh(sup[e.path], e) then
          local data = extract_sup(e.path)
          data.mtime, data.mtime_nsec, data.size = e.mtime, e.mtime_nsec, e.size
          sup[e.path] = data
        end
      end
      if i <= #stale then
        vim.schedule(step)
      else
        finish({
          pages = {},
          generation = gen,
          rows = rows,
          sup = sup,
          inlinks = inlinks,
          root = ctx.root,
          resolve = resolve,
          starred = read_starred(ctx.root),
        })
      end
    end
    step()
  end)
end

return M

-- DQL execution pipeline: parse -> FROM page set -> fold commands in written
-- order -> header projection. Synchronous (index is in-memory).
--
-- M.run(src, ctx) -> { ok=true, data } | { ok=false, phase, msg, pos? }
-- ctx = { index = table<abs_path, cache_row>, root, this_path?,
--         sup?, inlinks?, now? }
local parser = require("obsidian-query.dataview.parser")
local eval = require("obsidian-query.dataview.eval")
local page_mod = require("obsidian-query.dataview.page")
local functions = require("obsidian-query.dataview.functions")
local value = require("obsidian-query.dataview.value")

local M = {}

local NULL = value.NULL

---------------------------------------------------------------- FROM

local function resolve_link_path(raw, ctx)
  local target = vim.trim(raw:gsub("|.*$", ""):gsub("#.*$", ""))
  if target == "" then
    return ctx.this_path
  end
  local direct = ctx.root .. "/" .. target
  if ctx.index[direct] then
    return direct
  end
  if ctx.index[direct .. ".md"] then
    return direct .. ".md"
  end
  local want = vim.fn.fnamemodify(target, ":t:r"):lower()
  for path in pairs(ctx.index) do
    if vim.fn.fnamemodify(path, ":t:r"):lower() == want then
      return path
    end
  end
end

local function source_set(src, ctx)
  local k = src.k
  if k == "s_tag" then
    local out = {}
    for path, row in pairs(ctx.index) do
      for _, t in ipairs(row.tags or {}) do
        if t == src.tag or vim.startswith(t, src.tag .. "/") then
          out[path] = true
          break
        end
      end
    end
    return out
  elseif k == "s_folder" then
    local out = {}
    local prefix = ctx.root .. "/" .. src.folder
    for path in pairs(ctx.index) do
      if path == prefix or path == prefix .. ".md" or vim.startswith(path, prefix .. "/") then
        out[path] = true
      end
    end
    return out
  elseif k == "s_link" then
    -- pages linking TO the target
    local out = {}
    local target = resolve_link_path(src.raw, ctx)
    if target and ctx.inlinks then
      for _, p in ipairs(ctx.inlinks[target] or {}) do
        out[p] = true
      end
    end
    return out
  elseif k == "s_outgoing" then
    -- pages the target links to
    local out = {}
    local target = resolve_link_path(src.raw, ctx)
    local row = target and ctx.index[target]
    if row then
      for _, l in ipairs(row.links_out or {}) do
        local direct = ctx.root .. "/" .. (l.target or "")
        if ctx.index[direct] then
          out[direct] = true
        elseif ctx.index[direct .. ".md"] then
          out[direct .. ".md"] = true
        else
          local want = vim.fn.fnamemodify(l.target or "", ":t:r"):lower()
          for path in pairs(ctx.index) do
            if vim.fn.fnamemodify(path, ":t:r"):lower() == want then
              out[path] = true
              break
            end
          end
        end
      end
    end
    return out
  elseif k == "s_and" then
    local acc = source_set(src.kids[1], ctx)
    for i = 2, #src.kids do
      local s = source_set(src.kids[i], ctx)
      for path in pairs(acc) do
        if not s[path] then
          acc[path] = nil
        end
      end
    end
    return acc
  elseif k == "s_or" then
    local acc = {}
    for _, kid in ipairs(src.kids) do
      for path in pairs(source_set(kid, ctx)) do
        acc[path] = true
      end
    end
    return acc
  elseif k == "s_csv" then
    error("csv() must be the only FROM source", 0)
  elseif k == "s_not" then
    local exclude = source_set(src.kid, ctx)
    local out = {}
    for path in pairs(ctx.index) do
      if not exclude[path] then
        out[path] = true
      end
    end
    return out
  end
  return {}
end

---------------------------------------------------------------- csv

local function parse_csv_line(line)
  local fields, i, n = {}, 1, #line
  while i <= n do
    if line:sub(i, i) == '"' then
      local buf = {}
      i = i + 1
      while i <= n do
        local ch = line:sub(i, i)
        if ch == '"' and line:sub(i + 1, i + 1) == '"' then
          buf[#buf + 1] = '"'
          i = i + 2
        elseif ch == '"' then
          i = i + 1
          break
        else
          buf[#buf + 1] = ch
          i = i + 1
        end
      end
      fields[#fields + 1] = table.concat(buf)
      i = i + 1 -- separating comma
    else
      local j = line:find(",", i, true)
      fields[#fields + 1] = line:sub(i, (j or n + 1) - 1)
      i = (j or n + 1) + 1
    end
  end
  if line:sub(-1) == "," then
    fields[#fields + 1] = ""
  end
  return fields
end

local function decode_cell(v)
  if v == "" then
    return value.NULL
  end
  local n = tonumber(v)
  if n then
    return n
  end
  return page_mod.decode_fm(v)
end

---FROM csv("path"): each row becomes a synthetic page
local function csv_rows(rel, ctx)
  local abs = rel:sub(1, 1) == "/" and rel or (ctx.root .. "/" .. rel)
  local fd = io.open(abs, "r")
  if not fd then
    error(("csv(%q): file not found"):format(rel), 0)
  end
  local header, rows = nil, {}
  local base = vim.fn.fnamemodify(rel, ":t:r")
  for line in fd:lines() do
    line = line:gsub("\r$", "")
    if line ~= "" then
      local cells = parse_csv_line(line)
      if not header then
        header = {}
        for i, h in ipairs(cells) do
          header[i] = vim.trim(h):lower():gsub("%s+", "-")
        end
      else
        local row = {}
        for i, key in ipairs(header) do
          row[key] = decode_cell(vim.trim(cells[i] or ""))
        end
        row.file = {
          name = ("%s#%d"):format(base, #rows + 1),
          path = rel,
          folder = vim.fn.fnamemodify(rel, ":h"):gsub("^%.$", ""),
          link = value.link(rel),
        }
        row._path = abs
        rows[#rows + 1] = row
      end
    end
  end
  fd:close()
  return rows
end

---------------------------------------------------------------- rows

local function overlay(base, binds)
  return setmetatable(binds, { __index = base })
end

local function row_env(row, ctx)
  return { page = row, this = ctx.this or NULL, funcs = functions.registry, now = ctx.now }
end

local function default_alias(src_text)
  return (src_text or "value"):match("([%w_%-]+)%s*$") or "value"
end

---------------------------------------------------------------- pipeline

local function run_commands(rows, cmds, ctx)
  for _, cmd in ipairs(cmds) do
    if cmd.cmd == "where" then
      local kept = {}
      for _, row in ipairs(rows) do
        if value.truthy(eval.expr(cmd.expr, row_env(row, ctx))) then
          kept[#kept + 1] = row
        end
      end
      rows = kept
    elseif cmd.cmd == "sort" then
      local decorated = {}
      for i, row in ipairs(rows) do
        local keys = {}
        for j, k in ipairs(cmd.keys) do
          keys[j] = eval.expr(k.expr, row_env(row, ctx))
        end
        decorated[i] = { row = row, keys = keys, i = i }
      end
      table.sort(decorated, function(a, b)
        for j, k in ipairs(cmd.keys) do
          local c = value.cmp(a.keys[j], b.keys[j])
          if k.dir == "desc" then
            c = -c
          end
          if c ~= 0 then
            return c < 0
          end
        end
        return a.i < b.i -- stable
      end)
      rows = vim.tbl_map(function(d)
        return d.row
      end, decorated)
    elseif cmd.cmd == "group" then
      local buckets, order = {}, {}
      for _, row in ipairs(rows) do
        local key = eval.expr(cmd.expr, row_env(row, ctx))
        local id = value.to_display(key) .. "\0" .. value.typeof(key)
        local bucket = buckets[id]
        if not bucket then
          bucket = { key = key, members = {} }
          buckets[id] = bucket
          order[#order + 1] = bucket
        end
        table.insert(bucket.members, row)
      end
      local grouped = {}
      for _, bucket in ipairs(order) do
        local g = {
          key = bucket.key,
          rows = value.array(bucket.members),
          file = { link = NULL, path = "", name = value.to_display(bucket.key) },
        }
        if cmd.alias then
          g[cmd.alias] = bucket.key
        end
        grouped[#grouped + 1] = g
      end
      rows = grouped
    elseif cmd.cmd == "flatten" then
      local alias = cmd.alias or default_alias(cmd.src)
      local out = {}
      for _, row in ipairs(rows) do
        local v = eval.expr(cmd.expr, row_env(row, ctx))
        if value.typeof(v) == "array" then
          if #v == 0 then
            out[#out + 1] = overlay(row, { [alias] = NULL })
          else
            for _, el in ipairs(v) do
              out[#out + 1] = overlay(row, { [alias] = el })
            end
          end
        else
          out[#out + 1] = overlay(row, { [alias] = v })
        end
      end
      rows = out
    elseif cmd.cmd == "limit" then
      local n = eval.expr(cmd.expr, { funcs = functions.registry, now = ctx.now })
      if type(n) == "number" then
        rows = vim.list_slice(rows, 1, math.max(0, math.floor(n)))
      end
    end
  end
  return rows
end

---------------------------------------------------------------- projection

local function project(header, rows, ctx)
  if header.kind == "table" then
    local columns = {}
    if not header.without_id then
      columns[#columns + 1] = "File"
    end
    for _, f in ipairs(header.fields) do
      columns[#columns + 1] = f.alias or f.src
    end
    local out_rows = {}
    for _, row in ipairs(rows) do
      local cells = {}
      for _, f in ipairs(header.fields) do
        cells[#cells + 1] = eval.expr(f.expr, row_env(row, ctx))
      end
      local id
      if not header.without_id then
        id = (row.file and row.file.link ~= nil and value.typeof(row.file.link) == "link") and row.file.link
          or (row.key ~= nil and row.key)
          or NULL
      end
      out_rows[#out_rows + 1] = {
        id = id,
        cells = cells,
        path = row._path or (row.file and row.file.path ~= "" and (ctx.root .. "/" .. row.file.path)) or "",
      }
    end
    return { kind = "table", with_id = not header.without_id, columns = columns, rows = out_rows }
  elseif header.kind == "list" then
    -- grouped rows (from GROUP BY) become groups; otherwise one flat group
    local groups = {}
    local grouped = #rows > 0 and rows[1].rows ~= nil and value.typeof(rows[1].rows) == "array"
    if grouped then
      for _, g in ipairs(rows) do
        local items = {}
        for _, member in ipairs(g.rows) do
          items[#items + 1] = {
            link = member.file and member.file.link or NULL,
            text = header.expr and eval.expr(header.expr, row_env(member, ctx)) or nil,
            path = member._path or "",
          }
        end
        groups[#groups + 1] = { key = g.key, items = items }
      end
    else
      local items = {}
      for _, row in ipairs(rows) do
        items[#items + 1] = {
          link = not header.without_id and (row.file and row.file.link or NULL) or nil,
          text = header.expr and eval.expr(header.expr, row_env(row, ctx)) or nil,
          path = row._path or "",
        }
      end
      groups[1] = { key = nil, items = items }
    end
    return { kind = "list", groups = groups }
  elseif header.kind == "calendar" then
    -- bucket dated rows by (year, month); months + dated both newest-first
    local months, by_ym, dated = {}, {}, {}
    for _, row in ipairs(rows) do
      local d = header.expr and eval.expr(header.expr, row_env(row, ctx)) or (row.file and row.file.day)
      if value.typeof(d) == "date" then
        local ym = d.year * 100 + d.month
        local m = by_ym[ym]
        if not m then
          m = { year = d.year, month = d.month, days = {} }
          by_ym[ym] = m
          months[#months + 1] = m
        end
        m.days[d.day] = m.days[d.day] or {}
        table.insert(m.days[d.day], row._path or "")
        dated[#dated + 1] = { date = d, path = row._path or "" }
      end
    end
    table.sort(months, function(a, b)
      return a.year * 100 + a.month > b.year * 100 + b.month
    end)
    table.sort(dated, function(a, b)
      return a.date.ts > b.date.ts
    end)
    return { kind = "calendar", months = months, dated = dated }
  elseif header.kind == "task" then
    local groups, by_file, order = {}, {}, {}
    local grouped = #rows > 0 and rows[1].rows ~= nil and value.typeof(rows[1].rows) == "array"
    if grouped then
      for _, g in ipairs(rows) do
        local items = {}
        for _, member in ipairs(g.rows) do
          if getmetatable(member._task or {}) == value.task_mt or member._task then
            items[#items + 1] = member._task
          end
        end
        groups[#groups + 1] = { key = g.key, items = items }
      end
    else
      for _, row in ipairs(rows) do
        if row._task then
          local fpath = row._path or ""
          local g = by_file[fpath]
          if not g then
            g = { key = row.file and row.file.link or NULL, items = {} }
            by_file[fpath] = g
            order[#order + 1] = g
          end
          table.insert(g.items, row._task)
        end
      end
      groups = order
    end
    return { kind = "task", groups = groups }
  end
  return { kind = "unsupported", what = header.kind }
end

---------------------------------------------------------------- entry

---@param src string
---@param ctx table
---@return table result
function M.run(src, ctx)
  local ast, perr = parser.parse(src)
  if not ast then
    return { ok = false, phase = "parse", msg = perr.msg, pos = perr.pos }
  end
  local ok, result = pcall(function()
    -- FROM: first from command; absent -> whole vault
    local from_src
    for _, cmd in ipairs(ast.commands) do
      if cmd.cmd == "from" then
        from_src = cmd.src
        break
      end
    end
    local rows
    if from_src and from_src.k == "s_csv" then
      rows = csv_rows(from_src.path, ctx)
    else
      local set
      if from_src then
        set = source_set(from_src, ctx)
      else
        set = {}
        for path in pairs(ctx.index) do
          set[path] = true
        end
      end
      local paths = vim.tbl_keys(set)
      table.sort(paths)
      rows = {}
      for _, path in ipairs(paths) do
        rows[#rows + 1] = page_mod.build(path, ctx.index[path], ctx)
      end
    end
    if ctx.this_path and ctx.index[ctx.this_path] then
      ctx.this = page_mod.build(ctx.this_path, ctx.index[ctx.this_path], ctx)
    end
    -- TASK: explode to task overlay rows BEFORE commands (dataview semantics)
    if ast.header.kind == "task" then
      local exploded = {}
      for _, row in ipairs(rows) do
        for _, task in ipairs(row.file.tasks) do
          local o = overlay(row, { _task = task })
          for k, v in pairs(task) do
            rawset(o, k, v)
          end
          o._task = task
          exploded[#exploded + 1] = o
        end
      end
      rows = exploded
    end
    local cmds = vim.tbl_filter(function(c)
      return c.cmd ~= "from"
    end, ast.commands)
    rows = run_commands(rows, cmds, ctx)
    return project(ast.header, rows, ctx)
  end)
  if not ok then
    return { ok = false, phase = "eval", msg = tostring(result) }
  end
  return { ok = true, data = result }
end

return M

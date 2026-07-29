-- Cache row -> Page object (the eval env root).
-- ctx = { root, sup = {[path]={fields,headers}}, inlinks = {[path]={paths}}, now? }
local value = require("obsidian-query.dataview.value")

local M = {}

local NULL = value.NULL

local function sanitize(k)
  return k:lower():gsub("%s+", "-")
end

---Decode a raw frontmatter value into dv-values (ISO dates, [[links]], lists).
function M.decode_fm(v)
  local t = type(v)
  if t == "string" then
    local d = value.parse_date(v)
    if d ~= NULL then
      return d
    end
    local inner = v:match("^%[%[(.+)%]%]$")
    if inner then
      local path, display = inner:match("^([^|]*)|?(.*)$")
      return value.link(vim.trim(path), { display = display ~= "" and display or nil })
    end
    return v
  elseif t == "table" then
    if vim.islist(v) then
      local out = {}
      for i, el in ipairs(v) do
        out[i] = M.decode_fm(el)
      end
      return value.array(out)
    end
    local out = {}
    for k, el in pairs(v) do
      out[k] = M.decode_fm(el)
    end
    return out
  elseif v == vim.NIL then
    return NULL
  end
  return v
end

-- Tasks-plugin emoji shorthands -> field names (each followed by a date)
local TASK_EMOJI = {
  ["🗓️"] = "due", ["📅"] = "due",
  ["✅"] = "completion",
  ["➕"] = "created",
  ["⏳"] = "scheduled", ["⌛"] = "scheduled",
  ["🛫"] = "start",
}

---Tag prefix expansion: a/b/c -> {a, a/b, a/b/c}
local function expand_tags(tags)
  local out, seen = {}, {}
  for _, t in ipairs(tags or {}) do
    local acc = nil
    for part in t:gmatch("[^/]+") do
      acc = acc and (acc .. "/" .. part) or part
      if not seen[acc] then
        seen[acc] = true
        out[#out + 1] = "#" .. acc
      end
    end
  end
  return out
end

---@param abs_path string
---@param cache_tasks table[] cache rows {line, indent, state, text}
---@param headers table[] {line, level, text} sorted by line
---@param rel string vault-relative path
function M.build_tasks(abs_path, cache_tasks, headers, rel)
  local tasks, stack = {}, {}
  for _, ct in ipairs(cache_tasks or {}) do
    -- nearest preceding header (headers sorted by line; both 1-indexed)
    local section
    for i = #headers, 1, -1 do
      if headers[i].line < ct.line then
        section = headers[i]
        break
      end
    end
    local tags = {}
    for tag in (ct.text or ""):gmatch("#([%w_][%w_/%-]*)") do
      tags[#tags + 1] = "#" .. tag:lower()
    end
    -- inline fields on the task: [due:: 2026-08-01] / (key:: v) + emoji dates
    local fields = {}
    for k, v in (ct.text or ""):gmatch("[%[%(]([%w][%w%s_/%-]-)::%s*([^%]%)]*)[%]%)]") do
      fields[sanitize(vim.trim(k))] = M.decode_fm(vim.trim(v))
    end
    for emoji, field in pairs(TASK_EMOJI) do
      local d = (ct.text or ""):match(vim.pesc(emoji) .. "%s*(%d%d%d%d%-%d%d%-%d%d)")
      if d and fields[field] == nil then
        fields[field] = value.parse_date(d)
      end
    end
    local task = value.task({
      text = ct.text or "",
      status = ct.state or " ",
      checked = ct.state ~= " ",
      completed = ct.state == "x" or ct.state == "X",
      fullyCompleted = ct.state == "x" or ct.state == "X", -- refined by fold below
      line = ct.line, -- cache rows store 1-indexed lines (cache/note.lua loops from 1)
      indent = ct.indent or 0,
      path = abs_path,
      section = section
          and value.link(rel, { subpath = section.text, kind = "header", display = section.text })
        or value.link(rel),
      link = value.link(rel, section and { subpath = section.text, kind = "header" } or nil),
      tags = value.array(tags),
      children = value.array({}),
      parent = NULL,
    })
    for k, v in pairs(fields) do
      if rawget(task, k) == nil then
        task[k] = v
      end
    end
    -- indent-stack nesting
    while #stack > 0 and stack[#stack].indent >= task.indent do
      table.remove(stack)
    end
    if #stack > 0 then
      task.parent = stack[#stack].line
      table.insert(stack[#stack].children, task)
    end
    stack[#stack + 1] = task
    tasks[#tasks + 1] = task
  end
  -- post-order fullyCompleted fold
  local function fold(task)
    local full = task.completed
    for _, child in ipairs(task.children) do
      full = fold(child) and full
    end
    task.fullyCompleted = full
    return full
  end
  for _, t in ipairs(tasks) do
    if value.typeof(t.parent) == "null" then
      fold(t)
    end
  end
  return value.array(tasks)
end

---@param abs_path string
---@param row table obsidian.nvim cache row
---@param ctx table
---@return table page
function M.build(abs_path, row, ctx)
  local rel = abs_path:sub(#ctx.root + 2)
  local name = vim.fn.fnamemodify(abs_path, ":t:r")
  local sup = ctx.sup and ctx.sup[abs_path] or { fields = {}, headers = {} }

  local page = {}

  -- frontmatter flattening: raw key, lowered, sanitized kebab (last write wins)
  local fm = {}
  for k, v in pairs(row.properties or {}) do
    fm[k] = M.decode_fm(v)
  end
  for k, v in pairs(fm) do
    page[sanitize(k)] = v
    page[k:lower()] = v
    page[k] = v
  end
  -- inline Key:: fields (already sanitized keys); frontmatter wins on collision
  for k, v in pairs(sup.fields or {}) do
    if page[k] == nil then
      page[k] = M.decode_fm(v)
    end
  end

  local day = value.parse_date(name)
  if day == NULL and fm.date then
    day = value.typeof(fm.date) == "date" and fm.date or NULL
  end

  local outlinks = {}
  for _, l in ipairs(row.links_out or {}) do
    if l.target and l.target ~= "" then
      outlinks[#outlinks + 1] = value.link(l.target, { display = l.label })
    end
  end
  local inlinks = {}
  for _, p in ipairs(ctx.inlinks and ctx.inlinks[abs_path] or {}) do
    inlinks[#inlinks + 1] = value.link(p:sub(#ctx.root + 2))
  end

  local tasks = M.build_tasks(abs_path, row.tasks, sup.headers or {}, rel)

  page.file = setmetatable({
    name = name,
    folder = vim.fn.fnamemodify(rel, ":h"):gsub("^%.$", ""),
    path = rel,
    ext = vim.fn.fnamemodify(rel, ":e"),
    link = value.link(rel),
    size = row.size or 0,
    mtime = value.date(row.mtime or 0, "datetime"),
    mday = value.date(row.mtime or 0, "date"),
    day = day,
    tags = value.array(expand_tags(row.tags)),
    etags = value.array(vim.tbl_map(function(t)
      return "#" .. t
    end, row.tags or {})),
    aliases = value.array(vim.deepcopy(row.aliases or {})),
    tasks = tasks,
    starred = (ctx.starred and ctx.starred[rel]) or false,
    lists = tasks, -- cache indexes only checkbox items; documented limitation
    outlinks = value.array(outlinks),
    inlinks = value.array(inlinks),
    frontmatter = row.properties or {},
  }, {
    __index = function(self, key)
      -- ctime needs an fs_stat; fetched lazily and cached
      if key == "ctime" or key == "cday" then
        local stat = vim.uv.fs_stat(abs_path)
        local ts = stat and stat.birthtime and stat.birthtime.sec or (stat and stat.ctime.sec) or 0
        rawset(self, "ctime", value.date(ts, "datetime"))
        rawset(self, "cday", value.date(ts, "date"))
        return rawget(self, key)
      end
    end,
  })

  page._path = abs_path
  return page
end

return M

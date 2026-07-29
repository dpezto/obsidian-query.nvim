-- Evaluate a search AST (search/parser.lua) against one note.
--
-- eval.note(path, rel, content) -> Note   (lazy fm/tags/sections/blocks/tasks)
-- eval.run(ast, note)           -> ok: boolean, locs: {lnum, col, text}[]
--
-- Case: Obsidian smart case — term with an uppercase letter is case-sensitive,
-- else insensitive; match-case:/ignore-case: force it for their subtree.
local M = {}

---------------------------------------------------------------- note model

local TASK_PATTERNS = {
  "^%s*[%-%*%+]%s+%[(.)%]%s*(.*)$",
  "^%s*%d+[%.%)]%s+%[(.)%]%s*(.*)$",
}

local Note = {}
Note.__index = Note

---Display label: notes lose the .md, attachments keep their extension.
---(`file:` and bare terms match `note.name`, the full basename, so
---`file:.md` behaves as in Obsidian.)
function M.label(path)
  return vim.fn.fnamemodify(path, path:sub(-3) == ".md" and ":t:r" or ":t")
end

function M.note(path, rel, content)
  return setmetatable({
    path = path,
    rel = rel,
    name = vim.fn.fnamemodify(path, ":t"),
    lines = vim.split(content, "\n", { plain = true }),
  }, Note)
end

-- naive fallback for tests / when obsidian.nvim is absent: top-level
-- `key: value`, block lists, inline [a, b] lists
local function naive_yaml(lines)
  local data, last_key = {}, nil
  for _, l in ipairs(lines) do
    local item = l:match("^%s+%-%s*(.+)$")
    local key, val = l:match("^([%w_%- ]+):%s*(.*)$")
    if item and last_key then
      if type(data[last_key]) ~= "table" then
        data[last_key] = {}
      end
      table.insert(data[last_key], (item:gsub('^"(.*)"$', "%1")))
    elseif key then
      key = vim.trim(key)
      last_key = key
      local inline = val:match("^%[(.*)%]$")
      if inline then
        data[key] = vim.tbl_map(vim.trim, vim.split(inline, ",", { trimempty = true }))
      elseif val ~= "" then
        data[key] = (val:gsub('^"(.*)"$', "%1"))
      else
        data[key] = {}
      end
    end
  end
  return data
end

---Frontmatter region [2, fm_end-1] and parsed table; {} when absent.
function Note:frontmatter()
  if self._fm then
    return self._fm, self._fm_end
  end
  self._fm, self._fm_end = {}, 0
  if self.lines[1] == "---" then
    for i = 2, #self.lines do
      if self.lines[i]:match("^%-%-%-%s*$") or self.lines[i]:match("^%.%.%.%s*$") then
        self._fm_end = i
        local body = table.concat(self.lines, "\n", 2, i - 1)
        local ok, yaml = pcall(require, "obsidian.yaml")
        if ok then
          local ok2, data = pcall(yaml.loads, body)
          self._fm = (ok2 and type(data) == "table") and data or {}
        else
          self._fm = naive_yaml(vim.list_slice(self.lines, 2, i - 1))
        end
        break
      end
    end
  end
  return self._fm, self._fm_end
end

---All tags, lowercased: frontmatter list + inline #tags (code fences skipped).
---@return {tag: string, lnum: integer}[]
function Note:tags()
  if self._tags then
    return self._tags
  end
  local tags = {}
  local fm, fm_end = self:frontmatter()
  local fm_tags = fm.tags or fm.tag
  if type(fm_tags) == "string" then
    fm_tags = { fm_tags }
  end
  for _, t in ipairs(fm_tags or {}) do
    t = tostring(t):gsub("^#", "")
    local lnum = 1
    for i = 2, fm_end - 1 do
      if self.lines[i]:find(t, 1, true) then
        lnum = i
        break
      end
    end
    tags[#tags + 1] = { tag = t:lower(), lnum = lnum }
  end
  local in_fence = false
  for i = fm_end + 1, #self.lines do
    local l = self.lines[i]
    if l:match("^%s*```") then
      in_fence = not in_fence
    elseif not in_fence then
      for pos, t in l:gmatch("()#([%w_][%w_/%-]*)") do
        local prev = pos > 1 and l:sub(pos - 1, pos - 1) or " "
        -- tag boundary: not preceded by word char (hex colors, urls#anchor),
        -- nor by ( or [ (markdown-link anchors like [Doctorado](#doctorado))
        if not prev:match("[%w&\\%(%[]") and not t:match("^%d+$") then
          tags[#tags + 1] = { tag = t:lower(), lnum = i }
        end
      end
    end
  end
  self._tags = tags
  return tags
end

---Section line ranges: preamble + one per heading (until next heading).
---@return {s: integer, e: integer}[]
function Note:sections()
  if self._sections then
    return self._sections
  end
  local _, fm_end = self:frontmatter()
  local heads = {}
  for i = fm_end + 1, #self.lines do
    if self.lines[i]:match("^#+%s") then
      heads[#heads + 1] = i
    end
  end
  local secs = {}
  local first = heads[1] or (#self.lines + 1)
  if first > fm_end + 1 then
    secs[#secs + 1] = { s = fm_end + 1, e = first - 1 }
  end
  for i, h in ipairs(heads) do
    secs[#secs + 1] = { s = h, e = (heads[i + 1] or #self.lines + 1) - 1 }
  end
  self._sections = secs
  return secs
end

---Block line ranges: runs of non-blank lines outside frontmatter.
function Note:blocks()
  if self._blocks then
    return self._blocks
  end
  local _, fm_end = self:frontmatter()
  local blocks, s = {}, nil
  for i = fm_end + 1, #self.lines + 1 do
    local blank = i > #self.lines or self.lines[i]:match("^%s*$") ~= nil
    if blank and s then
      blocks[#blocks + 1] = { s = s, e = i - 1 }
      s = nil
    elseif not blank and not s then
      s = i
    end
  end
  self._blocks = blocks
  return blocks
end

---@return {lnum: integer, state: string, text: string}[]
function Note:tasks()
  if self._tasks then
    return self._tasks
  end
  local tasks = {}
  for i, l in ipairs(self.lines) do
    for _, pat in ipairs(TASK_PATTERNS) do
      local state, text = l:match(pat)
      if state then
        tasks[#tasks + 1] = { lnum = i, state = state, text = text }
        break
      end
    end
  end
  self._tasks = tasks
  return tasks
end

---------------------------------------------------------------- text matching

local function find_plain(text, term, case)
  local sensitive = case == "sensitive" or (case == "smart" and term:match("%u") ~= nil)
  local hay = sensitive and text or text:lower()
  local needle = sensitive and term or term:lower()
  if needle == "" then
    return 1
  end
  return (hay:find(needle, 1, true))
end

-- shared PCRE-ish -> vim very-magic translator (lookarounds, alternation)
local function get_regex(pat, flags, case)
  local ci = (flags:find("i") ~= nil) or case == "insensitive"
  return require("obsidian-query.regex").compile(pat, ci)
end

-- leaf match over an array of {lnum, text}; returns ok, locs
local function leaf_on_texts(leaf, texts, case)
  local locs = {}
  for _, t in ipairs(texts) do
    local col
    if leaf.k == "regex" then
      local re = get_regex(leaf.pat, leaf.flags, case)
      col = re and re:match_str(t.text)
      col = col and col + 1
    else
      col = find_plain(t.text, leaf.text, case)
    end
    if col then
      locs[#locs + 1] = { lnum = t.lnum, col = col, text = t.text }
    end
  end
  return #locs > 0, locs
end

---------------------------------------------------------------- AST evaluation

local eval_node

-- evaluate expr where textual leaves match against the given texts;
-- structural ops (file/path/tag/prop/...) still see the whole note
local function eval_scoped(ast, note, texts, case)
  if ast.k == "and" then
    local locs = {}
    for _, kid in ipairs(ast.kids) do
      local ok, kl = eval_scoped(kid, note, texts, case)
      if not ok then
        return false, {}
      end
      vim.list_extend(locs, kl)
    end
    return true, locs
  elseif ast.k == "or" then
    local any, locs = false, {}
    for _, kid in ipairs(ast.kids) do
      local ok, kl = eval_scoped(kid, note, texts, case)
      if ok then
        any = true
        vim.list_extend(locs, kl)
      end
    end
    return any, locs
  elseif ast.k == "not" then
    local ok = eval_scoped(ast.kid, note, texts, case)
    return not ok, {}
  elseif ast.k == "word" or ast.k == "phrase" or ast.k == "regex" then
    return leaf_on_texts(ast, texts, case)
  elseif ast.k == "op" and (ast.name == "match-case" or ast.name == "ignore-case") then
    return eval_scoped(ast.arg, note, texts, ast.name == "match-case" and "sensitive" or "insensitive")
  end
  -- structural op nested in a scope: evaluate against the whole note
  return eval_node(ast, note, case)
end

local function content_texts(note)
  if not note._content_texts then
    local ts = {}
    for i, l in ipairs(note.lines) do
      ts[i] = { lnum = i, text = l }
    end
    note._content_texts = ts
  end
  return note._content_texts
end

-- ranges: {s, e}[] -> ok if the sub-expr holds within any single range
local function eval_ranges(arg, note, ranges, case)
  local any, locs = false, {}
  for _, r in ipairs(ranges) do
    local texts = {}
    for i = r.s, r.e do
      texts[#texts + 1] = { lnum = i, text = note.lines[i] }
    end
    local ok, kl = eval_scoped(arg, note, texts, case)
    if ok then
      any = true
      vim.list_extend(locs, kl)
    end
  end
  return any, locs
end

local function has_tag(note, term)
  term = term:lower():gsub("^#", "")
  local locs = {}
  for _, t in ipairs(note:tags()) do
    if t.tag == term or vim.startswith(t.tag, term .. "/") then
      locs[#locs + 1] = { lnum = t.lnum, col = 1, text = note.lines[t.lnum] or "" }
    end
  end
  return #locs > 0, locs
end

-- boolean structure with a custom leaf predicate (tag groups: tag:(#a OR #b))
local function eval_pred(ast, leaffn)
  if ast.k == "and" then
    local locs = {}
    for _, kid in ipairs(ast.kids) do
      local ok, kl = eval_pred(kid, leaffn)
      if not ok then
        return false, {}
      end
      vim.list_extend(locs, kl)
    end
    return true, locs
  elseif ast.k == "or" then
    local any, locs = false, {}
    for _, kid in ipairs(ast.kids) do
      local ok, kl = eval_pred(kid, leaffn)
      if ok then
        any = true
        vim.list_extend(locs, kl)
      end
    end
    return any, locs
  elseif ast.k == "not" then
    local ok = eval_pred(ast.kid, leaffn)
    return not ok, {}
  elseif ast.k == "word" or ast.k == "phrase" then
    return leaffn(ast.text)
  end
  return false, {}
end

local function prop_match(note, name, value)
  local fm = note:frontmatter()
  local v = fm[name] or fm[name:lower()]
  if v == nil then
    return false, {}
  end
  if value == nil or value == "" then
    return true, {}
  end
  local vals = type(v) == "table" and v or { v }
  for _, x in ipairs(vals) do
    if tostring(x):lower():find(value:lower(), 1, true) then
      return true, {}
    end
  end
  return false, {}
end

local function task_texts(note, which)
  local texts = {}
  for _, t in ipairs(note:tasks()) do
    local keep = which == "task"
      or (which == "task-todo" and t.state == " ")
      or (which == "task-done" and t.state ~= " ")
    if keep then
      texts[#texts + 1] = { lnum = t.lnum, text = t.text }
    end
  end
  return texts
end

---@param ast table
---@param note table
---@param case "smart"|"sensitive"|"insensitive"
---@return boolean ok
---@return table locs
eval_node = function(ast, note, case)
  local k = ast.k
  if k == "and" or k == "or" or k == "not" then
    return eval_scoped(ast, note, content_texts(note), case)
  elseif k == "word" or k == "phrase" then
    -- bare terms match content or the filename (Obsidian unions both)
    local ok, locs = leaf_on_texts(ast, content_texts(note), case)
    if ok then
      return true, locs
    end
    return find_plain(note.name, ast.text, case) ~= nil, {}
  elseif k == "regex" then
    return leaf_on_texts(ast, content_texts(note), case)
  elseif k == "prop" then
    return prop_match(note, ast.name, ast.value)
  elseif k == "op" then
    local n, arg = ast.name, ast.arg
    if n == "file" then
      local ok = eval_scoped(arg, note, { { lnum = 1, text = note.name } }, case)
      return ok, {}
    elseif n == "path" then
      local ok = eval_scoped(arg, note, { { lnum = 1, text = note.rel } }, case)
      return ok, {}
    elseif n == "content" then
      return eval_scoped(arg, note, content_texts(note), case)
    elseif n == "tag" then
      return eval_pred(arg, function(term)
        return has_tag(note, term)
      end)
    elseif n == "line" then
      local ranges = {}
      for i = 1, #note.lines do
        ranges[i] = { s = i, e = i }
      end
      return eval_ranges(arg, note, ranges, case)
    elseif n == "section" then
      return eval_ranges(arg, note, note:sections(), case)
    elseif n == "block" then
      return eval_ranges(arg, note, note:blocks(), case)
    elseif n == "task" or n == "task-todo" or n == "task-done" then
      return eval_scoped(arg, note, task_texts(note, n), case)
    elseif n == "match-case" then
      return eval_scoped(arg, note, content_texts(note), "sensitive")
    elseif n == "ignore-case" then
      return eval_scoped(arg, note, content_texts(note), "insensitive")
    end
  end
  return false, {}
end

---@return boolean ok
---@return {lnum: integer, col: integer, text: string}[] locs (sorted, deduped by line)
function M.run(ast, note)
  local ok, locs = eval_node(ast, note, "smart")
  if not ok then
    return false, {}
  end
  table.sort(locs, function(a, b)
    return a.lnum < b.lnum or (a.lnum == b.lnum and a.col < b.col)
  end)
  local seen, out = {}, {}
  for _, l in ipairs(locs) do
    if not seen[l.lnum] then
      seen[l.lnum] = true
      out[#out + 1] = l
    end
  end
  return true, out
end

return M

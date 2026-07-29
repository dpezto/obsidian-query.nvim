-- blink.cmp source for ```query and ```dataview fence bodies.
-- Context-aware: operators/keywords/functions plus live vault data (tags,
-- folders, note names, frontmatter property keys) from the obsidian.nvim cache.
local source = {}

---------------------------------------------------------------- static docs

local QUERY_OPS = {
  { "tag:", "Notes with a tag (frontmatter or inline, nested): `tag:#maestría`" },
  { "path:", "Path contains: `path:Bitacora`" },
  { "file:", "Filename contains: `file:2026-07`" },
  { "content:", "Body text contains (excludes filename): `content:potencia`" },
  { "line:(", "Terms on the same line: `line:(potencia total)`" },
  { "section:(", "Terms under the same heading: `section:(alinear calibrar)`" },
  { "block:(", "Terms in the same paragraph: `block:(potencia bombeo)`" },
  { "task:", "Terms in any checkbox item; `task:()` = any task" },
  { "task-todo:", "Terms in unchecked tasks" },
  { "task-done:", "Terms in checked tasks" },
  { "match-case:(", "Force case-sensitive: `match-case:(MTS)`" },
  { "ignore-case:(", "Force case-insensitive" },
}

local DQL_KEYWORDS = {
  { "TABLE", "Tabular output: `TABLE field1, field2 AS \"Alias\"`" },
  { "TABLE WITHOUT ID", "Table without the File column" },
  { "LIST", "Bulleted note list, optional expression: `LIST file.mtime`" },
  { "TASK", "Query task items instead of notes" },
  { "CALENDAR", "Month grids of dated notes: `CALENDAR file.day`" },
  { "FROM", "Source: `#tag`, `\"folder\"`, `[[note]]`, `outgoing([[note]])`, AND/OR/-" },
  { "WHERE", "Filter rows: `WHERE lang = \"es\" AND priority > 1`" },
  { "SORT", "Order rows: `SORT file.name DESC, priority ASC`" },
  { "GROUP BY", "Bucket rows; each group gets `key` and `rows`" },
  { "FLATTEN", "One row per array element: `FLATTEN file.tags AS t`" },
  { "LIMIT", "Keep first N rows" },
  { "AS", "Alias a column / binding" },
  { "ASC", "Ascending sort" },
  { "DESC", "Descending sort" },
  { "AND", "Both sides truthy" },
  { "OR", "Either side truthy" },
  { "outgoing(", "Pages a note links to: `FROM outgoing([[note]])`" },
  { "this", "The note containing this fence" },
}

local FILE_FIELDS = {
  { "name", "Filename without extension" },
  { "folder", "Vault-relative folder" },
  { "path", "Vault-relative path" },
  { "link", "Link to the note" },
  { "size", "Bytes" },
  { "ctime", "Created (datetime)" },
  { "cday", "Created (date)" },
  { "mtime", "Modified (datetime)" },
  { "mday", "Modified (date)" },
  { "day", "Date from filename or `date` field" },
  { "tags", "All tags, nested prefixes expanded" },
  { "etags", "Tags exactly as written" },
  { "aliases", "Frontmatter aliases" },
  { "tasks", "Checkbox items (with .due, .completed, …)" },
  { "lists", "Alias of tasks" },
  { "inlinks", "Notes linking here" },
  { "outlinks", "Notes this links to" },
  { "frontmatter", "Raw frontmatter table" },
}

-- row-level fields available in TASK queries (tasks are exploded to rows)
local TASK_FIELDS = {
  { "text", "Task text (TASK queries)" },
  { "status", "Raw checkbox char: \" \", \"x\", \"-\", … (TASK queries)" },
  { "checked", "status ~= \" \" (TASK queries)" },
  { "completed", "status is x/X (TASK queries)" },
  { "fullyCompleted", "Completed including all subtasks (TASK queries)" },
  { "line", "1-indexed line in the note (TASK queries)" },
  { "section", "Link to the nearest heading above (TASK queries)" },
  { "due", "Date from [due:: …] or 📅 (TASK queries)" },
  { "completion", "Date from [completion:: …] or ✅ (TASK queries)" },
  { "created", "Date from [created:: …] or ➕ (TASK queries)" },
  { "scheduled", "Date from [scheduled:: …] or ⏳ (TASK queries)" },
  { "start", "Date from [start:: …] or 🛫 (TASK queries)" },
  { "children", "Subtasks (TASK queries)" },
  { "key", "Group key (after GROUP BY)" },
  { "rows", "Group members (after GROUP BY): rows.file.link" },
}

-- one-line signatures for the most-used DQL functions; rest get bare names
local FN_DOCS = {
  contains = "contains(hay, needle) — string/array/object, case-insensitive",
  econtains = "econtains(hay, needle) — exact/case-sensitive contains",
  length = "length(array|string|object)",
  date = "date(2026-07-28) / date(today|now|sow|som|soy…) / date(string)",
  dur = "dur(30 days) / dur(string)",
  default = "default(value, fallback)",
  choice = "choice(cond, a, b)",
  join = 'join(array, sep = ", ")',
  sort = "sort(array, key?)",
  map = "map(array, (x) => …)",
  filter = "filter(array, (x) => …)",
  sum = "sum(array)",
  min = "min(a, b, …) / min(array)",
  max = "max(a, b, …) / max(array)",
  dateformat = 'dateformat(date, "yyyy-MM-dd")',
  striptime = "striptime(date) — drop time component",
  regexmatch = 'regexmatch(string, "\\d+")',
  regexreplace = 'regexreplace(string, pat, rep)',
  flat = "flat(array, depth = 1)",
  unique = "unique(array)",
  any = "any(array, pred?)",
  all = "all(array, pred?)",
}

---------------------------------------------------------------- vault data

local function vault_data()
  local out = { tags = {}, folders = {}, notes = {}, props = {} }
  local ok, cache = pcall(require, "obsidian.cache")
  if not (ok and cache.is_enabled() and cache.is_ready()) then
    return out
  end
  local root = require("obsidian-query").buf_root(vim.api.nvim_get_current_buf())
  if not root then
    return out
  end
  local tags, folders, props = {}, {}, {}
  for path, row in pairs(cache.notes.all()) do
    if vim.startswith(path, root .. "/") then
      local rel = path:sub(#root + 2)
      out.notes[#out.notes + 1] = vim.fn.fnamemodify(rel, ":r")
      local dir = vim.fn.fnamemodify(rel, ":h")
      if dir ~= "." then
        folders[dir] = true
      end
      for _, t in ipairs(row.tags or {}) do
        tags[t] = true
      end
      for k in pairs(row.properties or {}) do
        props[k] = true
      end
    end
  end
  for t in pairs(tags) do
    out.tags[#out.tags + 1] = t
  end
  for f in pairs(folders) do
    out.folders[#out.folders + 1] = f
  end
  for p in pairs(props) do
    out.props[#out.props + 1] = p
  end
  table.sort(out.tags)
  table.sort(out.folders)
  table.sort(out.notes)
  table.sort(out.props)
  return out
end

---------------------------------------------------------------- fence context

---Language of the fence containing `row` (0-based), or nil.
local function fence_lang(buf, row)
  for i = row, math.max(0, row - 200), -1 do
    local line = vim.api.nvim_buf_get_lines(buf, i, i + 1, false)[1] or ""
    local lang = line:match("^%s*```(%S*)")
    if lang then
      if i == row then
        return nil -- cursor on a fence delimiter line
      end
      return (lang == "query" or lang == "dataview") and lang or nil
    end
  end
  return nil
end

---------------------------------------------------------------- items

local function kinds()
  return require("blink.cmp.types").CompletionItemKind
end

local function item(label, kind, doc, insert)
  return {
    label = label,
    kind = kind,
    insertText = insert or label,
    documentation = doc and { kind = "markdown", value = doc } or nil,
  }
end

local function static_items(defs, kind)
  local items = {}
  for _, d in ipairs(defs) do
    items[#items + 1] = item(d[1], kind, d[2])
  end
  return items
end

local function query_items(before)
  local K = kinds()
  local vd = vault_data()
  local _, nquotes = before:gsub('"', "")
  if nquotes % 2 == 1 then
    return {} -- inside a "phrase"
  end
  if before:match("tag:#?[%w_/%-]*$") then
    return vim.tbl_map(function(t)
      return item(t, K.Enum, "vault tag")
    end, vd.tags)
  elseif before:match("path:%S*$") then
    return vim.tbl_map(function(f)
      return item(f, K.Folder)
    end, vd.folders)
  elseif before:match("file:%S*$") then
    return vim.tbl_map(function(n)
      return item(vim.fn.fnamemodify(n, ":t"), K.File)
    end, vd.notes)
  elseif before:match("%[[%w%s%-]*$") then
    return vim.tbl_map(function(p)
      return item(p, K.Property, "frontmatter property; `[" .. p .. ":value]` to match a value")
    end, vd.props)
  end
  return static_items(QUERY_OPS, K.Keyword)
end

local function dataview_items(before)
  local K = kinds()
  local vd = vault_data()
  -- inside an open string? (odd number of quotes before cursor — a closed
  -- `FROM "x"` earlier in the line must NOT hijack later completions)
  local _, nquotes = before:gsub('"', "")
  if nquotes % 2 == 1 then
    if before:match("[Ff][Rr][Oo][Mm]") then
      return vim.tbl_map(function(f)
        return item(f, K.Folder)
      end, vd.folders)
    end
    return {} -- plain string literal: nothing to offer
  end
  if before:match("%[%[[^%]]*$") then
    return vim.tbl_map(function(n)
      return item(vim.fn.fnamemodify(n, ":t"), K.File, nil, vim.fn.fnamemodify(n, ":t"))
    end, vd.notes)
  elseif before:match("#[%w_/%-]*$") then
    return vim.tbl_map(function(t)
      return item(t, K.Enum, "vault tag")
    end, vd.tags)
  elseif before:match("file%.[%w]*$") then
    return static_items(FILE_FIELDS, K.Field)
  end
  local items = static_items(DQL_KEYWORDS, K.Keyword)
  vim.list_extend(items, static_items(TASK_FIELDS, K.Field))
  items[#items + 1] = item("file", K.Field, "Implicit note metadata: file.name, file.mtime, file.tags, …")
  for name in pairs(require("obsidian-query.dataview.functions").registry) do
    items[#items + 1] = item(name, K.Function, FN_DOCS[name], name .. "(")
  end
  for _, p in ipairs(vd.props) do
    items[#items + 1] = item(p, K.Property, "frontmatter property")
  end
  return items
end

---------------------------------------------------------------- blink source

function source.new(opts)
  return setmetatable(opts or {}, { __index = source })
end

function source:enabled()
  return vim.bo.filetype == "markdown"
end

function source:get_trigger_characters()
  return { ":", "#", "[", '"', ".", "(" }
end

function source:get_completions(ctx, callback)
  local row = ctx.cursor[1] - 1
  local lang = fence_lang(ctx.bufnr, row)
  if not lang then
    callback({ items = {}, is_incomplete_backward = false, is_incomplete_forward = false })
    return function() end
  end
  local before = ctx.line:sub(1, ctx.cursor[2])
  local items = lang == "query" and query_items(before) or dataview_items(before)
  callback({
    items = items,
    is_incomplete_backward = false,
    -- context decides the item set, so re-query as the prefix grows
    is_incomplete_forward = true,
  })
  return function() end
end

return source

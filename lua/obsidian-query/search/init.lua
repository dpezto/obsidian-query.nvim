-- Engine for Obsidian core-Search ```query fences.
-- Engine interface (consumed by obsidian-query.init):
--   parse(body) -> spec|nil        key(spec, ctx) -> string|nil
--   run(spec, ctx, cb(result))     lines(result) -> virt_lines
--   pick(spec, ctx, result)
local parser = require("obsidian-query.search.parser")
local eval = require("obsidian-query.search.eval")
local base = require("obsidian-query.render")

local M = {}

local BATCH = 25 -- files evaluated per event-loop tick
local MAX_MATCH_LINES = 3 -- matched lines shown per note inline
local max_notes = require("obsidian-query.config").max_rows
local parsed = setmetatable({}, { __mode = "v" })

function M.parse(body)
  body = vim.trim(body)
  if body == "" then
    return nil
  end
  local ast, err = parsed[body], nil
  if not ast then
    ast, err = parser.parse(body)
  end
  if not ast then
    return { body = body, error = err }
  end
  parsed[body] = ast
  return { body = body, ast = ast, has_content = parser.has_content(ast) }
end

function M.key(spec, ctx)
  return "query\0" .. ctx.root .. "\0" .. (ctx.buf or "") .. "\0" .. spec.body
end

-- Obsidian sorts basenames with a case-insensitive numeric collator.
function M.less(a, b)
  local x, y = vim.fn.tolower(vim.fn.fnamemodify(a, ":t:r")), vim.fn.tolower(vim.fn.fnamemodify(b, ":t:r"))
  while x ~= "" and y ~= "" do
    local nx, ny = x:match("^%d+"), y:match("^%d+")
    if nx and ny then
      local vx, vy = nx:gsub("^0+", ""), ny:gsub("^0+", "")
      if #vx ~= #vy then
        return #vx < #vy
      end
      if vx ~= vy then
        return vx < vy
      end
      x, y = x:sub(#nx + 1), y:sub(#ny + 1)
    else
      local cx, cy = vim.fn.strcharpart(x, 0, 1), vim.fn.strcharpart(y, 0, 1)
      if cx ~= cy then
        return cx < cy
      end
      x, y = x:sub(#cx + 1), y:sub(#cy + 1)
    end
  end
  if x ~= y then
    return x == ""
  end
  return a < b
end

function M.context(match)
  local text, col = match.text, match.col or 1
  local before = vim.fn.strchars(text:sub(1, col - 1))
  local ending = vim.fn.strchars(text:sub(1, (match.end_col or col + 1) - 1))
  local first = math.max(0, before - 100)
  local last = math.min(vim.fn.strchars(text), ending + 100)
  return (first > 0 and "…" or "")
    .. vim.trim(vim.fn.strcharpart(text, first, last - first))
    .. (last < vim.fn.strchars(text) and "…" or "")
end

function M.contexts(match)
  local spans = {}
  for _, range in ipairs(match.ranges or { { match.col or 1, match.end_col or match.col or 1 } }) do
    local last = spans[#spans]
    if last and vim.fn.strchars(match.text:sub(last.end_col, range[1] - 1)) <= 200 then
      last.end_col = math.max(last.end_col, range[2])
    else
      spans[#spans + 1] = { text = match.text, col = range[1], end_col = range[2] }
    end
  end
  return vim.tbl_map(M.context, spans)
end

local content_cache = {}

-- Positive literals are necessary conditions; bare terms can also match filenames.
local function required_content(ast)
  local leaf, filename
  if ast.k == "word" or ast.k == "phrase" then
    leaf, filename = ast, true
  elseif
    ast.k == "op"
    and vim.tbl_contains({ "content", "line", "section", "block", "task", "task-todo", "task-done" }, ast.name)
  then
    if ast.arg.k == "word" or ast.arg.k == "phrase" then
      leaf = ast.arg
    end
  elseif ast.k == "and" then
    for _, kid in ipairs(ast.kids) do
      local term = required_content(kid)
      if term then
        return term
      end
    end
  end
  if leaf and leaf.text ~= "" and not leaf.text:find("[\128-\255\r\n]") then
    return { text = leaf.text, filename = filename }
  end
end

local function cached_note(path, root)
  local st = vim.uv.fs_stat(path)
  if not st then
    content_cache[path] = nil
    return nil
  end
  local stamp = table.concat({ st.mtime.sec, st.mtime.nsec, st.size }, ":")
  local hit = content_cache[path]
  if hit and hit.stamp == stamp then
    return hit
  end
  local content = ""
  if path:sub(-3) == ".md" then
    local fd = io.open(path, "r")
    if not fd then
      return nil
    end
    content = fd:read("*a")
    fd:close()
  end
  hit = {
    stamp = stamp,
    content = content,
    note = eval.note(path, vim.fs.relpath(root, path) or path, content),
    results = setmetatable({}, { __mode = "k" }),
  }
  content_cache[path] = hit
  return hit
end

local function origin_note(hit)
  if not hit.origin then
    local function blank(text)
      return (text:gsub("[^\n]", " "))
    end
    local content = hit.content:gsub("```query.-```", blank)
    local start = content:find("```query", 1, true)
    if start then
      content = content:sub(1, start - 1) .. blank(content:sub(start))
    end
    hit.origin = eval.note(hit.note.path, hit.note.rel, content)
  end
  return hit.origin
end

---Reuse file contents and AST results until the file's full timestamp changes.
function M.run(spec, ctx, cb)
  if spec.error then
    cb({ error = spec.error })
    return
  end
  local this_path = ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf) and vim.api.nvim_buf_get_name(ctx.buf)
  if this_path then
    local rel = vim.fs.relpath(vim.uv.fs_realpath(ctx.root) or ctx.root, vim.uv.fs_realpath(this_path) or this_path)
    this_path = rel and (ctx.root .. "/" .. rel) or nil
  end
  vim.system({ "rg", "--files", "--no-ignore", "-0", ctx.root }, {}, function(out)
    if out.code > 1 then
      vim.schedule(function()
        cb({ error = vim.trim(out.stderr or "ripgrep failed") })
      end)
      return
    end
    local paths = vim.split(out.stdout or "", "\0", { plain = true, trimempty = true })
    table.sort(paths, M.less)
    local function evaluate(candidates)
      local files, total, i = {}, 0, 1
      local present = {}
      for _, path in ipairs(paths) do
        present[path] = true
      end
      for path in pairs(content_cache) do
        if vim.startswith(path, ctx.root .. "/") and not present[path] then
          content_cache[path] = nil
        end
      end
      local function step()
        local stop = math.min(i + BATCH - 1, #paths)
        while i <= stop do
          local path = paths[i]
          i = i + 1
          if not candidates or candidates[path] then
            local hit = cached_note(path, ctx.root)
            if hit then
              local own = path == this_path
              local key = own and "origin" or "saved"
              local results = hit.results[spec.ast] or {}
              hit.results[spec.ast] = results
              local result = results[key]
              if not result then
                local ok, locs, label = eval.run(spec.ast, own and origin_note(hit) or hit.note)
                result = { ok = ok, locs = locs, label = label }
                results[key] = result
              end
              if result.ok then
                files[#files + 1] = { path = path, matches = result.locs, label = result.label }
                for _, loc in ipairs(result.locs) do
                  total = total + #(loc.ranges or { loc })
                end
              end
            end
          end
        end
        if i <= #paths then
          vim.schedule(step)
        else
          cb({ files = files, total = total, has_content = spec.has_content })
        end
      end
      vim.schedule(step)
    end
    local term = required_content(spec.ast)
    if not term then
      evaluate()
      return
    end
    vim.system(
      { "rg", "-l", "--no-ignore", "-0", "-i", "-F", "--glob", "*.md", "--", term.text, ctx.root },
      {},
      function(filtered)
        local candidates
        if filtered.code <= 1 then
          candidates = {}
          for _, path in ipairs(vim.split(filtered.stdout or "", "\0", { plain = true, trimempty = true })) do
            candidates[path] = true
          end
        end
        if candidates and term.filename then
          for _, path in ipairs(paths) do
            if vim.fn.tolower(vim.fn.fnamemodify(path, ":t")):find(term.text:lower(), 1, true) then
              candidates[path] = true
            end
          end
        end
        evaluate(candidates)
      end
    )
  end)
end

function M.lines(result)
  if result.error then
    return { { { "▏ query: " .. result.error, "DiagnosticError" } } }
  end
  -- structural queries (tag/path/prop only) render one line per note;
  -- content-bearing queries also show their matched lines
  local lines = {}
  for fi = 1, math.min(#result.files, max_notes()) do
    local f = result.files[fi]
    lines[#lines + 1] = {
      { "▏ ", "RenderMarkdownBullet" },
      { f.label or eval.label(f.path), "RenderMarkdownLink" },
    }
    local snippets = {}
    for _, match in ipairs(f.matches) do
      vim.list_extend(snippets, M.contexts(match))
    end
    for j = 1, math.min(#snippets, MAX_MATCH_LINES) do
      lines[#lines + 1] = { { "▏   · ", "RenderMarkdownBullet" }, { snippets[j], "Comment" } }
    end
    if #snippets > MAX_MATCH_LINES then
      lines[#lines + 1] = { { "▏     +" .. (#snippets - MAX_MATCH_LINES) .. " more", "NonText" } }
    end
  end
  if #result.files > max_notes() then
    lines[#lines + 1] = {
      { "▏ ", "RenderMarkdownBullet" },
      {
        ("+%d more notes — %sfor all"):format(
          #result.files - max_notes(),
          require("obsidian-query.render").key("<CR>")
        ),
        "NonText",
      },
    }
  end
  local tail = ("%d notes"):format(#result.files)
  if result.total and result.total > 0 then
    tail = tail .. (", %d matches"):format(result.total)
  end
  lines[#lines + 1] = { { "▏ ", "RenderMarkdownBullet" }, { tail, "Comment" } }
  return lines
end

function M.pick(spec, _, result)
  if result.error or not result.files then
    return
  end
  local items = {}
  for _, f in ipairs(result.files) do
    local name = f.label or eval.label(f.path)
    if #f.matches == 0 then
      items[#items + 1] = {
        file = f.path,
        text = name,
        display = { { name, "Directory" } },
      }
    else
      for _, m in ipairs(f.matches) do
        local text = vim.trim(m.text)
        items[#items + 1] = {
          file = f.path,
          text = name .. " " .. text,
          pos = { m.lnum, m.col - 1 },
          display = { { name, "Directory" }, { "  " }, { text, "Comment" } },
        }
      end
    end
  end
  local q = base.clip((spec.body:gsub("%s+", " ")), 30)
  base.picker(("Search · %s (%d)"):format(q, #items), items)
end

return M

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

function M.parse(body)
  body = vim.trim(body)
  if body == "" then
    return nil
  end
  local ast, err = parser.parse(body)
  if not ast then
    return { body = body, error = err }
  end
  return { body = body, ast = ast, has_content = parser.has_content(ast) }
end

function M.key(spec, ctx)
  return "query\0" .. ctx.root .. "\0" .. spec.body
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

---Evaluate every vault note against the AST, chunked to keep the UI live.
-- ponytail: reads all .md files per run; rg-prefilter candidates if a vault
-- ever grows past a few thousand notes
function M.run(spec, ctx, cb)
  if spec.error then
    cb({ error = spec.error })
    return
  end
  vim.system({ "rg", "--files", ctx.root }, { text = true }, function(out)
    local paths = vim.split(out.stdout or "", "\n", { trimempty = true })
    table.sort(paths, M.less)
    local files, total, i = {}, 0, 1
    local function step()
      local stop = math.min(i + BATCH - 1, #paths)
      while i <= stop do
        local path = paths[i]
        i = i + 1
        -- attachments are matchable by path/filename only, so never read them
        local content = ""
        if path:sub(-3) == ".md" then
          local fd = io.open(path, "r")
          if fd then
            content = fd:read("*a")
            fd:close()
          end
        end
        local rel = vim.fs.relpath(ctx.root, path) or path
        local ok, locs = eval.run(spec.ast, eval.note(path, rel, content))
        if ok then
          files[#files + 1] = { path = path, matches = locs }
          total = total + #locs
        end
      end
      if i <= #paths then
        vim.schedule(step)
      else
        cb({ files = files, total = total, has_content = spec.has_content })
      end
    end
    vim.schedule(step)
  end)
end

function M.lines(result)
  if result.error then
    return { { { "▏ query: " .. result.error, "DiagnosticError" } } }
  end
  -- structural queries (tag/path/prop only) render one line per note;
  -- content-bearing queries also show their matched lines
  local lines, show_matches = {}, result.has_content
  for fi = 1, math.min(#result.files, max_notes()) do
    local f = result.files[fi]
    lines[#lines + 1] = {
      { "▏ ", "RenderMarkdownBullet" },
      { eval.label(f.path), "RenderMarkdownLink" },
    }
    if show_matches then
      for j = 1, math.min(#f.matches, MAX_MATCH_LINES) do
        lines[#lines + 1] = {
          { "▏   · ", "RenderMarkdownBullet" },
          { M.context(f.matches[j]), "Comment" },
        }
      end
      if #f.matches > MAX_MATCH_LINES then
        lines[#lines + 1] = {
          { "▏     +" .. (#f.matches - MAX_MATCH_LINES) .. " more", "NonText" },
        }
      end
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
  if result.total and result.total > 0 and show_matches then
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
    local name = eval.label(f.path)
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

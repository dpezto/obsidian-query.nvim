-- Engine for ```dataview fences (same interface as obsidian-query.search).
local query = require("obsidian-query.dataview.query")
local dv_render = require("obsidian-query.dataview.render")
local value = require("obsidian-query.dataview.value")
local base = require("obsidian-query.render")

local M = {}

function M.parse(body)
  body = vim.trim(body)
  if body == "" then
    return nil
  end
  return { body = body }
end

function M.key(spec, ctx)
  return "dataview\0" .. ctx.root .. "\0" .. spec.body
end

function M.run(spec, ctx, cb)
  require("obsidian-query.index").get(ctx, function(idx, err, transient)
    if not idx then
      -- transient (vault not active): cb(nil) keeps the previous render
      cb(not transient and { ok = false, phase = "index", msg = err or "index unavailable" } or nil)
      return
    end
    local this_path = ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf) and vim.api.nvim_buf_get_name(ctx.buf) or nil
    cb(query.run(spec.body, {
      index = idx.rows,
      root = ctx.root,
      sup = idx.sup,
      inlinks = idx.inlinks,
      starred = idx.starred,
      this_path = this_path,
    }))
  end)
end

M.lines = dv_render.lines

local function note_name(path)
  return vim.fn.fnamemodify(path, ":t:r")
end

-- Short readable FROM source for the picker title.
-- ponytail: leaf sources only; combinators (and/or/not) are too long to fit
local function source_label(src)
  local s ---@type string?
  if src.k == "s_tag" then
    s = "#" .. src.tag
  elseif src.k == "s_folder" then
    s = '"' .. src.folder .. '"'
  elseif src.k == "s_csv" then
    s = src.path
  elseif src.k == "s_link" then
    s = "[[" .. src.raw .. "]]"
  elseif src.k == "s_outgoing" then
    s = "outgoing([[" .. src.raw .. "]])"
  end
  return s and base.clip(s, 30)
end

local open_items = base.picker

function M.pick(spec, ctx, result)
  if not result.ok then
    return
  end
  local data = result.data
  local items = {}
  if data.kind == "table" then
    for _, row in ipairs(data.rows) do
      if row.path ~= "" then
        local parts = {}
        for _, c in ipairs(row.cells) do
          parts[#parts + 1] = value.to_display(c)
        end
        local cells = table.concat(parts, " · ")
        local id = value.to_display(row.id)
        items[#items + 1] = {
          file = row.path,
          text = id .. " " .. cells,
          display = { { id, "Directory" }, { "  " }, { cells, "Comment" } },
        }
      end
    end
  elseif data.kind == "list" then
    for _, group in ipairs(data.groups) do
      for _, item in ipairs(group.items) do
        if item.path ~= "" then
          local label = value.to_display(item.link or item.text)
          local extra = item.link and item.text and value.to_display(item.text) or ""
          items[#items + 1] = {
            file = item.path,
            text = label .. " " .. extra,
            display = { { label, "Directory" }, { "  " }, { extra, "Comment" } },
          }
        end
      end
    end
  elseif data.kind == "task" then
    for _, group in ipairs(data.groups) do
      for _, task in ipairs(group.items) do
        items[#items + 1] = {
          file = task.path,
          text = note_name(task.path) .. " " .. task.text,
          pos = { task.line, 0 },
          display = {
            { note_name(task.path), "Directory" },
            { "  " },
            { task.completed and "󰄲 " or "󰄱 ", task.completed and "Comment" or "Special" },
            { task.text, task.completed and "Comment" or "Normal" },
          },
        }
      end
    end
  elseif data.kind == "calendar" then
    for _, d in ipairs(data.dated) do
      if d.path ~= "" then
        local date = value.to_display(d.date)
        items[#items + 1] = {
          file = d.path,
          text = date .. " " .. note_name(d.path),
          display = { { date, "Number" }, { "  " }, { note_name(d.path), "Directory" } },
        }
      end
    end
  end
  local label = data.from and source_label(data.from)
  local title = data.kind:upper() .. (label and (" · " .. label) or "")
  open_items(("%s (%d)"):format(title, #items), items)
end

---Shift a calendar's shown month (<Left>/<Right>); no-op for other results.
---@param delta integer? months to move; nil jumps back to the current month
---@return boolean handled
function M.shift(result, delta)
  if not (result.ok and result.data.kind == "calendar") then
    return false
  end
  result.view = delta and (result.view or 0) + delta or 0
  return true
end

---Click on a calendar: the header arrows change month, the month label
---jumps back to today, a day cell opens a picker of that day's notes.
---@return boolean handled
function M.click(result, vidx, col)
  local map = result.ok and result.data._clickmap
  local cells = map and map[vidx]
  if not cells then
    return false
  end
  for _, cell in ipairs(cells) do
    if (cell.shift or cell.today) and col >= cell.s and col <= cell.e then
      return M.shift(result, cell.shift) -- month label: shift nil -> today
    end
    if col >= cell.s and col <= cell.e and cell.paths and #cell.paths > 0 then
      local items = {}
      for _, p in ipairs(cell.paths) do
        items[#items + 1] = {
          file = p,
          text = note_name(p),
          display = { { note_name(p), "Directory" } },
        }
      end
      open_items("Notes · " .. cell.date, items)
      return true
    end
  end
  return false
end

return M

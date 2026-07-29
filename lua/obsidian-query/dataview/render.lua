-- virt_lines rendering for DQL results (table/list/task/error).
local value = require("obsidian-query.dataview.value")

local M = {}

local MAX_COL = 40
-- j/k can't enter virtual lines, so a tall block scrolls past in one jump;
-- cap inline rows and push the full set to the <CR> picker
-- optional inline row cap (opts.max_inline_rows); unlimited by default
local function max_rows()
  return require("obsidian-query.config").opts.max_inline_rows or math.huge
end
local BAR = { "▏ ", "RenderMarkdownBullet" }

local function more_line(n, what)
  return { BAR, { ("+%d more %s — <CR> for all"):format(n, what), "NonText" } }
end

local function width(s)
  return vim.fn.strdisplaywidth(s)
end

local function clip(s)
  if width(s) <= MAX_COL then
    return s
  end
  return vim.fn.strcharpart(s, 0, MAX_COL - 1) .. "…"
end

local function pad(s, w)
  return s .. string.rep(" ", w - width(s))
end

local function cell_hl(v)
  return value.typeof(v) == "link" and "RenderMarkdownLink" or "RenderMarkdownTableRow"
end

function M.table_lines(data)
  local cols = #data.columns
  local widths = {}
  for i, c in ipairs(data.columns) do
    widths[i] = width(clip(c))
  end
  local display = {}
  for r = 1, math.min(#data.rows, max_rows()) do
    local row = data.rows[r]
    local cells = {}
    if data.with_id then
      cells[1] = { clip(value.to_display(row.id)), cell_hl(row.id) }
    end
    for _, cell in ipairs(row.cells) do
      cells[#cells + 1] = { clip(value.to_display(cell)), cell_hl(cell) }
    end
    for i = 1, cols do
      cells[i] = cells[i] or { "", "RenderMarkdownTableRow" }
      widths[i] = math.max(widths[i] or 0, width(cells[i][1]))
    end
    display[r] = cells
  end

  local function rule(l, mid, r)
    local parts = {}
    for i = 1, cols do
      parts[i] = string.rep("─", (widths[i] or 0) + 2)
    end
    return l .. table.concat(parts, mid) .. r
  end

  local lines = {}
  lines[#lines + 1] = { BAR, { rule("╭", "┬", "╮"), "RenderMarkdownTableHead" } }
  local head = { BAR, { "│ ", "RenderMarkdownTableHead" } }
  for i, c in ipairs(data.columns) do
    head[#head + 1] = { pad(clip(c), widths[i]), "RenderMarkdownTableHead" }
    head[#head + 1] = { i < cols and " │ " or " │", "RenderMarkdownTableHead" }
  end
  lines[#lines + 1] = head
  lines[#lines + 1] = { BAR, { rule("├", "┼", "┤"), "RenderMarkdownTableHead" } }
  for _, cells in ipairs(display) do
    local line = { BAR, { "│ ", "RenderMarkdownTableRow" } }
    for i = 1, cols do
      line[#line + 1] = { pad(cells[i][1], widths[i]), cells[i][2] }
      line[#line + 1] = { i < cols and " │ " or " │", "RenderMarkdownTableRow" }
    end
    lines[#lines + 1] = line
  end
  lines[#lines + 1] = { BAR, { rule("╰", "┴", "╯"), "RenderMarkdownTableHead" } }
  if #data.rows > max_rows() then
    lines[#lines + 1] = more_line(#data.rows - max_rows(), "rows")
  end
  lines[#lines + 1] = { BAR, { ("%d rows"):format(#data.rows), "Comment" } }
  return lines
end

function M.list_lines(data)
  local lines, total, shown = {}, 0, 0
  for _, group in ipairs(data.groups) do
    total = total + #group.items
  end
  for _, group in ipairs(data.groups) do
    if shown >= max_rows() then
      break
    end
    if group.key ~= nil then
      lines[#lines + 1] = { BAR, { value.to_display(group.key), "RenderMarkdownH2" } }
    end
    for _, item in ipairs(group.items) do
      if shown >= max_rows() then
        break
      end
      shown = shown + 1
      local line = { BAR }
      if group.key ~= nil then
        line[#line + 1] = { "  ", "Comment" }
      end
      local has_link = item.link ~= nil and value.typeof(item.link) == "link"
      if has_link then
        line[#line + 1] = { value.to_display(item.link), "RenderMarkdownLink" }
      end
      if item.text ~= nil and value.typeof(item.text) ~= "null" then
        if has_link then
          line[#line + 1] = { ": ", "Comment" }
        end
        line[#line + 1] = { value.to_display(item.text), "RenderMarkdownTableRow" }
      end
      lines[#lines + 1] = line
    end
  end
  if total > shown then
    lines[#lines + 1] = more_line(total - shown, "results")
  end
  lines[#lines + 1] = { BAR, { ("%d results"):format(total), "Comment" } }
  return lines
end

function M.task_lines(data)
  local lines, total, shown = {}, 0, 0
  for _, group in ipairs(data.groups) do
    total = total + #group.items
  end
  for _, group in ipairs(data.groups) do
    if shown >= max_rows() then
      break
    end
    lines[#lines + 1] = { BAR, { value.to_display(group.key), "RenderMarkdownH2" } }
    for _, task in ipairs(group.items) do
      if shown >= max_rows() then
        break
      end
      shown = shown + 1
      local box = task.completed and "󰄲 " or "󰄱 "
      local hl = task.completed and "RenderMarkdownChecked" or "RenderMarkdownUnchecked"
      lines[#lines + 1] = {
        BAR,
        { string.rep("  ", math.min(task.indent and math.floor(task.indent / 2) or 0, 4) + 1) },
        { box, hl },
        { task.text, task.completed and "@markup.strikethrough" or "RenderMarkdownTableRow" },
      }
    end
  end
  if total > shown then
    lines[#lines + 1] = more_line(total - shown, "tasks")
  end
  lines[#lines + 1] = { BAR, { ("%d tasks"):format(total), "Comment" } }
  return lines
end

local MONTHS = {
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
}
local GRID_W = 7 * 3 -- Mo..Su, each day cell 3 display cols wide

---Dataview shows one month at a time, opening on the current month;
---`view` is that month's offset, moved by <Left>/<Right> (see M.shift).
---@param data table calendar result
---@param view integer? months from today (0 = current month)
function M.calendar_lines(data, view)
  local lines = {}
  -- clickmap: virt-line index -> day cells {s, e (1-based display cols), paths}
  -- consumed by the <LeftMouse> handler to open a per-day picker
  local clickmap = {}
  data._clickmap = clickmap
  local today = data.today or os.date("*t")
  -- os.time normalises month over/underflow, so any offset is a valid month
  local base = os.date("*t", os.time({ year = today.year, month = today.month + (view or 0), day = 1 }))
  local m = { year = base.year, month = base.month, days = {} }
  for _, bucket in ipairs(data.months) do
    if bucket.year == base.year and bucket.month == base.month then
      m = bucket
      break
    end
  end
  -- header spans the grid (7 day cells, 3 cols each) with the arrows pinned
  -- to its edges and the label centred, so the click targets never move as
  -- the month changes; "▏ " = 2 display cols before it
  local label = ("%s %d"):format(MONTHS[m.month], m.year)
  local inner = math.max(GRID_W - 2 - width(label), 0)
  local lpad = math.floor(inner / 2)
  lines[#lines + 1] = {
    BAR,
    { "‹", "RenderMarkdownH2" },
    { string.rep(" ", lpad) .. label .. string.rep(" ", inner - lpad), "RenderMarkdownH2" },
    { "›", "RenderMarkdownH2" },
  }
  clickmap[1] = {
    { s = 3, e = 3, shift = -1 },
    { s = 4, e = 2 + GRID_W - 1, today = true },
    { s = 2 + GRID_W, e = 2 + GRID_W, shift = 1 },
  }
  lines[#lines + 1] = { BAR, { "Mo Tu We Th Fr Sa Su", "Comment" } }
  local first_wd = (os.date("*t", os.time({ year = m.year, month = m.month, day = 1 })).wday + 5) % 7 -- 0 = Monday
  local ndays = os.date("*t", os.time({ year = m.year, month = m.month + 1, day = 0 })).day
  local row, cells, cellmap = { BAR }, 0, {}
  for _ = 1, first_wd do
    row[#row + 1] = { "   " }
    cells = cells + 1
  end
  local n_month = 0
  for day = 1, ndays do
    local hit = m.days[day]
    local is_today = today.year == m.year and today.month == m.month and today.day == day
    row[#row + 1] = {
      ("%2d%s"):format(day, hit and "•" or " "),
      is_today and "Special" or (hit and "RenderMarkdownLink" or "Comment"),
    }
    if hit then
      n_month = n_month + #hit
      -- "▏ " = 2 display cols, each cell 3 wide
      cellmap[#cellmap + 1] = {
        s = 2 + cells * 3 + 1,
        e = 2 + (cells + 1) * 3,
        paths = hit,
        date = ("%04d-%02d-%02d"):format(m.year, m.month, day),
      }
    end
    cells = cells + 1
    if (first_wd + day) % 7 == 0 or day == ndays then
      lines[#lines + 1] = row
      if #cellmap > 0 then
        clickmap[#lines] = cellmap
      end
      row, cells, cellmap = { BAR }, 0, {}
    end
  end
  lines[#lines + 1] = {
    BAR,
    { ("%d this month · %d dated notes"):format(n_month, #data.dated), "Comment" },
    { "  <Left>/<Right> month · <Home> today", "NonText" },
  }
  return lines
end

function M.error_line(prefix, msg)
  return { { { "▏ " .. prefix .. ": " .. msg, "DiagnosticError" } } }
end

function M.lines(result)
  if not result.ok then
    return M.error_line("dataview " .. (result.phase or "error"), result.msg or "?")
  end
  local data = result.data
  if data.kind == "table" then
    return M.table_lines(data)
  elseif data.kind == "list" then
    return M.list_lines(data)
  elseif data.kind == "task" then
    return M.task_lines(data)
  elseif data.kind == "calendar" then
    return M.calendar_lines(data, result.view)
  end
  return M.error_line("dataview", "unsupported result: " .. tostring(data.kind))
end

return M

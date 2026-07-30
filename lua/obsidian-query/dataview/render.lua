-- virt_lines rendering for DQL results (table/list/task/error).
local value = require("obsidian-query.dataview.value")

local M = {}

local MAX_COL = 40
-- j/k can't enter virtual lines, so a tall block scrolls past in one jump;
-- cap inline rows and push the full set to the <CR> picker
local max_rows = require("obsidian-query.config").max_rows
local BAR = { "▏ ", "RenderMarkdownBullet" }

local base = require("obsidian-query.render")
local key = base.key

local function more_line(n, what)
	return { BAR, { ("+%d more %s — %sfor all"):format(n, what, key("<CR>")), "NonText" } }
end

local function width(s)
	return vim.fn.strdisplaywidth(s)
end

local function clip(s)
	return base.clip(s, MAX_COL)
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
			local box = base.checkbox(task.status)
			lines[#lines + 1] = {
				BAR,
				{ string.rep("  ", math.min(task.indent and math.floor(task.indent / 2) or 0, 4) + 1) },
				{ box.icon, box.highlight },
				{ task.text, box.scope_highlight or "RenderMarkdownTableRow" },
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
	"January",
	"February",
	"March",
	"April",
	"May",
	"June",
	"July",
	"August",
	"September",
	"October",
	"November",
	"December",
}
local GRID_W = 7 * 3 -- Mo..Su, each day cell 3 display cols wide

-- Day cells are heat-mapped by note count over the month on screen: brighter
-- = more notes, and a month whose days all hold the same count collapses to
-- the ramp's first colour. The ramp lists anchors; HEAT_STEPS colours are
-- interpolated across them, so the scale reads as a continuous spectrum.
local HEAT_RAMP = { "#000004", "#1c1044", "#4f127b", "#812581", "#b5367a", "#e55964", "#fb8761", "#fec287", "#fbfdbf" }
local HEAT_STEPS = 24
local HEAT_MIN_CONTRAST = 3 -- contrast floor vs Normal bg for day cells
M.HEAT_MIN_CONTRAST = HEAT_MIN_CONTRAST

local function rgb(hex)
	local n = tonumber(hex:sub(2), 16)
	return math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256
end

---Blend two colours in sRGB; `t` = 0 is `a`, 1 is `b`.
local function mix(a, b, t)
	local r1, g1, b1 = rgb(a)
	local r2, g2, b2 = rgb(b)
	return ("#%02x%02x%02x"):format(
		math.floor(r1 + (r2 - r1) * t + 0.5),
		math.floor(g1 + (g2 - g1) * t + 0.5),
		math.floor(b1 + (b2 - b1) * t + 0.5)
	)
end

---Colour `t` of the way (0..1) along the ramp.
local function sample(ramp, t)
	if #ramp == 1 then
		return ramp[1]
	end
	local x = t * (#ramp - 1) + 1
	local i = math.min(math.floor(x), #ramp - 1)
	return mix(ramp[i], ramp[i + 1], x - i)
end

---The heat ramp at `t` (0..1); `ramp` defaults to the full palette. Test seam.
function M.sample_heat(t, ramp)
	return sample(ramp or HEAT_RAMP, t)
end

---WCAG relative luminance.
local function luminance(hex)
	local lin = {}
	for i, c in ipairs({ rgb(hex) }) do
		c = c / 255
		lin[i] = c <= 0.03928 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
	end
	return 0.2126 * lin[1] + 0.7152 * lin[2] + 0.0722 * lin[3]
end

local function contrast(a, b)
	local la, lb = luminance(a), luminance(b)
	local hi, lo = math.max(la, lb), math.min(la, lb)
	return (hi + 0.05) / (lo + 0.05)
end

---The ramp is fixed but the colorscheme's background is not, so keep the
---longest stretch of the *continuous* ramp that clears HEAT_MIN_CONTRAST: a
---dark background loses the near-black end, a light one the near-white end.
---The cut is by luma (WCAG contrast is a pure function of relative luminance)
---and lands exactly where the curve crosses the floor — the boundary colour is
---synthesised by interpolation, interior anchors are kept verbatim. A passing
---stretch can never straddle the background's own luminance (contrast dips to
---1 there), so no explicit side check is needed.
---@param bg string
---@return string[] anchors
function M.usable_ramp(bg)
	local N = 96 -- scan resolution along the curve
	local function passes(t)
		return contrast(sample(HEAT_RAMP, t), bg) >= HEAT_MIN_CONTRAST
	end
	-- longest contiguous passing run, in curve parameter t
	local best_lo, best_hi, run_lo
	for i = 0, N do
		local t = i / N
		if passes(t) then
			run_lo = run_lo or t
			if not best_lo or t - run_lo > best_hi - best_lo then
				best_lo, best_hi = run_lo, t
			end
		else
			run_lo = nil
		end
	end
	if not best_lo then
		-- nothing clears the floor (mid grey vs a low-contrast ramp): fall back
		-- to the least-bad anchor rather than an empty scale
		local best = HEAT_RAMP[1]
		for _, hex in ipairs(HEAT_RAMP) do
			if contrast(hex, bg) > contrast(best, bg) then
				best = hex
			end
		end
		return { best }
	end
	-- refine both edges to the exact floor crossing (bisection keeps the
	-- passing bound, so the result never dips below the floor)
	local function refine(pass_t, fail_t)
		for _ = 1, 8 do
			local mid = (pass_t + fail_t) / 2
			if passes(mid) then
				pass_t = mid
			else
				fail_t = mid
			end
		end
		return pass_t
	end
	local lo = best_lo > 0 and refine(best_lo, best_lo - 1 / N) or 0
	local hi = best_hi < 1 and refine(best_hi, best_hi + 1 / N) or 1
	-- rebuild anchors: synthesised endpoints + surviving originals between them
	local kept = { sample(HEAT_RAMP, lo) }
	for i, hex in ipairs(HEAT_RAMP) do
		local t = (i - 1) / (#HEAT_RAMP - 1)
		if t > lo and t < hi then
			kept[#kept + 1] = hex
		end
	end
	kept[#kept + 1] = sample(HEAT_RAMP, hi)
	return kept
end

local function define_heat()
	local normal = vim.api.nvim_get_hl(0, { name = "Normal" })
	-- transparent background: assume the extreme so the floor still holds
	local bg = normal.bg and ("#%06x"):format(normal.bg) or (vim.o.background == "light" and "#ffffff" or "#000000")
	local ramp = M.usable_ramp(bg)
	for i = 1, HEAT_STEPS do
		local fg = sample(ramp, (i - 1) / (HEAT_STEPS - 1))
		vim.api.nvim_set_hl(0, "ObsidianQueryHeat" .. i, { fg = fg, default = true })
	end
	-- stacked over the day's heat colour: `reverse` paints that colour as the
	-- cell's background, so today stands out without owning a colour itself
	vim.api.nvim_set_hl(0, "ObsidianQueryToday", { reverse = true, bold = true, default = true })
end
define_heat()
vim.api.nvim_create_autocmd({ "ColorScheme", "OptionSet" }, {
	group = vim.api.nvim_create_augroup("obsidian_query_heat", { clear = true }),
	pattern = { "*", "background" },
	callback = define_heat,
})

---Heat group picker for one month: linear over that month's note counts.
---@param days table<integer, string[]>
---@return fun(n: integer): string
---@return integer? lo lowest count
---@return integer? hi highest count
local function heat_scale(days)
	local lo, hi
	for _, paths in pairs(days) do
		lo = math.min(lo or #paths, #paths)
		hi = math.max(hi or #paths, #paths)
	end
	return function(n)
		local step = 1
		if hi and hi > lo then
			step = 1 + math.floor((n - lo) / (hi - lo) * (HEAT_STEPS - 1) + 0.5)
		end
		return "ObsidianQueryHeat" .. step
	end, lo, hi
end

---Legend line mapping the ramp back to counts: `lo ███…███ hi`, exactly
---GRID_W wide to line up with the grid. One segment per column, coloured by
---the same groups the day cells use.
---@param lo integer
---@param hi integer
---@return table line
local function legend_line(lo, hi)
	local a, b = tostring(lo), tostring(hi)
	local w = GRID_W - #a - #b - 2
	local line = { BAR, { a .. " ", "Comment" } }
	for j = 1, w do
		local step = 1 + math.floor((j - 1) / (w - 1) * (HEAT_STEPS - 1) + 0.5)
		line[#line + 1] = { "█", "ObsidianQueryHeat" .. step }
	end
	line[#line + 1] = { " " .. b, "Comment" }
	return line
end

---The month a calendar view offset lands on (0/nil = the current month).
---os.time normalises month over/underflow, so any offset is a valid month.
---@param data table calendar result (uses data.today)
---@param view integer?
---@return {year: integer, month: integer, label: string}
function M.view_month(data, view)
	local today = data.today or os.date("*t")
	local t = os.date("*t", os.time({ year = today.year, month = today.month + (view or 0), day = 1 }))
	return { year = t.year, month = t.month, label = ("%s %d"):format(MONTHS[t.month], t.year) }
end

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
	local base = M.view_month(data, view)
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
	local label = base.label
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
	local heat, count_lo, count_hi = heat_scale(m.days)
	for day = 1, ndays do
		local hit = m.days[day]
		local is_today = today.year == m.year and today.month == m.month and today.day == day
		local hl = hit and heat(#hit) or "Comment"
		row[#row + 1] = {
			("%2d%s"):format(day, hit and "•" or " "),
			is_today and { hl, "ObsidianQueryToday" } or hl,
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
	-- legend only when the colours actually encode a range
	if count_hi and count_hi > count_lo then
		lines[#lines + 1] = legend_line(count_lo, count_hi)
	end
	lines[#lines + 1] = {
		BAR,
		{ ("%d this month · %d dated notes"):format(n_month, #data.dated), "Comment" },
		{
			("  %s/%s month · %stoday"):format(key("<Left>"), key("<Right>"), key("<Home>")),
			"NonText",
		},
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

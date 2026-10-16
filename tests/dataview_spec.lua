-- Run: nvim -l tests/dataview_spec.lua
-- Tests exercise the tree they live in: drop the deployed config from rtp so
-- nvim's rtp loader can't shadow the (possibly un-applied) chezmoi source.
vim.opt.rtp:remove(vim.fn.stdpath("config"))
local here = debug.getinfo(1).source:sub(2)
local lua_dir = vim.fs.dirname(vim.fs.dirname(here)) .. "/lua"
package.path = lua_dir .. "/?.lua;" .. lua_dir .. "/?/init.lua;" .. package.path

local lexer = require("obsidian-query.dataview.lexer")
local parser = require("obsidian-query.dataview.parser")
local value = require("obsidian-query.dataview.value")
local eval = require("obsidian-query.dataview.eval")
local functions = require("obsidian-query.dataview.functions")
local page_mod = require("obsidian-query.dataview.page")
local query = require("obsidian-query.dataview.query")

local n_ok, group = 0, ""
local function check(cond, msg)
  if not cond then
    io.write(("FAIL [%s] %s\n"):format(group, msg))
    os.exit(1)
  end
  n_ok = n_ok + 1
end

---------------------------------------------------------------- fixtures

local ROOT = "/vault"
local function ts(y, m, d, h)
  return os.time({ year = y, month = m, day = d, hour = h or 12 })
end
local NOW = value.date(ts(2026, 7, 28), "datetime")

local INDEX = {
  [ROOT .. "/Journal/2026-07-01.md"] = {
    mtime = ts(2026, 7, 1),
    size = 100,
    aliases = { "day one" },
    tags = { "día", "ci/setup" },
    properties = { status = "open", priority = 3, due = "2026-08-01" },
    links_out = { { target = "2026-07-10", kind = "wiki" } },
    tasks = {
      { line = 10, indent = 0, state = " ", text = "align #lab [due:: 2026-08-15]" },
      { line = 11, indent = 2, state = "x", text = "sub uno" },
      { line = 13, indent = 0, state = "x", text = "calibrate 📅 2026-07-30" },
    },
  },
  [ROOT .. "/Journal/2026-07-10.md"] = {
    mtime = ts(2026, 7, 10),
    size = 200,
    aliases = {},
    tags = { "día" },
    properties = { status = "done", priority = 1 },
    links_out = {},
    tasks = {},
  },
  [ROOT .. "/Papers/reading.md"] = {
    mtime = ts(2026, 6, 1),
    size = 300,
    aliases = {},
    tags = { "papers" },
    properties = { status = "done", rating = 9.5 },
    links_out = { { target = "2026-07-01", kind = "wiki" } },
    tasks = {},
  },
}
local SUP = {
  [ROOT .. "/Journal/2026-07-01.md"] = {
    fields = { ["session-goal"] = "publish notes" },
    headers = { { line = 5, level = 1, text = "Plan" }, { line = 9, level = 2, text = "Tasks" } },
    lists = {
      { line = 6, indent = 0, text = "idea suelta" },
      { line = 10, indent = 0, text = "[ ] align #lab [due:: 2026-08-15]" },
      { line = 11, indent = 2, text = "[x] sub uno" },
      { line = 13, indent = 0, text = "[x] calibrate 📅 2026-07-30" },
    },
  },
}
local INLINKS = {
  [ROOT .. "/Journal/2026-07-10.md"] = { ROOT .. "/Journal/2026-07-01.md" },
  [ROOT .. "/Journal/2026-07-01.md"] = { ROOT .. "/Papers/reading.md" },
}
local CTX = { index = INDEX, root = ROOT, sup = SUP, inlinks = INLINKS, now = NOW }

local function run(q)
  local ctx = vim.tbl_extend("force", {}, CTX)
  return query.run(q, ctx)
end

---------------------------------------------------------------- lexer
group = "lexer"
local toks = assert(lexer.tokenize("due-date - b \"x\" 'y' #a/b [[Note|Show]] (f) => != 3.5"))
local types = vim.tbl_map(function(t)
  return t.type
end, toks)
check(toks[1].text == "due-date", "kebab ident")
check(toks[2].type == "-" and toks[3].text == "b", "minus vs kebab")
check(toks[4].type == "STRING" and toks[4].text == "x", "dquote string")
check(toks[5].type == "STRING" and toks[5].text == "y", "squote string")
check(toks[6].type == "TAG" and toks[6].text == "a/b", "tag token")
check(toks[7].type == "LINK" and toks[7].text == "Note|Show", "link raw capture")
check(vim.tbl_contains(types, "=>"), "arrow token")
check(toks[#toks - 1].type == "NUMBER" and toks[#toks - 1].text == "3.5", "number")

---------------------------------------------------------------- parser
group = "parser"
local q = assert(
  parser.parse('TABLE WITHOUT ID status AS "Status", priority FROM #día WHERE priority > 1 SORT priority DESC LIMIT 5')
)
check(q.header.kind == "table" and q.header.without_id, "TABLE WITHOUT ID")
check(#q.header.fields == 2 and q.header.fields[1].alias == "Status", "field alias")
check(q.commands[1].cmd == "from" and q.commands[1].src.k == "s_tag", "FROM #tag")
check(q.commands[2].cmd == "where" and q.commands[2].expr.k == "cmp", "WHERE cmp")
check(q.commands[3].cmd == "sort" and q.commands[3].keys[1].dir == "desc", "SORT DESC")
check(q.commands[4].cmd == "limit", "LIMIT")

q = assert(parser.parse('LIST FROM #a AND ("Papers" OR -[[x]]) WHERE contains(file.name, "07")'))
local src = q.commands[1].src
check(src.k == "s_and" and src.kids[2].k == "s_or" and src.kids[2].kids[2].k == "s_not", "source algebra")

q = assert(parser.parse("LIST WHERE any(map(file.tasks, (t) => !t.completed))"))
check(q.commands[1].expr.k == "call", "lambda parses inside call")

q = assert(parser.parse("TABLE file.day WHERE file.day >= date(2026-07-01) AND file.day <= date(today)"))
check(q.commands[1].expr.k == "and", "AND keyword in WHERE")
local q2 = assert(parser.parse('LIST WHERE priority > 1 AND status = "open" OR done'))
check(q2.commands[1].expr.k == "or" and q2.commands[1].expr.l.k == "and", "AND binds tighter than OR")

local _, err = parser.parse("GARBAGE nope")
check(err and err.msg:find("must start"), "bad header error")
_, err = parser.parse("TABLE FROM #a WHERE")
check(err ~= nil, "truncated WHERE errors")

---------------------------------------------------------------- values
group = "values"
local d1 = value.parse_date("2026-07-01")
check(value.typeof(d1) == "date" and d1.prec == "date" and d1.year == 2026, "parse_date + lazy components")
local dt = value.parse_date("2026-07-01T14:30")
check(dt.prec == "datetime" and dt.hour == 14, "datetime parse")
check(value.typeof(value.parse_date("nope")) == "null", "bad date -> null")
-- Obsidian writes frontmatter timestamps space-separated, not ISO "T"
local sp = value.parse_date("2024-02-18 10:44")
check(sp.prec == "datetime" and sp.hour == 10 and sp.minute == 44, "space-separated datetime")
check(value.to_display(sp) == "10:44 AM - February 18, 2024", "space form keeps its time")
check(value.parse_date("2026-07-01 is a Wednesday").prec == "date", "trailing prose stays a date")
-- negative durations keep their calendar part and display signed
local neg = value.arith("-", value.parse_date("2026-01-01"), value.parse_date("2026-01-02"))
check(value.to_display(neg) == "-1 day", "date - later date displays negative")
local negm = value.dur(0, -14)
check(value.to_display(negm) == "-1 year, 2 months", "negative months display signed")
local dur = value.parse_dur("1 day, 2 hours")
check(dur.ms == (26 * 3600) * 1000, "parse_dur")
check(value.parse_dur("3h").ms == 3 * 3600 * 1000, "parse_dur short")

check(value.arith("+", "a", 1) == "a1", "string + number concat")
check(value.typeof(value.arith("+", value.NULL, 1)) == "null", "null + number -> null")
local diff = value.arith("-", value.parse_date("2026-07-10"), value.parse_date("2026-07-01"))
check(value.typeof(diff) == "duration" and diff.days == 9, "date - date -> duration")
local advanced = value.arith("+", d1, value.parse_dur("7 days"))
check(value.typeof(advanced) == "date" and advanced.day == 8, "date + duration")
check(value.typeof(value.arith("/", 1, 0)) == "null", "div by zero -> null")

check(value.truthy("") == false and value.truthy(value.array({})) == false, "empty falsy")
check(value.compare_op("=", value.NULL, value.NULL) == true, "null = null")
check(value.compare_op("=", value.NULL, 1) == false, "null = x false")
check(value.compare_op("<", value.NULL, 1) == true, "null sorts before non-null values")
check(value.cmp(1, "a") == -1, "type rank number < string")
check(value.cmp(value.array({ 1, 2 }), value.array({ 1, 3 })) == -1, "array elementwise")

---------------------------------------------------------------- functions
group = "functions"
local F = functions.registry
local env = { funcs = F, now = NOW }
check(F.contains(env, { "Hello World", "world" }) == false, "contains string case-sensitive")
check(F.contains(env, { value.array({ 1, 2 }), 2 }) == true, "contains array")
check(F.econtains(env, { "Hello", "hello" }) == false, "econtains case-sensitive")
check(F.length(env, { value.array({ 1, 2, 3 }) }) == 3, "length")
check(F.default(env, { value.NULL, 5 }) == 5, "default")
check(F.choice(env, { true, "a", "b" }) == "a", "choice")
check(F.join(env, { value.array({ 1, 2 }), "-" }) == "1-2", "join")
check(value.eq(F.reverse(env, { value.array({ 1, 2 }) }), value.array({ 2, 1 })), "reverse")
check(F.first(env, { value.array({ 7, 8 }) }) == 7 and F.last(env, { value.array({ 7, 8 }) }) == 8, "first/last")
check(F.sum(env, { value.array({ 1, 2, 3 }) }) == 6, "sum")
check(F.min(env, { 3, 1, 2 }) == 1 and F.max(env, { 3, 1, 2 }) == 3, "min/max varargs")
check(value.eq(F.sort(env, { value.array({ 3, 1, 2 }) }), value.array({ 1, 2, 3 })), "sort")
check(value.eq(F.unique(env, { value.array({ 1, 1, 2 }) }), value.array({ 1, 2 })), "unique")
check(F.regextest(env, { "\\d+", "abc123" }) == true, "regextest substring")
check(F.regexreplace(env, { "a1b2", "\\d", "_" }) == "a_b_", "regexreplace")
check(F.lower(env, { "ABC" }) == "abc", "lower")
check(value.eq(F.lower(env, { value.array({ "A", "B" }) }), value.array({ "a", "b" })), "vectorized lower")
check(F.startswith(env, { "foobar", "foo" }) == true, "startswith")
check(F.round(env, { 3.456, 2 }) == 3.46, "round digits")
check(F.typeof(env, { value.NULL }) == "null", "typeof")
check(F.dateformat(env, { value.parse_date("2026-07-01"), "yyyy/MM/dd" }) == "2026/07/01", "dateformat")
check(
  F.dateformat(env, { value.parse_date("2026-07-01"), "'week' W" }):match("^week %d+$") ~= nil,
  "dateformat literal+W"
)
check(F.striptime(env, { value.parse_date("2026-07-01T14:30") }).prec == "date", "striptime")

---------------------------------------------------------------- eval
group = "eval"
local pg = page_mod.build(ROOT .. "/Journal/2026-07-01.md", INDEX[ROOT .. "/Journal/2026-07-01.md"], CTX)
local penv = { page = pg, funcs = F, now = NOW }
local function ev(src)
  local q3 = assert(parser.parse("LIST WHERE " .. src))
  return eval.expr(q3.commands[1].expr, penv)
end
check(ev('status = "open"') == true, "fm field access")
check(ev("priority + 1 = 4") == true, "arith on field")
check(ev("missing.deep.chain") == value.NULL, "null chain propagates")
check(ev("file.name") == "2026-07-01", "file.name")
check(ev("file.folder") == "Journal", "file.folder")
check(value.typeof(ev("due")) == "date", "ISO frontmatter string -> date")
check(ev("session-goal") == "publish notes", "inline field via kebab ident")
check(ev('contains(file.tags, "#ci")') == true, "tag prefix expansion")
check(ev('contains(file.etags, "#ci/setup")') == true, "etags exact")
check(ev("length(file.aliases) = 1") == true, "aliases")
check(ev("length(file.inlinks) = 1") == true, "inlinks")
check(ev("length(file.outlinks) = 1") == true, "outlinks")
check(ev("length(file.tasks) = 3") == true, "tasks present")
check(ev("length(file.lists) = 4") == true, "lists = plain bullets + tasks")
check(ev("length(filter(file.lists, (l) => !l.task)) = 1") == true, "plain bullet marked task=false")
check(ev('first(filter(file.lists, (l) => !l.task)).text = "idea suelta"') == true, "plain bullet text")
check(ev("all(map(file.tasks, (t) => t.task))") == true, "tasks carry task=true")
check(ev("any(map(file.tasks, (t) => !t.checked))") == true, "lambda over tasks")
check(ev("none(list(false, false))") == true and ev("none(list(true))") == false, "none()")
check(ev('startswith("abc", "z")') == false, "call returning false stays false, not null")
check(ev('startswith("abc", "z") = false') == true, "false results compare as false")
check(ev("string(-dur(1 month))") == "-1 month", "negated duration keeps months")
check(ev("date(today) - due < dur(30 days)") == true, "date literal + dur math")
-- swizzle
local rows_v = eval.expr(assert(parser.parse("LIST WHERE file.tasks.text")).commands[1].expr, penv)
check(value.typeof(rows_v) == "array" and rows_v[1]:find("^align #lab") ~= nil, "array swizzle .text")

---------------------------------------------------------------- page/tasks
group = "page"
check(pg.file.tasks[1].fullyCompleted == false, "parent not fullyCompleted (unchecked itself)")
check(pg.file.tasks[3].fullyCompleted == true, "leaf completed")
check(#pg.file.tasks[1].children == 1, "indent nesting")
check(pg.file.tasks[1].section.display == "Tasks", "section from headers index")
check(pg.file.tasks[1].line == 9, "task line follows Dataview zero-based indexing")
check(value.eq(pg.file.tasks[1].tags, value.array({ "#lab" })), "task tags")
check(value.typeof(pg.file.tasks[1].due) == "date" and pg.file.tasks[1].due.day == 15, "task [due::] field")
check(value.typeof(pg.file.tasks[3].due) == "date" and pg.file.tasks[3].due.day == 30, "task emoji due")

group = "this"
local tctx = vim.tbl_extend("force", {}, CTX, { this_path = ROOT .. "/Journal/2026-07-01.md" })
local tres = query.run("LIST WHERE file.name = this.file.name", tctx)
check(tres.ok and #tres.data.groups[1].items == 1, "this resolves to fence note")
tres = query.run("LIST FROM [[]]", tctx)
check(
  tres.ok and #tres.data.groups[1].items == 1 and tres.data.groups[1].items[1].path:find("reading"),
  "FROM [[]] = inlinks of this"
)

---------------------------------------------------------------- pipeline
group = "pipeline"
local res = run('TABLE status, priority FROM "Journal" SORT priority DESC')
check(res.ok, "table runs: " .. (res.msg or ""))
check(#res.data.rows == 2, "folder source")
check(res.data.columns[1] == "File" and res.data.columns[2] == "status", "columns")
check(res.data.rows[1].cells[2] == 3, "sort desc by priority")
check(res.data.rows[1].path:find("2026%-07%-01"), "row path")

res = run("LIST FROM #ci")
check(res.ok and #res.data.groups[1].items == 1, "nested tag source")

res = run('LIST FROM #día WHERE status = "open"')
check(res.ok and #res.data.groups[1].items == 1, "WHERE filters")

res = run("LIST FROM [[2026-07-10]]")
check(res.ok and #res.data.groups[1].items == 1, "FROM [[link]] = inlinks")
check(res.data.groups[1].items[1].path:find("07%-01"), "inlink correct")

res = run("LIST FROM outgoing([[reading]])")
check(res.ok and #res.data.groups[1].items == 1 and res.data.groups[1].items[1].path:find("07%-01"), "outgoing()")

res = run('LIST FROM "Journal" OR "Papers"')
check(res.ok and #res.data.groups[1].items == 3, "source OR")

res = run('LIST FROM -"Papers"')
check(res.ok and #res.data.groups[1].items == 2, "source negation")

res = run('TABLE length(rows) FROM "Journal" GROUP BY status')
check(res.ok and #res.data.rows == 2, "GROUP BY buckets")
check(res.data.rows[1].cells[1] == 1, "length(rows)")

res = run('LIST FROM "Journal" FLATTEN file.tags AS t WHERE t = "#ci"')
check(res.ok and #res.data.groups[1].items == 1, "FLATTEN then WHERE (written order)")

res = run('LIST FROM "Journal" WHERE priority > 0 LIMIT 1')
check(res.ok and #res.data.groups[1].items == 1, "LIMIT")

-- command order matters: WHERE before vs after GROUP
local a = run('TABLE length(rows) FROM "Journal" WHERE priority > 1 GROUP BY status')
local b = run('TABLE length(rows) FROM "Journal" GROUP BY status WHERE length(rows) > 1')
check(a.ok and #a.data.rows == 1, "WHERE then GROUP")
check(b.ok and #b.data.rows == 0, "GROUP then WHERE on group rows")

res = run('TASK FROM "Journal" WHERE !completed')
check(res.ok, "task query runs")
local tcount = 0
for _, g in ipairs(res.data.groups) do
  tcount = tcount + #g.items
end
check(tcount == 1, "task explosion + WHERE on task fields; got " .. tcount)

res = run('TASK FROM "Journal" GROUP BY section')
check(res.ok and #res.data.groups >= 1, "task GROUP BY section")

res = run("CALENDAR")
check(res.ok, "calendar runs")
check(#res.data.months == 1 and res.data.months[1].month == 7, "one month bucket (file.day from names)")
check(res.data.months[1].days[1] ~= nil and res.data.months[1].days[10] ~= nil, "days 1 and 10 marked")
check(#res.data.dated == 2 and res.data.dated[1].date.day == 10, "dated newest first")

res = run("CALENDAR file.mtime")
check(res.ok and #res.data.months == 2 and res.data.months[1].month == 7, "explicit expr; months desc")

res = run('CALENDAR FROM "Papers"')
check(res.ok and #res.data.months == 0 and #res.data.dated == 0, "dateless rows dropped")
check(res.data.undated > 0, "dateless rows counted")

local dv_render = require("obsidian-query.dataview.render")
local function flatten(lines)
  local flat = {}
  for _, l in ipairs(lines) do
    local parts = {}
    for _, seg in ipairs(l) do
      parts[#parts + 1] = seg[1]
    end
    flat[#flat + 1] = table.concat(parts)
  end
  return flat
end
-- one month at a time, opening on "today" (NOW = 2026-07-28)
local flat = flatten(dv_render.calendar_lines(run("CALENDAR").data))
local undated_flat = flatten(dv_render.calendar_lines(run('CALENDAR FROM "Papers"').data))
check(undated_flat[#undated_flat]:find("without a date"), "undated rows reported under the grid")
local journal = run('CALENDAR FROM "Journal"').data
local journal_flat = flatten(dv_render.calendar_lines(journal))
check(
  journal.undated == 0 and not journal_flat[#journal_flat]:find("without a date"),
  "all-dated calendar has no warning"
)
check(flat[1]:find("‹") and flat[1]:find("July 2026") and flat[1]:find("›$"), "grid header with arrows")
-- header spans the grid ("▏ " + 7 day cells) so the arrows sit still
check(vim.fn.strdisplaywidth(flat[1]) == 2 + 21, "header spans the grid width")
check(flat[2]:find("Mo Tu We"), "weekday row")
check(flat[3]:find("1•"), "day 1 marked (2026-07-01 is a Wednesday)")
check(journal_flat[#journal_flat]:find("2 this month · 2 dated notes"), "month + total tail")
for _, l in ipairs(flat) do
  check(not l:find("August") and not l:find("June"), "only the current month rendered")
end

-- <Left>/<Right> shift the view; months without notes still render
local next_month = flatten(dv_render.calendar_lines(journal, 1))
check(next_month[1]:find("August 2026"), "view +1 -> next month")
check(next_month[#next_month]:find("0 this month"), "empty month renders with no dots")
check(flatten(dv_render.calendar_lines(run("CALENDAR").data, -13))[1]:find("June 2025"), "view -13 wraps the year")

local cres2 = run("CALENDAR")
check(dv_render.lines(cres2) ~= nil and require("obsidian-query.dataview").shift(cres2, 2), "shift() handles calendars")
check(cres2.view == 2, "shift accumulates")
check(not require("obsidian-query.dataview").shift(run("LIST"), 1), "shift ignores other kinds")
check(flatten(dv_render.lines(cres2))[1]:find("September 2026"), "lines() honours the view")

-- key hints: nerd-font glyph for known keys, literal <Key> otherwise, both
-- trailing-padded so a two-cell glyph can't collide with the next character
local base_render = require("obsidian-query.render")
-- the glyphs are private-use codepoints, so assert their shape, not literals
local left = base_render.key("<Left>")
check(left ~= "<Left> " and vim.fn.strchars(left) == 2, "glyph + pad for known keys")
check(base_render.key("<F5>") == "<F5> ", "unknown keys stay literal")
for _, lhs in ipairs({ "<Left>", "<Right>", "<CR>", "<Home>", "<F5>" }) do
  check(base_render.key(lhs):sub(-1) == " ", "key hint padded: " .. lhs)
end

-- view_month resolves an offset to a labelled month
local vm_data = { today = { year = 2026, month = 7, day = 28 } }
local vm = dv_render.view_month(vm_data, 0)
check(vm.year == 2026 and vm.month == 7 and vm.label == "July 2026", "view_month at offset 0")
check(dv_render.view_month(vm_data, 2).label == "September 2026", "view_month offset crosses months")
check(dv_render.view_month(vm_data, -7).label == "December 2025", "view_month offset crosses years")

-- day cells are heat-mapped by note count over the shown month
local function heat_of(days)
  local d = {
    kind = "calendar",
    months = { { year = 2026, month = 7, days = days } },
    dated = {},
    today = { year = 2026, month = 7, day = 1 },
  }
  local hl = {}
  for _, line in ipairs(dv_render.calendar_lines(d, 0)) do
    for _, seg in ipairs(line) do
      local day = seg[1]:match("^%s*(%d+)•$")
      if day then
        hl[tonumber(day)] = seg[2]
      end
    end
  end
  return hl
end
local flat_heat = heat_of({ [2] = { "a" }, [3] = { "b" }, [6] = { "c" } })
check(flat_heat[2] == "ObsidianQueryHeat1" and flat_heat[6] == "ObsidianQueryHeat1", "equal counts collapse to step 1")
local ramp = heat_of({ [2] = { "a" }, [3] = { "a", "b", "c" }, [6] = { "a", "b", "c", "d", "e" } })
local function step_of(hl)
  return tonumber(hl:match("Heat(%d+)$"))
end
local last = step_of(ramp[2])
check(last == 1, "fewest notes -> first palette step")
check(step_of(ramp[3]) > last and step_of(ramp[6]) > step_of(ramp[3]), "more notes -> further along the ramp")
check(vim.api.nvim_get_hl(0, { name = ramp[6] }).fg ~= nil, "heat groups defined")
-- the ramp is interpolated, not snapped to its anchors
local anchors =
  { ["88226a"] = true, ["a83655"] = true, ["e35933"] = true, ["f9950a"] = true, ["f8c932"] = true, ["fcffa4"] = true }
local between = 0
for i = 1, step_of(ramp[6]) do
  local fg = vim.api.nvim_get_hl(0, { name = "ObsidianQueryHeat" .. i }).fg
  if fg and not anchors[("%06x"):format(fg)] then
    between = between + 1
  end
end
check(between > 0, "steps interpolate between the ramp anchors")
-- legend: `lo ███ hi` under the grid, grid-wide, only when counts vary
local function legend_of(days)
  local d = {
    kind = "calendar",
    months = { { year = 2026, month = 7, days = days } },
    dated = {},
    today = { year = 2026, month = 7, day = 1 },
  }
  for _, line in ipairs(dv_render.calendar_lines(d, 0)) do
    if line[2] and line[2][1]:match("^%d+ $") and line[3] and line[3][1] == "█" then
      return line
    end
  end
  return nil
end
local leg = legend_of({ [2] = { "a" }, [3] = { "a", "b", "c" }, [6] = { "a", "b", "c", "d", "e" } })
check(leg ~= nil, "legend rendered when counts vary")
check(leg[2][1] == "1 " and leg[#leg][1] == " 5", "legend labelled with min and max counts")
local legw, first_step, last_step = 0, nil, nil
for i = 2, #leg do
  legw = legw + vim.fn.strdisplaywidth(leg[i][1])
  local s = type(leg[i][2]) == "string" and leg[i][2]:match("^ObsidianQueryHeat(%d+)$")
  if s then
    first_step = first_step or tonumber(s)
    last_step = tonumber(s)
  end
end
check(legw == 21, "legend spans the grid width")
check(first_step == 1 and last_step == 24, "legend sweeps the full ramp")
check(legend_of({ [2] = { "a" }, [9] = { "b" } }) == nil, "no legend when every day has the same count")
check(legend_of({}) == nil, "no legend for an empty month")

-- today keeps its heat colour, marked by a stacked attribute group
local with_today = heat_of({ [1] = { "a" }, [4] = { "a", "b" } })
check(type(with_today[1]) == "table", "today's cell stacks two groups")
check(
  with_today[1][1]:find("^ObsidianQueryHeat%d+$") and with_today[1][2] == "ObsidianQueryToday",
  "today = heat + today attrs"
)
check(type(with_today[4]) == "string" and step_of(with_today[4]) > 1, "other days keep a plain heat group")
local today_hl = vim.api.nvim_get_hl(0, { name = "ObsidianQueryToday" })
check(today_hl.reverse and today_hl.fg == nil, "today group reverses the heat colour, owns none")

-- heat colours are clamped to stay legible on the colorscheme's background
local function ratio(a, b) -- WCAG, independent of the implementation under test
  local function lum(hex)
    local n, l = tonumber(hex:sub(2), 16), {}
    for i, c in ipairs({ math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256 }) do
      c = c / 255
      l[i] = c <= 0.03928 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
    end
    return 0.2126 * l[1] + 0.7152 * l[2] + 0.0722 * l[3]
  end
  local x, y = lum(a), lum(b)
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05)
end
local LATTE, MOCHA = "#eff1f5", "#1e1e2e"
local FLOOR = dv_render.HEAT_MIN_CONTRAST
local full = { dv_render.sample_heat(0), dv_render.sample_heat(1) }
check(ratio(full[1], MOCHA) < FLOOR, "the raw ramp's dark end fails on a dark background")
check(ratio(full[2], LATTE) < FLOOR, "the raw ramp's light end fails on a light background")
for _, bg in ipairs({ LATTE, MOCHA, "#808080" }) do
  local ramp = dv_render.usable_ramp(bg)
  check(#ramp > 0, "usable ramp never empties on " .. bg)
  for _, hex in ipairs(ramp) do
    check(ratio(hex, bg) >= FLOOR or #ramp == 1, ("kept anchor %s clears the floor on %s"):format(hex, bg))
  end
  local seen = {}
  for i = 1, 24 do
    local fg = dv_render.sample_heat((i - 1) / 23, ramp)
    check(ratio(fg, bg) >= FLOOR or #ramp == 1, ("step %d stays legible on %s"):format(i, bg))
    seen[fg] = true
  end
  check(vim.tbl_count(seen) > 1 or #ramp == 1, "surviving anchors still interpolate on " .. bg)
end
local dark_ramp, light_ramp = dv_render.usable_ramp(MOCHA), dv_render.usable_ramp(LATTE)
check(dark_ramp[1] ~= full[1], "dark background drops the ramp's darkest anchors")
check(light_ramp[#light_ramp] ~= full[2], "light background drops the ramp's lightest anchors")
check(#dark_ramp < 9 and #light_ramp < 9, "both backgrounds drop something")

local cal_data = run("CALENDAR").data
dv_render.calendar_lines(cal_data)
local cmap = cal_data._clickmap
check(cmap ~= nil and next(cmap) ~= nil, "clickmap built")
local any_cell
for vidx, cells in pairs(cmap) do
  if vidx ~= 1 then -- line 1 holds the header arrows, not day cells
    any_cell = cells[1]
    break
  end
end
check(any_cell and any_cell.s > 2 and any_cell.e > any_cell.s and #any_cell.paths > 0, "clickmap cell shape")
check(cmap[1] and cmap[1][1].shift == -1 and cmap[1][2].today and cmap[1][3].shift == 1, "header cells clickable")
local dv = require("obsidian-query.dataview")
local clicked = run("CALENDAR")
dv_render.lines(clicked)
local arrows = clicked.data._clickmap[1]
check(dv.click(clicked, 1, arrows[3].s) and clicked.view == 1, "clicking › advances a month")
check(dv.click(clicked, 1, arrows[1].s) and clicked.view == 0, "clicking ‹ goes back")
dv.shift(clicked, 5)
check(dv.click(clicked, 1, arrows[2].s) and clicked.view == 0, "clicking the month label returns to today")
dv.shift(clicked, 5)
check(dv.shift(clicked, nil) and clicked.view == 0, "shift(nil) jumps to today")

-- inline row caps: opt-in via config
require("obsidian-query.config").set({ max_inline_rows = 15 })
local long_rows = {}
for i = 1, 20 do
  long_rows[i] = { id = value.NULL, cells = { i }, path = "" }
end
local capped = dv_render.table_lines({ kind = "table", with_id = false, columns = { "n" }, rows = long_rows })
local found_more = false
for _, l in ipairs(capped) do
  for _, seg in ipairs(l) do
    if seg[1]:find("+5 more rows", 1, true) then
      found_more = true
    end
  end
end
check(found_more, "table capped at 15 with more-line")
require("obsidian-query.config").set({ max_inline_rows = vim.NIL })
require("obsidian-query.config").opts.max_inline_rows = nil
local uncapped = dv_render.table_lines({ kind = "table", with_id = false, columns = { "n" }, rows = long_rows })
check(#uncapped > #capped, "uncapped by default renders all rows")

res = run("TABLE nope FROM #missing-tag")
check(res.ok and #res.data.rows == 0, "empty source -> empty table")

res = run("LIST WHERE")
check(not res.ok and res.phase == "parse", "parse error surfaces")

---------------------------------------------------------------- inline exprs
group = "inline"
local pe = parser.parse_expr
check(pe("this.file.name") ~= nil, "bare expr parses")
check(pe("length(file.tasks)") ~= nil, "call expr parses")
check(pe("WHERE x") == nil, "command keywords rejected")
check(pe("1 +") == nil, "truncated expr rejected")
local ienv = { page = pg, this = pg, funcs = F, now = NOW }
check(eval.expr(pe("this.file.name"), ienv) == "2026-07-01", "this in inline env")
check(value.to_display(eval.expr(pe("length(file.tasks)"), ienv)) == "3", "inline call display")
check(value.to_display(eval.expr(pe("missing.field"), ienv)) == "-", "null uses default rendering")

---------------------------------------------------------------- durations
group = "durations"
local jan31 = value.parse_date("2026-01-31")
local plus1mo = value.arith("+", jan31, value.parse_dur("1 month"))
check(value.to_display(plus1mo) == "February 28, 2026", "month shift clamps day")
check(
  value.to_display(value.arith("+", value.parse_date("2024-02-29"), value.parse_dur("1 year"))) == "February 28, 2025",
  "year shift clamps leap day"
)
check(value.parse_dur("1 mo").months == 1 and value.parse_dur("2 years").months == 24, "symbolic months")
check(value.to_display(value.parse_dur("14 months, 3 days")) == "1 year, 2 months, 3 days", "hybrid display")
check(value.cmp(value.parse_dur("1 month"), value.parse_dur("29 days")) == 1, "approx ordering")
check(
  value.to_display(value.arith("-", value.parse_date("2026-03-31"), value.parse_dur("1 month"))) == "February 28, 2026",
  "month subtraction clamps"
)

---------------------------------------------------------------- regex
group = "regex"
check(F.regextest(env, { "foo|bar", "foo" }) == true, "alternation")
check(F.regextest(env, { "foo(?=bar)", "foobar" }) == true, "lookahead")
check(F.regextest(env, { "foo(?=bar)", "foobaz" }) == false, "negative lookahead miss")
check(F.regextest(env, { "(?<=x)bar", "xbar" }) == true, "lookbehind")
check(F.regexreplace(env, { "john smith", "(\\w+) (\\w+)", "$2 $1" }) == "smith john", "backref replace")
check(F.regextest(env, { "\\w+@\\w+", "a@b.com" }) == true, "literal @")

---------------------------------------------------------------- formats
group = "formats"
check(
  F.durationformat(env, { value.parse_dur("1 year, 2 months, 3 days"), "y'y' M'mo' d'd'" }) == "1y 2mo 3d",
  "durationformat tokens"
)
check(F.durationformat(env, { value.parse_dur("90 minutes"), "h:mm" }) == "1:30", "durationformat padding")
check(F.currencyformat(env, { 1234.5 }) == "$1,234.50", "currencyformat default USD")
check(F.currencyformat(env, { -1234.5, "EUR" }) == "-\u{20ac}1,234.50", "currencyformat EUR negative")

---------------------------------------------------------------- csv + starred + dup fields
group = "sources"
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/.obsidian", "p")
local fd = io.open(tmp .. "/data.csv", "w")
fd:write('name,score,when\n"Smith, J",9.5,2026-07-01\nDoe,7,2026-06-01\n')
fd:close()
fd = io.open(tmp .. "/.obsidian/bookmarks.json", "w")
fd:write(
  '{"items":[{"type":"file","path":"Journal/2026-07-01.md"},{"type":"group","items":[{"type":"file","path":"Papers/reading.md"}]}]}'
)
fd:close()

local cres = query.run('TABLE score, when FROM csv("data.csv") SORT score DESC', { index = {}, root = tmp })
check(cres.ok, "csv query runs: " .. (cres.msg or ""))
check(#cres.data.rows == 2 and cres.data.rows[1].cells[1] == 9.5, "csv rows sorted")
check(value.typeof(cres.data.rows[1].cells[2]) == "date", "csv dates decoded")
check(cres.data.rows[1].id ~= nil, "csv row id link")
local cerr = query.run('LIST FROM #a AND csv("data.csv")', { index = {}, root = tmp })
check(not cerr.ok and cerr.msg:find("only FROM source"), "csv nested rejected")
cerr = query.run('LIST FROM csv("nope.csv")', { index = {}, root = tmp })
check(not cerr.ok and cerr.msg:find("not found"), "missing csv reported")

local idx_mod = require("obsidian-query.index")
local starred = idx_mod._read_starred(tmp)
check(starred["Journal/2026-07-01.md"] and starred["Papers/reading.md"], "bookmarks incl. groups")
local sctx = vim.tbl_extend("force", {}, CTX, { starred = starred })
local spg = page_mod.build(ROOT .. "/Journal/2026-07-01.md", INDEX[ROOT .. "/Journal/2026-07-01.md"], sctx)
check(spg.file.starred == true, "file.starred true")
check(pg.file.starred == false, "file.starred false without bookmarks")
local dupmd = tmp .. "/dup.md"
fd = io.open(dupmd, "w")
fd:write("author:: Alice\nauthor:: Bob\nsingle:: uno\n")
fd:close()
local sup2 = idx_mod._extract_sup(dupmd)
check(type(sup2.fields.author) == "table" and #sup2.fields.author == 2, "repeated inline keys -> array")
check(sup2.fields.single == "uno", "single key stays scalar")
-- list extraction: bullets and numbered outside fences/frontmatter only
local listmd = tmp .. "/lists.md"
fd = io.open(listmd, "w")
fd:write(
  "---\ntags:\n  - yaml-item\n---\n# H\n- uno\n  - dos\n3) tres\n```\n- fenced\n```\n"
    .. "~~~~\n- tilde\n# not a heading\nfake:: field\n~~~\n~~~~\n- [ ] box\n"
)
fd:close()
local sup3 = idx_mod._extract_sup(listmd)
check(#sup3.lists == 4, "yaml + fenced bullets excluded, box included")
check(sup3.lists[1].text == "uno" and sup3.lists[2].indent == 2, "list text + indent")
check(sup3.lists[3].text == "tres", "numbered list item")
check(sup3.lists[4].text == "[ ] box", "checkbox line still recorded (paired with its task by line)")
check(#sup3.headers == 1 and sup3.fields.fake == nil, "~~~ fences hide headings and fields")
vim.fn.delete(tmp, "rf")

---------------------------------------------------------------- task toggle
group = "toggle"
local dv_engine = require("obsidian-query.dataview")
for _, expr in ipairs({
  "choice(true, false, true)",
  "default(null, false)",
  "first([false])",
  "last([false])",
  "any([true], (t) => false)",
  "all([true], (t) => false)",
  "any(file.tasks, (t) => t.completed AND !t.completed)",
}) do
  check(ev(expr) == false, "false survives function result: " .. expr)
end
check(ev("none([true], (t) => false)") == true, "none respects a false predicate")
check(ev("first(sort([1, 2], (n) => n = 1)) = 2") == true, "sort preserves false keys")
local completed_ctx = vim.deepcopy(CTX)
for _, row in pairs(completed_ctx.index) do
  for _, task in ipairs(row.tasks) do
    task.state = "x"
  end
end
local completed_result = query.run("TASK WHERE any(file.tasks, (t) => !t.completed)", completed_ctx)
check(completed_result.ok and #completed_result.data.groups == 0, "TASK query empties when all tasks are completed")
check(dv_engine.toggle_task_line("- [ ] hacer algo") == "- [x] hacer algo", "open -> done")
check(dv_engine.toggle_task_line("  - [x] hecho") == "  - [ ] hecho", "done -> open")
check(dv_engine.toggle_task_line("3. [/] parcial") == "3. [ ] parcial", "custom state resets to open")
check(dv_engine.toggle_task_line("plain prose line") == nil, "no checkbox -> nil")
check(dv_engine.toggle_task_line("- [ ] outer [x] inner") == "- [x] outer [x] inner", "first checkbox wins")
check(dv_engine.toggle_task_line("prose [x] reference") == nil, "prose brackets are not tasks")
check(dv_engine.toggle_task_line("- link [x](url)") == nil, "list links are not tasks")
check(dv_engine.toggle_task_line("- [ ] changed", "original") == nil, "stale task text is rejected")
check(dv_engine.toggle_task_line("2) [X] original", "original") == "2) [ ] original", "numbered task reopens")

local key_a = vim.api.nvim_create_buf(false, true)
local key_b = vim.api.nvim_create_buf(false, true)
local spec = dv_engine.parse("TASK WHERE file.path = this.file.path")
check(
  dv_engine.key(spec, { root = ROOT, buf = key_a }) ~= dv_engine.key(spec, { root = ROOT, buf = key_b }),
  "this-dependent queries have separate cache entries per note"
)
vim.api.nvim_buf_delete(key_a, { force = true })
vim.api.nvim_buf_delete(key_b, { force = true })

-- Exercise the actual picker callback against a temporary note.
local task_path = vim.fn.tempname() .. ".md"
vim.fn.writefile({ "- [ ] original", "- [ ] other" }, task_path)
local picker = require("obsidian-query.picker")
local saved_open, saved_notify = picker.open, vim.notify
local picked, toggle, warning
picker.open = function(_, items, opts)
  picked, toggle = items[1], opts.toggle
end
vim.notify = function(msg)
  warning = msg
end
dv_engine.pick({}, {}, {
  ok = true,
  data = {
    kind = "task",
    groups = {
      { items = {
        { path = task_path, text = "original", line = 1, status = " ", completed = false },
      } },
    },
  },
})
check(toggle(picked) == true and vim.fn.readfile(task_path)[1] == "- [x] original", "picker persists completion")
check(toggle(picked) == false and vim.fn.readfile(task_path)[1] == "- [ ] original", "picker persists reopening")
picked.settings =
  vim.tbl_extend("force", require("obsidian-query.dataview.settings").defaults, { recursiveSubTaskCompletion = true })
picked.task = { children = { { line = 2, text = "other", children = {} } } }
check(
  toggle(picked) == true and vim.fn.readfile(task_path)[2] == "- [x] other",
  "recursive completion changes subtasks"
)
check(
  toggle(picked) == false and vim.fn.readfile(task_path)[2] == "- [ ] other",
  "recursive reopening changes subtasks"
)
picked.settings.taskCompletionTracking = true
check(
  toggle(picked) == true and vim.fn.readfile(task_path)[2]:find("completion::", 1, true),
  "recursive tracking adds dates"
)
check(
  toggle(picked) == false and vim.fn.readfile(task_path)[2] == "- [ ] other",
  "recursive tracking can reopen updated child text"
)
local task_buf = vim.fn.bufnr(task_path)
vim.api.nvim_buf_set_lines(task_buf, 0, 0, false, { "- [ ] inserted" })
check(toggle(picked) == nil and warning ~= nil, "stale picker warns instead of toggling another task")
check(vim.api.nvim_buf_get_lines(task_buf, 0, 1, false)[1] == "- [ ] inserted", "unrelated task remains untouched")
check(vim.fn.readfile(task_path)[1] == "- [ ] original", "stale toggle does not write unsaved edits")
picker.open, vim.notify = saved_open, saved_notify
vim.api.nvim_buf_delete(task_buf, { force = true })
vim.fn.delete(task_path)

-- Production index path must retain lists and use the cache's full timestamp.
local index_path = vim.fn.tempname() .. ".md"
local index_root = vim.fs.dirname(index_path)
-- obsidian.nvim v3.16 row layout: stats nested under `stat`
local rows = { [index_path] = { stat = { mtime_sec = 10, mtime_nsec = 1, size = 12 }, tasks = {} } }
local saved_cache, saved_obsidian = package.loaded["obsidian.cache"], _G.Obsidian
_G.Obsidian = nil
package.loaded["obsidian.cache"] = {
  is_enabled = function()
    return true
  end,
  when_ready = function(cb)
    cb()
  end,
  notes = {
    all = function()
      return rows
    end,
  },
}
local indexed
vim.fn.writefile({ "- first" }, index_path)
idx_mod.get({ root = index_root }, function(result)
  indexed = result
end)
check(
  indexed.sup[index_path].lists and indexed.sup[index_path].lists[1].text == "first",
  "index retains extracted lists"
)
vim.fn.writefile({ "- other" }, index_path)
rows[index_path].stat.mtime_nsec = 2
idx_mod.invalidate()
idx_mod.get({ root = index_root }, function(result)
  indexed = result
end)
check(indexed.sup[index_path].lists[1].text == "other", "same-second edit refreshes supplement")
local shared_index
idx_mod.get({ root = index_root }, function(result)
  shared_index = result
end)
check(shared_index == indexed, "index shared within an invalidation generation")
local sharedctx = { index = indexed.rows, pages = indexed.pages, root = index_root, sup = indexed.sup }
local firstpage = page_mod.get(index_path, sharedctx)
check(page_mod.get(index_path, sharedctx) == firstpage, "pages shared within generation")
local cached_result = query.run("LIST", sharedctx)
check(cached_result.ok and sharedctx.pages[index_path] == firstpage, "query reuses existing page")
idx_mod.invalidate()
idx_mod.get({ root = index_root }, function(result)
  shared_index = result
end)
check(shared_index ~= indexed and shared_index.pages[index_path] == nil, "invalidation replaces page generation")
local spage = page_mod.build(index_path, rows[index_path], { root = index_root })
check(spage.file.size == 12 and spage.file.mtime.ts == 10, "page reads nested stat (size, mtime)")
-- relative markdown links resolve against the linking note's folder first
local rel_root = "/relvault"
rows = {
  [rel_root .. "/peer.md"] = { stat = {} },
  [rel_root .. "/sub/peer.md"] = { stat = {} },
  [rel_root .. "/sub/source.md"] = { stat = {}, links_out = { { target = "peer.md", kind = "markdown" } } },
}
idx_mod.get({ root = rel_root }, function(result)
  indexed = result
end)
check(
  indexed.inlinks[rel_root .. "/sub/peer.md"] and not indexed.inlinks[rel_root .. "/peer.md"],
  "markdown link resolves to the sibling note"
)
local out_res = query.run("LIST FROM outgoing([[sub/source]])", { index = rows, root = rel_root })
check(
  out_res.ok
    and #out_res.data.groups[1].items == 1
    and out_res.data.groups[1].items[1].path == rel_root .. "/sub/peer.md",
  "outgoing() resolves relative markdown targets"
)
local resolve = idx_mod.make_resolver(rows)
check(resolve("missing", rel_root) == nil, "missing link name stays unresolved")
check(resolve("sub/peer", rel_root) == rel_root .. "/sub/peer.md", "resolver accepts vault relative paths")
check(
  resolve("peer.md", rel_root, rel_root .. "/sub/source.md", true) == rel_root .. "/sub/peer.md",
  "resolver accepts source relative paths"
)
package.loaded["obsidian.cache"], _G.Obsidian = saved_cache, saved_obsidian
vim.fn.delete(index_path)

---------------------------------------------------------------- audit regressions
group = "audit"
check(ev("file.mday = date(2026-07-01)") == true, "file.mday is a day value (midnight)")
local tomorrow = ev("date(tomorrow)")
check(tomorrow.hour == 0 and tomorrow.day == 29, "date(tomorrow) is next local midnight")
check(ev("date(eom)").day == 31 and ev("date(eom)").hour == 0, "date(eom) is the month's last midnight")
check(
  ev('length(unique([1, 1, "1", date(2026-07-01), date(2026-07-01), [[a]], [[A]], [1], [1]]))') == 6,
  "unique() dedupes scalars, dates, links and arrays"
)
check(F.regexreplace(env, { '"foo"', "\\b(foo)", "$1" }) == '"foo"', "\\b adds no capture group")
check(F.regexreplace(env, { "a foo b", "(?<=a )(foo)", "[$1]" }) == "a [foo] b", "lookaround adds no capture group")
res = run('TABLE x FROM "Journal" FLATTEN [] AS x')
check(res.ok and #res.data.rows == 0, "FLATTEN [] yields no rows")
res = run("LIST WITHOUT ID false")
check(res.ok and res.data.groups[1].items[1].text == false, "LIST WITHOUT ID keeps a false value")
res = run("TABLE length(rows) GROUP BY priority = 1")
local false_id = false
for _, r in ipairs(res.data.rows) do
  false_id = false_id or r.id == false
end
check(res.ok and false_id, "false group key survives as the row ID")
res = run("LIST WITHOUT ID file.name GROUP BY status")
check(res.ok and res.data.groups[1].items[1].link == nil, "grouped LIST honours WITHOUT ID")
res = run('TABLE length(rows) GROUP BY choice(priority = 1, ["a, b"], ["a", "b"])')
check(res.ok and #res.data.rows == 2, "GROUP BY splits values that merely display alike")

do
  group = "link dereference"
  local deref = run('TABLE [[2026-07-10]].status, file.inlinks.status FROM "Journal/2026-07-01"')
  check(deref.ok and deref.data.rows[1].cells[1] == "done", "link literal dereferences to page")
  check(deref.data.rows[1].cells[2][1] == "done", "inlinks swizzle dereferences pages")
  deref = run("TABLE rows.file.link.status GROUP BY status")
  check(deref.ok and deref.data.rows[1].cells[1][1] ~= value.NULL, "grouped rows swizzle dereferences links")
  deref = run("TABLE [[missing]].status, [[2026-07-10]].path LIMIT 1")
  check(
    deref.ok and deref.data.rows[1].cells[1] == value.NULL and deref.data.rows[1].cells[2] == value.NULL,
    "missing pages and link metadata index return null"
  )
  local projectctx = vim.deepcopy(CTX)
  projectctx.index[ROOT .. "/Papers/reading.md"].properties.project = "[[2026-07-10]]"
  deref = query.run('TABLE project.status FROM "Papers"', projectctx)
  check(deref.ok and deref.data.rows[1].cells[1] == "done", "frontmatter link dereference")

  group = "link identity"
  local identctx = vim.deepcopy(CTX)
  identctx.this_path = ROOT .. "/Journal/2026-07-01.md"
  identctx.index[ROOT .. "/Papers/reading.md"].properties.project = "[[2026-07-01]]"
  local identity = query.run(
    'TABLE contains(file.outlinks, this.file.link), project = this.file.link, [[2026-07-01]] = this.file.link, link("2026-07-01") = this.file.link FROM "Papers"',
    identctx
  )
  for _, cell in ipairs(identity.data.rows[1].cells) do
    check(cell == true, "outlinks, frontmatter, literals and link() use resolved paths")
  end
  local sublink = value.link("Folder/Note#Heading")
  check(
    sublink.path == "Folder/Note" and sublink.subpath == "Heading" and sublink.kind == "header",
    "link subpaths are separate from identity path"
  )
  local unresolved = query.run('TABLE link("missing"), [[missing]] LIMIT 1', vim.tbl_extend("force", {}, CTX))
  check(
    unresolved.data.rows[1].cells[1].path == "missing" and unresolved.data.rows[1].cells[2].path == "missing",
    "unresolved links retain their paths"
  )

  group = "missing functions"
  check(ev('icontains(["Hello", ["World"]], "WORLD")') == true, "icontains recurses and ignores case")
  check(value.eq(ev('icontains("Alpha", ["AL", "z"])'), value.array({ true, false })), "icontains vectorizes needles")
  check(ev("product([2, 3, 4])") == 24 and ev("product([])") == value.NULL, "product values and empty array")
  check(ev('reduce([10, 2, 3], "-")') == 5, "reduce folds operators left to right")
  check(ev("reduce([2, null, 3], (a, b) => a * b)") == 6, "reduce lambda skips nulls")
  check(ev('reduce([true, false], "&")') == false, "reduce boolean operators")
  check(value.eq(ev("ldefault([null, 1], 2)"), value.array({ value.NULL, 1 })), "ldefault preserves arrays")
  check(ev("ldefault(null, false)") == false, "ldefault preserves false fallback")
  check(ev("firstvalue([null, false, 3])") == false and ev("firstvalue([])") == value.NULL, "firstvalue keeps false")
  check(
    ev('display([null, "**bold**", [[Folder/Note|Label]]])') == ", bold, Label",
    "display strips markdown and uses link display"
  )

  group = "settings"
  local settings_mod = require("obsidian-query.dataview.settings")
  local settings_root = vim.fn.tempname()
  check(settings_mod.get(settings_root).defaultDateFormat == "MMMM dd, yyyy", "missing settings use Dataview defaults")
  vim.fn.mkdir(settings_root .. "/.obsidian/plugins/dataview", "p")
  local settings_path = settings_root .. "/.obsidian/plugins/dataview/data.json"
  vim.fn.writefile({ '{"showResultCount":false,"tableIdColumnName":"Note","inlineQueryPrefix":"?"}' }, settings_path)
  local custom_settings = settings_mod.get(settings_root)
  check(not custom_settings.showResultCount and custom_settings.inlineQueryPrefix == "?", "vault settings read")
  check(
    custom_settings.warnOnEmptyResult and custom_settings.renderNullAs == "\\-",
    "missing settings keys retain defaults"
  )
  check(settings_mod.get(settings_root) == custom_settings, "settings cached by timestamp")
  local custom_query = query.run("TABLE file.name", { index = INDEX, root = settings_root })
  check(custom_query.data.columns[1] == "Note", "custom table ID column name")
  vim.fn.writefile({ '{"renderNullAs":"none"}' }, settings_path)
  check(settings_mod.get(settings_root).renderNullAs == "none", "settings cache refreshed after edit")
  vim.fn.writefile({ "broken json" }, settings_path)
  check(settings_mod.get(settings_root).showResultCount, "malformed settings use defaults")
  local tracking =
    vim.tbl_extend("force", settings_mod.defaults, { taskCompletionTracking = true, taskCompletionText = "done" })
  local tracked = dv_engine.toggle_task_line("- [ ] work ^block", nil, tracking)
  check(tracked == "- [x] work [done:: " .. os.date("%Y-%m-%d") .. "] ^block", "completion field before block ID")
  check(dv_engine.toggle_task_line(tracked, nil, tracking) == "- [ ] work ^block", "reopening removes completion field")
  tracking.taskCompletionUseEmojiShorthand = true
  tracked = dv_engine.toggle_task_line("- [ ] work", nil, tracking)
  check(tracked == "- [x] work ✅ " .. os.date("%Y-%m-%d"), "emoji completion date")
  check(dv_engine.toggle_task_line(tracked, nil, tracking) == "- [ ] work", "reopening removes emoji completion")
  vim.fn.delete(settings_root, "rf")

  group = "render parity"
  local rendered_table = flatten(dv_render.lines(run("TABLE status")))
  check(rendered_table[2]:find("File (3)", 1, true) ~= nil, "table result count in first header")
  local rendered_noid = flatten(dv_render.lines(run("TABLE WITHOUT ID status")))
  check(rendered_noid[2]:find("status (3)", 1, true) ~= nil, "WITHOUT ID still counts first column")
  for _, kind in ipairs({ "TABLE status", "LIST", "TASK" }) do
    local empty = run(kind .. " FROM #missing")
    check(
      table.concat(flatten(dv_render.lines(empty))):find("Dataview: No results to show", 1, true) ~= nil,
      "empty warning for " .. kind
    )
    empty.data.settings = vim.tbl_extend("force", empty.data.settings, { warnOnEmptyResult = false })
    check(
      not table.concat(flatten(dv_render.lines(empty))):find("No results", 1, true),
      "empty warning can be disabled"
    )
  end
  local grouped_list = run("LIST length(rows) GROUP BY status")
  check(#grouped_list.data.groups == 1 and #grouped_list.data.groups[1].items == 2, "grouped LIST projects group rows")
  check(grouped_list.data.groups[1].items[1].text == 2, "grouped LIST evaluates length(rows) on group")
  local grouped_false = run("LIST GROUP BY priority = 1")
  check(grouped_false.data.groups[1].items[1].link == false, "grouped LIST preserves false key")
  local grouped_table = run("TABLE length(rows) GROUP BY status")
  check(grouped_table.data.columns[1] == "status", "grouped table header is group expression")
  local task_lines = flatten(dv_render.lines(run('TASK FROM "Journal" WHERE !completed')))
  check(
    #task_lines == 2 and task_lines[2]:find("sub uno", 1, true),
    "TASK includes selected parent's children with no file header"
  )
  local all_task_lines = flatten(dv_render.lines(run('TASK FROM "Journal"')))
  check(#all_task_lines == 3, "TASK children rendered once")
  local group_task_lines = flatten(dv_render.lines(run('TASK FROM "Journal" GROUP BY completed')))
  check(group_task_lines[1]:find("false (1)", 1, true), "task groups have counts")
  check(value.to_display(value.parse_date("2026-07-01T00:00")) == "July 01, 2026", "midnight datetime uses date format")
  local fmt_settings = vim.tbl_extend(
    "force",
    require("obsidian-query.dataview.settings").defaults,
    { defaultDateFormat = "dd/MM/yyyy", renderNullAs = "none" }
  )
  check(
    value.to_display(value.parse_date("2026-07-01"), fmt_settings) == "01/07/2026"
      and value.to_display(value.NULL, fmt_settings) == "none",
    "custom rendering settings"
  )
  check(
    value.to_display(value.link("Folder/image.png#Header")) == "image.png > Header",
    "link display preserves attachment extensions and subpaths"
  )

  group = "unsaved this"
  local unsavedbuf = vim.api.nvim_create_buf(true, false)
  local unsavedpath = ROOT .. "/Journal/2026-07-01.md"
  vim.api.nvim_buf_set_name(unsavedbuf, unsavedpath)
  vim.api.nvim_buf_set_lines(
    unsavedbuf,
    0,
    -1,
    false,
    { "---", "status: draft", "---", "session-goal:: unsaved", "- [ ] changed" }
  )
  local unsavedidx = { rows = INDEX, sup = SUP, inlinks = INLINKS, pages = {} }
  local unsavedpage = idx_mod.this_page(unsavedidx, unsavedbuf, ROOT)
  check(
    unsavedpage.status == "draft" and unsavedpage["session-goal"] == "unsaved",
    "unsaved frontmatter and inline fields"
  )
  check(unsavedpage.file.tasks[1].text == "changed", "unsaved tasks")
  check(idx_mod.this_page(unsavedidx, unsavedbuf, ROOT) == unsavedpage, "buffer page cached by changedtick")
  local unsavedresult = query.run(
    'TABLE this.status, status FROM "Journal/2026-07-01"',
    vim.tbl_extend("force", {}, CTX, { this = unsavedpage, this_path = unsavedpath })
  )
  check(
    unsavedresult.data.rows[1].cells[1] == "draft" and unsavedresult.data.rows[1].cells[2] == "open",
    "only this sees unsaved content"
  )
  vim.api.nvim_buf_set_lines(unsavedbuf, 1, 2, false, { "status: revised" })
  check(idx_mod.this_page(unsavedidx, unsavedbuf, ROOT).status == "revised", "buffer page refreshes after edit")
  vim.bo[unsavedbuf].modified = false
  check(idx_mod.this_page(unsavedidx, unsavedbuf, ROOT).status == "open", "unmodified buffers use saved page")
  vim.api.nvim_buf_delete(unsavedbuf, { force = true })

  do
    group = "property completion"
    local core = require("obsidian-query")
    local saved_root, saved_gen = core.buf_root, core.generation
    local saved_cache, saved_types = package.loaded["obsidian.cache"], package.loaded["blink.cmp.types"]
    core.buf_root = function()
      return ROOT
    end
    core.generation = function()
      return 999
    end
    package.loaded["obsidian.cache"] = {
      is_enabled = function()
        return true
      end,
      is_ready = function()
        return true
      end,
      notes = {
        all = function()
          return INDEX
        end,
      },
    }
    package.loaded["blink.cmp.types"] = { CompletionItemKind = { Value = 12 } }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "```dataview", "LIST" })
    local source = require("obsidian-query.blink").new()
    for _, prefix in ipairs({
      'WHERE status = "',
      'WHERE status != "',
      'WHERE contains(status, "',
      'FROM "Journal" WHERE status = "d',
      "WHERE icontains(status, '",
    }) do
      local completion
      source:get_completions({ bufnr = buf, cursor = { 2, #prefix }, line = prefix }, function(result)
        completion = result
      end)
      check(
        #completion.items == 2 and completion.items[1].label == "done" and completion.items[2].label == "open",
        "property values for " .. prefix
      )
      check(
        completion.items[1].textEdit.range["end"].character == #prefix,
        "value completion replaces current string content"
      )
    end
    local completion
    local prefix = 'FROM "'
    source:get_completions({ bufnr = buf, cursor = { 2, #prefix }, line = prefix }, function(result)
      completion = result
    end)
    check(#completion.items == 2 and completion.items[1].label == "Journal", "FROM still completes folders")
    vim.api.nvim_buf_delete(buf, { force = true })
    core.buf_root, core.generation = saved_root, saved_gen
    package.loaded["obsidian.cache"], package.loaded["blink.cmp.types"] = saved_cache, saved_types
  end

  group = "wide rendering"
  local wide = require("obsidian-query.render").clip(string.rep("界", 30), 40)
  check(vim.fn.strdisplaywidth(wide) <= 40 and wide:sub(-3) == "…", "clip counts display columns for wide characters")
  local wide_table =
    dv_render.table_lines({ columns = { "text" }, with_id = false, rows = { { cells = { string.rep("界", 30) } } } })
  check(#wide_table == 5, "wide table cell renders without negative padding")

  do
    group = "sparse cache health"
    local saved_cache, saved_ob = package.loaded["obsidian.cache"], _G.Obsidian
    _G.Obsidian = nil
    package.loaded["obsidian.cache"] = {
      is_enabled = function()
        return true
      end,
      is_ready = function()
        return true
      end,
      notes = {
        count = function()
          return 1
        end,
        all = function()
          return { ["/v/a.md"] = { stat = {} } }
        end,
      },
    }
    local saved, errors = {}, {}
    for _, method in ipairs({ "start", "ok", "warn", "error" }) do
      saved[method] = vim.health[method]
      vim.health[method] = function(msg)
        if method == "error" then
          errors[#errors + 1] = msg
        end
      end
    end
    require("obsidian-query.health").check()
    check(not table.concat(errors):find("cache row", 1, true), "health accepts omitted optional tags and properties")
    local saved_add = vim.treesitter.language.add
    vim.treesitter.language.add = function(language)
      if language == "markdown_inline" then
        error("missing parser")
      end
      return true
    end
    require("obsidian-query.health").check()
    check(
      table.concat(errors):find("markdown_inline parser missing", 1, true),
      "health checks inline expression parser"
    )
    vim.treesitter.language.add = saved_add
    for method, fn in pairs(saved) do
      vim.health[method] = fn
    end
    package.loaded["obsidian.cache"], _G.Obsidian = saved_cache, saved_ob
  end

  group = "link immutability"
  local original_link = value.link("Note.md", { subpath = "H", kind = "header", display = "original" })
  local relabeled = F.link(env, { original_link, "changed" })
  check(
    relabeled.display == "changed" and original_link.display == "original",
    "link() display override leaves shared link unchanged"
  )
  check(relabeled.kind == "header" and relabeled.subpath == "H", "link() display override preserves link metadata")

  group = "predicate parity"
  check(ev('contains(["hello", ["world"]], "world")') == true, "contains recurses into nested arrays")
  check(
    ev('contains("Hello", "hello")') == false and ev('icontains("Hello", "hello")') == true,
    "contains and icontains differ in case"
  )
  check(ev("contains(3, 3)") == true and ev("econtains(null, null)") == true, "contains scalar equality")
  check(value.eq(ev('contains("hello", ["he", "z"])'), value.array({ true, false })), "contains vectorizes needles")
  check(
    value.eq(ev("default([null, 1, 2], [3, 4])"), value.array({ 3, 1 })),
    "default zips vectorized arguments to shortest array"
  )
  check(
    value.eq(ev('startswith(["abc", "xyz"], ["a", "q"])'), value.array({ true, false })),
    "string functions zip arguments"
  )
  check(value.eq(ev("choice([true, false], 1, 2)"), value.array({ 1, 2 })), "choice vectorizes predicate")

  group = "regex parity"
  check(ev('regexmatch("[a-z]+", "alpha")') == true, "regexmatch takes pattern first")
  check(ev('regexmatch("[a-z]+", "alpha1")') == false, "regexmatch anchors unanchored patterns")
  check(ev('regextest("[a-z]+", "alpha1")') == true, "regextest permits partial match")
  check(ev('regexmatch(null, "text")') == false, "regex null input is false")

  group = "value parity"
  check(ev("[10, 20][0]") == 10 and ev("[10, 20][1]") == 20, "DQL array indexing is zero-based")
  check(ev("[10][-1]") == value.NULL and ev("[10][1]") == value.NULL, "array indexing rejects out-of-bounds values")
  check(ev('"abc"[1]') == "b", "DQL string indexing")
  check(
    value.cmp(value.array({}), false) < 0 and value.cmp(value.date(0), 1) < 0,
    "cross-type order uses Dataview type names"
  )
  check(not value.eq(value.link("missing"), value.link("MISSING")), "unresolved links are case-sensitive")
  check(not value.eq(value.link("a#H"), value.link("a#^H")), "header and block links have different identities")

  group = "group order"
  local ordered_groups = run("TABLE status, length(rows) GROUP BY status")
  check(
    ordered_groups.data.rows[1].id == "done" and ordered_groups.data.rows[2].id == "open",
    "GROUP BY sorts keys ascending"
  )
  check(ordered_groups.data.rows[1].cells[1] == "done", "GROUP BY exposes unaliased expression name")

  group = "collection functions"
  check(ev('reverse("café")') == "éfac", "reverse preserves UTF-8 string characters")
  check(value.eq(ev("slice([1, 2, 3, 4], -3, -1)"), value.array({ 2, 3 })), "slice supports negative bounds")
  check(value.eq(ev("nonnull(null, 2, false)"), value.array({ 2, false })), "nonnull accepts varargs")
  check(ev("any(false, true)") == true and ev("all(true, false)") == false, "boolean aggregates accept varargs")
  check(ev("sum([1, null, 2])") == value.NULL, "sum does not reset accumulation after null")
  check(ev("average(4)") == 4 and ev("average([])") == value.NULL, "average scalar and empty array")
  check(
    ev('extract([[2026-07-10]], "status").status') == value.NULL,
    "unresolved extract without resolver returns null"
  )
  local extracted = run('TABLE extract([[2026-07-10]], "status") LIMIT 1')
  check(extracted.data.rows[1].cells[1].status == "done", "extract dereferences links")
  check(ev("meta(embed([[x]])).embed") == true, "embed sets link metadata")
  check(ev("minby([1, 2], (x) => null)") == 1, "minby keeps first element when all keys null")
  check(ev("maxby([false, true], (x) => null)") == false, "maxby preserves false first element")

  group = "resolver ambiguity"
  local resolver_rows =
    { ["/v/A/Note.md"] = {}, ["/v/B/Note.md"] = {}, ["/v/Note.md"] = {}, ["/v/Deep/Folder/Other.md"] = {} }
  local resolver = idx_mod.make_resolver(resolver_rows)
  check(resolver("Note", "/v", "/v/B/source.md") == "/v/Note.md", "vault exact path wins for wiki links")
  check(
    resolver("Note.md", "/v", "/v/B/source.md", true) == "/v/B/Note.md",
    "markdown targets resolve relative to source"
  )
  check(resolver("Folder/Other", "/v") == "/v/Deep/Folder/Other.md", "partial folder suffix resolves")
  check(resolver("Missing/Other", "/v") == nil, "missing folder does not resolve by basename alone")
  check(resolver("/Missing/Note", "/v") == nil, "absolute vault link cannot fall back to basename")
  check(resolver("deep/folder/other", "/v") == "/v/Deep/Folder/Other.md", "path lookup ignores case")
  check(resolver("", "/v", "/v/B/Note.md") == "/v/B/Note.md", "empty link resolves containing note")
end

---------------------------------------------------------------- checkboxes
group = "checkbox"
local base = require("obsidian-query.render")
local cfg_mod = require("obsidian-query.config")
cfg_mod.set({ icons = "nerd" })
-- stub render-markdown: it isn't on the rtp here, and this is exactly the shape
-- obsidian-query reads out of it (state.get(buf).checkbox)
package.loaded["render-markdown.state"] = {
  get = function()
    return {
      bullet = { icons = { "B" } },
      checkbox = {
        enabled = true,
        unchecked = { icon = "U ", highlight = "Unch" },
        checked = { icon = "C ", highlight = "Ch", scope_highlight = "Strike" },
        custom = { todo = { raw = "[-]", rendered = "T", highlight = "Todo" } },
      },
    }
  end,
}
local open, done, todo = base.checkbox(" "), base.checkbox("x"), base.checkbox("-")
check(open.icon == "U " and open.highlight == "Unch", "unchecked comes from render-markdown")
check(done.icon == "C " and done.scope_highlight == "Strike", "checked keeps its scope highlight")
check(todo.icon == "T " and todo.highlight == "Todo", "custom raw state -> rendered glyph, padded")
check(base.checkbox("X").icon == "C ", "uppercase X is checked")
local odd = base.checkbox("~")
check(odd.icon == "B ~ " and odd.highlight == "RenderMarkdownBullet", "unconfigured state -> bullet + raw char")
package.loaded["render-markdown.state"] = nil
check(base.checkbox("-").icon == "[-] ", "no render-markdown -> literal state")
cfg_mod.set({ icons = "ascii" })
check(base.checkbox("-").icon == "[-] ", "ascii keeps the raw state")
check(base.checkbox("x").highlight == "RenderMarkdownChecked", "ascii still highlights done tasks")
cfg_mod.set({ icons = "auto" })

---------------------------------------------------------------- picker title
group = "title"
local fres = run('TABLE file.name FROM "Journal"')
check(fres.ok and fres.data.from and fres.data.from.k == "s_folder", "FROM folder exposed on result")
check(fres.data.from.folder == "Journal", "folder name kept for the title")
local tagres = run("LIST FROM #día")
check(tagres.data.from.k == "s_tag" and tagres.data.from.tag == "día", "FROM tag exposed")
check(run("LIST").data.from == nil, "no FROM -> no source on result")

-- Closing a picker must restart refreshes that were skipped while it was open.
do
  group = "picker close refresh"
  local saved_ts, saved_text = vim.treesitter.query.parse, vim.treesitter.get_node_text
  local saved_retry, saved_get = base.retry, idx_mod.get
  local saved_ob = _G.Obsidian
  local modules = {}
  for _, name in ipairs({ "obsidian.api", "obsidian-query.highlight", "render-markdown.api", "obsidian.lsp.watchfiles" }) do
    modules[name] = package.loaded[name] or false
  end
  local note = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(note, ROOT .. "/remaining.md")
  vim.api.nvim_buf_set_lines(note, 0, -1, false, { "```dataview", "TASK WHERE !completed", "```", "" })
  vim.api.nvim_set_current_buf(note)
  local lang, body = { text = "dataview" }, { text = "TASK WHERE !completed" }
  local block = {
    range = function()
      return 0, 0, 3, 0
    end,
  }
  local fence_on = true
  vim.treesitter.query.parse = function()
    return {
      captures = { "lang", "body", "block" },
      iter_matches = function()
        local done = false
        return function()
          if not done and fence_on then
            done = true
            return 1, { { lang }, { body }, { block } }
          end
        end
      end,
    }
  end
  vim.treesitter.get_node_text = function(node)
    return node.text
  end
  package.loaded["obsidian-query.highlight"] = { attach = function() end }
  package.loaded["obsidian.api"] = {
    find_workspace = function()
      return { path = ROOT, root = ROOT }
    end,
  }
  _G.Obsidian = { workspace = { path = ROOT, root = ROOT }, dir = ROOT }
  local changed
  package.loaded["obsidian.lsp.watchfiles"] = {
    register_handler = function(cb)
      changed = cb
    end,
  }
  local rows = vim.deepcopy(INDEX)
  idx_mod.get = function(_, cb)
    cb({ rows = rows, sup = SUP, inlinks = INLINKS })
  end
  base.retry = function() end -- model the bounded retries having expired
  local core = require("obsidian-query")
  local count
  local function draw()
    local marks = core.parse({ buf = note })
    local lines = marks[1].opts.virt_lines
    count = table.concat(flatten(lines), "\n")
  end
  package.loaded["render-markdown.api"] = {
    render = function()
      if vim.api.nvim_get_current_buf() == note then
        draw()
      end
    end,
  }
  draw()
  check(count:find("align #lab", 1, true) ~= nil, "initial remaining task count")
  local picker_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(picker_buf)
  rows[ROOT .. "/Journal/2026-07-01.md"].tasks[1].state = "x"
  changed()
  vim.wait(20, function()
    return false
  end)
  check(count:find("align #lab", 1, true) ~= nil, "refresh skipped while picker was open")
  vim.api.nvim_set_current_buf(note)
  check(
    vim.wait(200, function()
      return count:find("No results to show for task query", 1, true) ~= nil
    end),
    "closing picker refreshes remaining count"
  )
  local fetches = 0
  idx_mod.get = function(_, cb)
    fetches = fetches + 1
    cb({ rows = rows, sup = SUP, inlinks = INLINKS })
  end
  vim.api.nvim_set_current_buf(picker_buf)
  vim.api.nvim_set_current_buf(note)
  vim.wait(20, function()
    return false
  end)
  check(fetches == 0, "entering an unchanged note reruns no query")
  fence_on = false
  core.parse({ buf = note })
  fence_on = true
  local before = fetches
  draw()
  check(fetches == before + 1, "a fence gone from the buffer releases its cache entry")
  body.text = "  LIST\nWHERE )"
  vim.api.nvim_buf_set_lines(note, 0, -1, false, { "```dataview", "  LIST", "WHERE )", "```" })
  draw()
  local dns = vim.api.nvim_get_namespaces()["obsidian-query"]
  local diags = vim.diagnostic.get(note, { namespace = dns })
  check(#diags == 1 and diags[1].lnum == 2 and diags[1].col == 6, "diagnostic points inside fence at parse error")
  body.text = "LIST"
  draw()
  check(#vim.diagnostic.get(note, { namespace = dns }) == 0, "fixed query clears diagnostic")
  body.text = "LIST WHERE )"
  draw()
  fence_on = false
  core.parse({ buf = note })
  check(#vim.diagnostic.get(note, { namespace = dns }) == 0, "removed fence clears diagnostic")
  vim.api.nvim_del_augroup_by_name("obsidian_query_stale")
  vim.api.nvim_buf_delete(picker_buf, { force = true })
  vim.api.nvim_buf_delete(note, { force = true })
  vim.treesitter.query.parse, vim.treesitter.get_node_text = saved_ts, saved_text
  base.retry, idx_mod.get, _G.Obsidian = saved_retry, saved_get, saved_ob
  for name, module in pairs(modules) do
    package.loaded[name] = module or nil
  end
end

-- A write landing while the inline index request is in flight must leave the
-- returned index stale, so the next parse asks again.
do
  group = "inline stale race"
  local inline = require("obsidian-query.inline")
  local core = require("obsidian-query")
  local saved_root, saved_get, saved_retry = core.buf_root, idx_mod.get, base.retry
  local saved_rm = package.loaded["render-markdown.api"]
  package.loaded["render-markdown.api"] = { render = function() end }
  base.retry = function() end
  local path = ROOT .. "/Journal/2026-07-01.md"
  core.buf_root = function()
    return ROOT
  end
  local calls, pending_cb = 0, nil
  idx_mod.get = function(_, cb)
    calls = calls + 1
    pending_cb = cb
  end
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, path)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x `= file.name` y" })
  local function parse()
    local ltree = vim.treesitter.get_parser(buf, "markdown")
    ltree:parse(true)
    local marks
    ltree:for_each_tree(function(tree, lt)
      if lt:lang() == "markdown_inline" then
        marks = inline.parse({ buf = buf, root = tree:root() })
      end
    end)
    return marks
  end
  inline.invalidate()
  check(#parse() == 0 and calls == 1, "first parse requests the index")
  vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })
  pending_cb({ rows = INDEX, sup = SUP, inlinks = INLINKS })
  local marks = parse()
  check(#marks == 1 and marks[1].opts.virt_text[1][1] == "2026-07-01", "result renders")
  check(calls == 2, "write during the request re-requests the index")
  inline.invalidate() -- workspace switch: obsidian.nvim drops the queued callback
  parse()
  check(calls == 3, "a request stranded by a cache reset is retried")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "---", "status: draft", "---", "x `= this.status` y" })
  pending_cb({ rows = INDEX, sup = SUP, inlinks = INLINKS })
  marks = parse()
  check(#marks == 1 and marks[1].opts.virt_text[1][1] == "draft", "inline this reflects unsaved frontmatter")
  inline.invalidate()
  vim.api.nvim_buf_delete(buf, { force = true })
  core.buf_root, idx_mod.get, base.retry = saved_root, saved_get, saved_retry
  package.loaded["render-markdown.api"] = saved_rm
end

do
  group = "shared index races"
  local saved_cache, saved_ob = package.loaded["obsidian.cache"], _G.Obsidian
  _G.Obsidian = nil
  local ready, requests = nil, 0
  package.loaded["obsidian.cache"] = {
    is_enabled = function()
      return true
    end,
    when_ready = function(cb)
      requests = requests + 1
      ready = cb
    end,
    notes = {
      all = function()
        return {}
      end,
    },
  }
  idx_mod.invalidate()
  local first, second
  idx_mod.get({ root = "/race" }, function(result)
    first = result
  end)
  idx_mod.get({ root = "/race" }, function(result)
    second = result
  end)
  check(requests == 1, "concurrent fences coalesce one index request")
  ready()
  check(first ~= nil and first == second, "concurrent fences share completed index")
  idx_mod.invalidate()
  local obsolete, transient
  idx_mod.get({ root = "/race" }, function(result, _, retry)
    obsolete, transient = result, retry
  end)
  idx_mod.invalidate()
  ready()
  check(obsolete == nil and transient == true, "invalidation rejects queued old generation")
  idx_mod.get({ root = "/race" }, function(result)
    first = result
  end)
  _G.Obsidian = { dir = "/other" }
  ready()
  check(first == nil, "workspace switch while waiting cannot publish another vault's index")
  idx_mod.invalidate()
  package.loaded["obsidian.cache"], _G.Obsidian = saved_cache, saved_ob
end

do
  group = "hash parity"
  check(ev('hash("hello", 0)') == 4625896200565286, "hash matches bundled cyrb53")
  check(ev('hash("hello", 7)') == 5198064567490728, "hash accepts numeric variant")
  check(ev('hash("hel", "lo")') == ev('hash("hello", 0)'), "hash concatenates string seed and text")
  check(ev('hash("café🧪", 0)') == 1515590994826948, "hash uses UTF-16 code units")
end

do
  group = "lexical error positions"
  local _, lexical = parser.parse("LIST\nWHERE @")
  check(lexical.pos == 12, "lexical errors retain byte position for diagnostics")
  local _, quoted = parser.parse('LIST "unterminated')
  check(quoted.pos == 6, "unterminated strings diagnose opening quote")
end

do
  group = "typed inline fields"
  local fields = idx_mod.inline_fields("text [project:: [[Folder/Note|Label]]] (score:: 3)")
  check(
    #fields == 2 and fields[1].value == "[[Folder/Note|Label]]",
    "balanced inline fields preserve nested wiki links"
  )
  check(
    page_mod.decode_inline("3") == 3 and page_mod.decode_inline("false") == false,
    "inline numbers and booleans are typed"
  )
  check(page_mod.decode_inline("") == value.NULL, "empty inline field is null")
  check(
    value.eq(page_mod.decode_inline('"one", "two"'), value.array({ "one", "two" })),
    "typed comma-separated inline array"
  )
  local ctx = vim.tbl_extend("force", {}, CTX, {
    sup = { [ROOT .. "/Papers/reading.md"] = { fields = { project = "[[2026-07-10]]", score = "4" }, headers = {} } },
  })
  local typed = query.run('TABLE project.status, score FROM "Papers"', ctx)
  check(
    typed.data.rows[1].cells[1] == "done" and typed.data.rows[1].cells[2] == 4,
    "inline project dereferences with numeric fields"
  )
  local task =
    page_mod.build_tasks("/v/n.md", { { line = 1, text = "[score:: 2] [project:: [[Note]]]" } }, {}, "n.md")[1]
  check(
    task.score == 2 and task.project.path == "Note" and not task.checked,
    "task fields use shared parser and absent status is open"
  )
end

do
  group = "date validation"
  check(
    value.parse_date("2026-02-30") == value.NULL and value.parse_date("2026-13-01") == value.NULL,
    "invalid calendar dates are null"
  )
  check(value.parse_date("2026-07-01T25:00") == value.NULL, "invalid times are null")
  check(page_mod.decode_fm("2026-07-01 16:05") == "2026-07-01 16:05", "space-separated datetime stays text")
  check(value.typeof(page_mod.decode_fm("2026-07-01T16:05")) == "date", "T-separated datetime is a date")
  check(page_mod.decode_fm("2026-07-01 prose") == "2026-07-01 prose", "frontmatter date parsing consumes full value")
  check(
    value.eq(value.parse_date("2026-07-01T12:30:00Z"), value.parse_date("2026-07-01T06:30:00-06:00")),
    "timestamp offsets identify same instant"
  )
  local millis = value.parse_date("2026-07-01T12:30:00.123Z")
  check(
    millis.millisecond == 123 and F.dateformat(env, { millis, "SSS" }) == "123",
    "fractional seconds survive parsing"
  )
  check(
    value.parse_dur("-2 days").ms == -2 * 86400000 and value.parse_dur("250 ms").ms == 250,
    "signed durations and milliseconds"
  )
  check(value.parse_dur("2 days ago") == value.NULL, "duration parsing rejects trailing prose")
  check(value.typeof(page_mod.decode_fm("2 days")) == "duration", "frontmatter durations are typed")
end

do
  group = "settings refresh"
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/.obsidian/plugins/dataview", "p")
  root = vim.uv.fs_realpath(root)
  local path = root .. "/.obsidian/plugins/dataview/data.json"
  local spec = dv_engine.parse("TABLE file.name")
  local before = dv_engine.key(spec, { root = root })
  vim.fn.writefile({ '{"showResultCount":false}' }, path)
  check(dv_engine.key(spec, { root = root }) ~= before, "settings edits invalidate fence result identity")
  local core, inline = require("obsidian-query"), require("obsidian-query.inline")
  local saved_root, saved_get, saved_retry = core.buf_root, idx_mod.get, base.retry
  local saved_rm = package.loaded["render-markdown.api"]
  package.loaded["render-markdown.api"] = { render = function() end }
  base.retry = function() end
  core.buf_root = function()
    return root
  end
  idx_mod.get = function(_, cb)
    cb({ rows = {}, sup = {}, inlinks = {}, pages = {} })
  end
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, root .. "/note.md")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a `? 2 + 3` b `= 1`" })
  vim.fn.writefile({ '{"inlineQueryPrefix":"?"}' }, path)
  inline.invalidate()
  local function draw()
    local parser = vim.treesitter.get_parser(buf, "markdown")
    parser:parse(true)
    local marks = {}
    parser:for_each_tree(function(tree, lang)
      if lang:lang() == "markdown_inline" then
        marks = inline.parse({ buf = buf, root = tree:root() })
      end
    end)
    return marks
  end
  local marks = draw()
  check(#marks == 1 and marks[1].opts.virt_text[1][1] == "5", "custom inline query prefix is evaluated")
  vim.fn.writefile({ '{"enableInlineDataview":false}' }, path)
  check(#draw() == 0, "inline setting disables rendered values")
  inline.invalidate()
  vim.api.nvim_buf_delete(buf, { force = true })
  core.buf_root, idx_mod.get, base.retry = saved_root, saved_get, saved_retry
  package.loaded["render-markdown.api"] = saved_rm
  vim.fn.delete(root, "rf")
end

do
  group = "unsaved link exclusions"
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, "/v/unsaved.md")
  local lines = { "[[Visible]]", "```dataview", "LIST [[Hidden]]", "```" }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local page = idx_mod.this_page({ rows = {}, sup = {}, inlinks = {} }, buf, "/v")
  check(#page.file.outlinks == 1 and page.file.outlinks[1].path == "Visible", "unsaved outlinks exclude fenced code")
  check(page.file.size == #table.concat(lines, "\n") + 1, "unsaved page size follows buffer content")
  vim.api.nvim_buf_delete(buf, { force = true })
end

do
  group = "inline property completion"
  local core = require("obsidian-query")
  local saved_root, saved_gen, saved_peek = core.buf_root, core.generation, idx_mod.peek
  local saved_cache, saved_types = package.loaded["obsidian.cache"], package.loaded["blink.cmp.types"]
  core.buf_root = function()
    return ROOT
  end
  core.generation = function()
    return 1000
  end
  idx_mod.peek = function()
    return { sup = { [ROOT .. "/Papers/reading.md"] = { fields = { stage = { "draft", "review" } } } } }
  end
  package.loaded["obsidian.cache"] = {
    is_enabled = function()
      return true
    end,
    is_ready = function()
      return true
    end,
    notes = {
      all = function()
        return INDEX
      end,
    },
  }
  package.loaded["blink.cmp.types"] = { CompletionItemKind = { Value = 12 } }
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = { "~~~~dataview" }
  for _ = 1, 220 do
    lines[#lines + 1] = ""
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local source, completion = require("obsidian-query.blink").new(), nil
  local prefix = 'WHERE stage = "'
  source:get_completions({ bufnr = buf, cursor = { 221, #prefix }, line = prefix }, function(r)
    completion = r
  end)
  check(
    #completion.items == 2 and completion.items[1].label == "draft",
    "inline property values complete inside long tilde fences"
  )
  vim.api.nvim_buf_delete(buf, { force = true })
  core.buf_root, core.generation, idx_mod.peek = saved_root, saved_gen, saved_peek
  package.loaded["obsidian.cache"], package.loaded["blink.cmp.types"] = saved_cache, saved_types
end

do
  group = "mixed list nesting"
  local tasks = page_mod.build_tasks("/v/n.md", {
    { line = 1, indent = 0, text = "parent", state = "x" },
    { line = 3, indent = 4, text = "nested task", state = " " },
  }, {}, "n.md")
  local lists = page_mod.build_lists({
    headers = {},
    lists = {
      { line = 1, indent = 0, text = "[x] parent" },
      { line = 2, indent = 2, text = "plain" },
      { line = 3, indent = 4, text = "[ ] nested task" },
    },
  }, tasks, "/v/n.md", "n.md")
  check(
    lists[2].parent == 0 and lists[2].children[1] == tasks[2],
    "plain lists participate in parent and child hierarchy"
  )
  check(tasks[1].children[1] == lists[2] and not tasks[1].fullyCompleted, "completion folds through plain list parents")
  local rendered = flatten(dv_render.task_lines({ groups = { { items = tasks } } }))
  check(#rendered == 3 and rendered[2]:find("• plain", 1, true), "TASK renders plain descendants without checkboxes")
end

do
  group = "task metadata parity"
  check(pg.file.tasks[1].path == "Journal/2026-07-01.md", "task paths are vault relative")
  check(pg.file.tasks[2].parent == 9 and pg.file.tasks[2].line == 10, "task parent references zero-based line")
  check(value.typeof(pg.file.frontmatter.due) == "date", "file.frontmatter contains decoded Dataview values")
end

do
  group = "workspace boundary"
  local saved_ob, saved_api = _G.Obsidian, package.loaded["obsidian.api"]
  _G.Obsidian = { workspace = { root = ROOT } }
  package.loaded["obsidian.api"] = {
    find_workspace = function()
      return nil
    end,
  }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "/outside/note.md")
  check(require("obsidian-query").buf_root(buf) == nil, "unrecognized file does not inherit active vault")
  package.loaded["obsidian.api"].find_workspace = function()
    error("API unavailable")
  end
  check(require("obsidian-query").buf_root(buf) == nil, "fallback workspace still enforces vault boundary")
  vim.api.nvim_buf_delete(buf, { force = true })
  _G.Obsidian, package.loaded["obsidian.api"] = saved_ob, saved_api
end

do
  group = "string function parity"
  check(
    value.eq(ev('split("abc", "")'), value.array({ "a", "b", "c" })),
    "empty regex split omits boundary empty strings"
  )
  check(value.eq(ev('split("", "")'), value.array({})), "empty regex splits empty text to no elements")
  check(
    ev('padleft("x", 4, "ab")') == "abax" and ev('padright("x", 4, "ab")') == "xaba",
    "padding truncates repeated pad string"
  )
  check(ev('padleft("x", 4, "")') == "x", "empty padding is a no-op")
  check(
    ev('substring("abcd", 3, 1)') == "bc" and ev('substring("abcd", -2, 2)') == "ab",
    "substring swaps and clamps bounds"
  )
  check(ev('truncate("abcdef", 5)') == "ab...", "truncate uses Dataview default suffix")
  check(value.eq(ev('split("a,b;c", "[,;]")'), value.array({ "a", "b", "c" })), "split uses regex delimiters")
  check(value.eq(ev('split("a,b,c", ",", 2)'), value.array({ "a", "b" })), "split honors result limit")
end

do
  group = "currency rounding"
  check(F.currencyformat(env, { 9.999 }) == "$10.00", "currency rounding carries into integer part")
  check(F.currencyformat(env, { 999.9, "JPY" }) == "¥1,000", "zero-decimal currency rounds before grouping")
end

do
  group = "date overloads"
  check(ev('date("28/07/2026", "dd/MM/yyyy")').day == 28, "custom date parser returns a date")
  check(ev('date("28/07/2026", "dd/MM/yyyy")').month == 7, "date accepts numeric format")
  check(ev('date("July 28, 2026 2:30 PM", "MMMM dd, yyyy h:mm a")').hour == 14, "date accepts named month and meridiem")
  check(ev('date("2026-02-30", "yyyy-MM-dd")') == value.NULL, "custom date format validates calendar")
  check(ev('date("1000", "x")').ts == 1, "date accepts epoch milliseconds")
  check(ev("date([[2026-07-01]])").day == 1, "date accepts date-named links")
end

do
  group = "external links"
  check(
    ev('typeof(elink("https://example.com", "Label"))') == "widget",
    "external link is a widget rather than a vault link"
  )
  check(value.to_display(ev('elink("https://example.com", "Label")')) == "Label", "external link renders display label")
  check(ev('meta(elink("https://example.com"))') == value.NULL, "external links do not expose vault link metadata")
  check(ev('elink("https://example.com").path') == value.NULL, "external links cannot dereference vault pages")
end

do
  group = "folder normalization"
  check(#run('LIST FROM ""').data.groups[1].items == 3, "empty folder source includes whole vault")
  check(#run('LIST FROM "Journal/"').data.groups[1].items == 2, "folder source permits trailing slash")
end

do
  group = "runtime query errors"
  local result = run("TABLE nonexistent(file.name)")
  check(
    not result.ok and result.phase == "eval" and result.msg:find("Unrecognized function", 1, true),
    "unknown function produces query error rather than null cells"
  )
  local shadow = vim.deepcopy(CTX)
  shadow.index[ROOT .. "/Papers/reading.md"].properties.contains = "frontmatter value"
  result = query.run('TABLE contains("abc", "a") FROM "Papers"', shadow)
  check(result.ok and result.data.rows[1].cells[1] == true, "page field does not shadow built-in function calls")
end

do
  group = "completion index readiness"
  local core = require("obsidian-query")
  local saved_root, saved_gen, saved_peek = core.buf_root, core.generation, idx_mod.peek
  local saved_cache, saved_types = package.loaded["obsidian.cache"], package.loaded["blink.cmp.types"]
  core.buf_root = function()
    return ROOT
  end
  core.generation = function()
    return 2000
  end
  local ready
  idx_mod.peek = function()
    return ready
  end
  package.loaded["obsidian.cache"] = {
    is_enabled = function()
      return true
    end,
    is_ready = function()
      return true
    end,
    notes = {
      all = function()
        return INDEX
      end,
    },
  }
  package.loaded["blink.cmp.types"] = { CompletionItemKind = { Value = 12 } }
  local source, buf = require("obsidian-query.blink").new(), vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "```dataview", "" })
  local function complete()
    local result
    local prefix = 'WHERE stage = "'
    source:get_completions({ bufnr = buf, cursor = { 2, #prefix }, line = prefix }, function(r)
      result = r
    end)
    return result.items
  end
  check(#complete() == 0, "unready supplements do not invent completion values")
  ready = { sup = { [ROOT .. "/Papers/reading.md"] = { fields = { stage = "draft" } } } }
  check(
    #complete() == 1 and complete()[1].label == "draft",
    "ready supplement replaces completion memo without a vault edit"
  )
  vim.api.nvim_buf_delete(buf, { force = true })
  core.buf_root, core.generation, idx_mod.peek = saved_root, saved_gen, saved_peek
  package.loaded["obsidian.cache"], package.loaded["blink.cmp.types"] = saved_cache, saved_types
end

io.write(("all %d checks passed\n"):format(n_ok))

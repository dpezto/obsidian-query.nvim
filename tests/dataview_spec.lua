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
local toks = assert(lexer.tokenize('due-date - b "x" \'y\' #a/b [[Note|Show]] (f) => != 3.5'))
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
local q = assert(parser.parse('TABLE WITHOUT ID status AS "Status", priority FROM #día WHERE priority > 1 SORT priority DESC LIMIT 5'))
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
check(value.to_display(sp) == "2024-02-18 10:44", "space form keeps its time")
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
check(value.typeof(value.compare_op("<", value.NULL, 1)) == "null", "null < x -> null")
check(value.cmp(1, "a") == -1, "type rank number < string")
check(value.cmp(value.array({ 1, 2 }), value.array({ 1, 3 })) == -1, "array elementwise")

---------------------------------------------------------------- functions
group = "functions"
local F = functions.registry
local env = { funcs = F, now = NOW }
check(F.contains(env, { "Hello World", "world" }) == true, "contains string ci")
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
check(F.regexmatch(env, { "abc123", "\\d+" }) == true, "regexmatch shim")
check(F.regexreplace(env, { "a1b2", "\\d", "_" }) == "a_b_", "regexreplace")
check(F.lower(env, { "ABC" }) == "abc", "lower")
check(value.eq(F.lower(env, { value.array({ "A", "B" }) }), value.array({ "a", "b" })), "vectorized lower")
check(F.startswith(env, { "foobar", "foo" }) == true, "startswith")
check(F.round(env, { 3.456, 2 }) == 3.46, "round digits")
check(F.typeof(env, { value.NULL }) == "null", "typeof")
check(F.dateformat(env, { value.parse_date("2026-07-01"), "yyyy/MM/dd" }) == "2026/07/01", "dateformat")
check(F.dateformat(env, { value.parse_date("2026-07-01"), "'week' W" }):match("^week %d+$") ~= nil, "dateformat literal+W")
check(F.striptime(env, { value.parse_date("2026-07-01T14:30") }).prec == "date", "striptime")

---------------------------------------------------------------- eval
group = "eval"
local pg = page_mod.build(ROOT .. "/Journal/2026-07-01.md", INDEX[ROOT .. "/Journal/2026-07-01.md"], CTX)
local penv = { page = pg, funcs = F, now = NOW }
local function ev(src)
  local q3 = assert(parser.parse("LIST WHERE " .. src))
  return eval.expr(q3.commands[1].expr, penv)
end
check(ev("status = \"open\"") == true, "fm field access")
check(ev("priority + 1 = 4") == true, "arith on field")
check(ev("missing.deep.chain") == value.NULL, "null chain propagates")
check(ev("file.name") == "2026-07-01", "file.name")
check(ev("file.folder") == "Journal", "file.folder")
check(value.typeof(ev("due")) == "date", "ISO frontmatter string -> date")
check(ev("session-goal") == "publish notes", "inline field via kebab ident")
check(ev("contains(file.tags, \"#ci\")") == true, "tag prefix expansion")
check(ev("contains(file.etags, \"#ci/setup\")") == true, "etags exact")
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
check(ev('string(-dur(1 month))') == "-1 month", "negated duration keeps months")
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
check(pg.file.tasks[1].line == 10, "cache line passed through 1-indexed")
check(value.eq(pg.file.tasks[1].tags, value.array({ "#lab" })), "task tags")
check(value.typeof(pg.file.tasks[1].due) == "date" and pg.file.tasks[1].due.day == 15, "task [due::] field")
check(value.typeof(pg.file.tasks[3].due) == "date" and pg.file.tasks[3].due.day == 30, "task emoji due")

group = "this"
local tctx = vim.tbl_extend("force", {}, CTX, { this_path = ROOT .. "/Journal/2026-07-01.md" })
local tres = query.run('LIST WHERE file.name = this.file.name', tctx)
check(tres.ok and #tres.data.groups[1].items == 1, "this resolves to fence note")
tres = query.run("LIST FROM [[]]", tctx)
check(tres.ok and #tres.data.groups[1].items == 1 and tres.data.groups[1].items[1].path:find("reading"), "FROM [[]] = inlinks of this")

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

res = run("LIST FROM #día WHERE status = \"open\"")
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

res = run("TABLE length(rows) FROM \"Journal\" GROUP BY status")
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

res = run("TASK FROM \"Journal\" WHERE !completed")
check(res.ok, "task query runs")
local tcount = 0
for _, g in ipairs(res.data.groups) do
  tcount = tcount + #g.items
end
check(tcount == 1, "task explosion + WHERE on task fields; got " .. tcount)

res = run("TASK FROM \"Journal\" GROUP BY section")
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
check(flat[1]:find("‹") and flat[1]:find("July 2026") and flat[1]:find("›$"), "grid header with arrows")
-- header spans the grid ("▏ " + 7 day cells) so the arrows sit still
check(vim.fn.strdisplaywidth(flat[1]) == 2 + 21, "header spans the grid width")
check(flat[2]:find("Mo Tu We"), "weekday row")
check(flat[3]:find("1•"), "day 1 marked (2026-07-01 is a Wednesday)")
check(flat[#flat]:find("2 this month · 2 dated notes"), "month + total tail")
for _, l in ipairs(flat) do
  check(not l:find("August") and not l:find("June"), "only the current month rendered")
end

-- <Left>/<Right> shift the view; months without notes still render
local next_month = flatten(dv_render.calendar_lines(run("CALENDAR").data, 1))
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
  local d = { kind = "calendar", months = { { year = 2026, month = 7, days = days } }, dated = {},
    today = { year = 2026, month = 7, day = 1 } }
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
local anchors = { ["88226a"] = true, ["a83655"] = true, ["e35933"] = true,
  ["f9950a"] = true, ["f8c932"] = true, ["fcffa4"] = true }
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
  local d = { kind = "calendar", months = { { year = 2026, month = 7, days = days } }, dated = {},
    today = { year = 2026, month = 7, day = 1 } }
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
check(with_today[1][1]:find("^ObsidianQueryHeat%d+$") and with_today[1][2] == "ObsidianQueryToday", "today = heat + today attrs")
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
check(value.to_display(eval.expr(pe("missing.field"), ienv)) == "", "null displays empty (no mark)")

---------------------------------------------------------------- durations
group = "durations"
local jan31 = value.parse_date("2026-01-31")
local plus1mo = value.arith("+", jan31, value.parse_dur("1 month"))
check(value.to_display(plus1mo) == "2026-02-28", "month shift clamps day")
check(value.to_display(value.arith("+", value.parse_date("2024-02-29"), value.parse_dur("1 year"))) == "2025-02-28", "year shift clamps leap day")
check(value.parse_dur("1 mo").months == 1 and value.parse_dur("2 years").months == 24, "symbolic months")
check(value.to_display(value.parse_dur("14 months, 3 days")) == "1 year, 2 months, 3 days", "hybrid display")
check(value.cmp(value.parse_dur("1 month"), value.parse_dur("29 days")) == 1, "approx ordering")
check(value.to_display(value.arith("-", value.parse_date("2026-03-31"), value.parse_dur("1 month"))) == "2026-02-28", "month subtraction clamps")

---------------------------------------------------------------- regex
group = "regex"
check(F.regexmatch(env, { "foo", "foo|bar" }) == true, "alternation")
check(F.regexmatch(env, { "foobar", "foo(?=bar)" }) == true, "lookahead")
check(F.regexmatch(env, { "foobaz", "foo(?=bar)" }) == false, "negative lookahead miss")
check(F.regexmatch(env, { "xbar", "(?<=x)bar" }) == true, "lookbehind")
check(F.regexreplace(env, { "john smith", "(\\w+) (\\w+)", "$2 $1" }) == "smith john", "backref replace")
check(F.regexmatch(env, { "a@b.com", "\\w+@\\w+" }) == true, "literal @")

---------------------------------------------------------------- formats
group = "formats"
check(F.durationformat(env, { value.parse_dur("1 year, 2 months, 3 days"), "y'y' M'mo' d'd'" }) == "1y 2mo 3d", "durationformat tokens")
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
fd:write('{"items":[{"type":"file","path":"Journal/2026-07-01.md"},{"type":"group","items":[{"type":"file","path":"Papers/reading.md"}]}]}')
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
fd:write("---\ntags:\n  - yaml-item\n---\n# H\n- uno\n  - dos\n3) tres\n```\n- fenced\n```\n- [ ] box\n")
fd:close()
local sup3 = idx_mod._extract_sup(listmd)
check(#sup3.lists == 4, "yaml + fenced bullets excluded, box included")
check(sup3.lists[1].text == "uno" and sup3.lists[2].indent == 2, "list text + indent")
check(sup3.lists[3].text == "tres", "numbered list item")
check(sup3.lists[4].text == "[ ] box", "checkbox line still recorded (paired with its task by line)")
vim.fn.delete(tmp, "rf")

---------------------------------------------------------------- task toggle
group = "toggle"
local dv_engine = require("obsidian-query.dataview")
check(dv_engine.toggle_task_line("- [ ] hacer algo") == "- [x] hacer algo", "open -> done")
check(dv_engine.toggle_task_line("  - [x] hecho") == "  - [ ] hecho", "done -> open")
check(dv_engine.toggle_task_line("3. [/] parcial") == "3. [ ] parcial", "custom state resets to open")
check(dv_engine.toggle_task_line("plain prose line") == nil, "no checkbox -> nil")
check(dv_engine.toggle_task_line("- [ ] outer [x] inner") == "- [x] outer [x] inner", "first checkbox wins")

---------------------------------------------------------------- picker title
group = "title"
local fres = run('TABLE file.name FROM "Journal"')
check(fres.ok and fres.data.from and fres.data.from.k == "s_folder", "FROM folder exposed on result")
check(fres.data.from.folder == "Journal", "folder name kept for the title")
local tagres = run("LIST FROM #día")
check(tagres.data.from.k == "s_tag" and tagres.data.from.tag == "día", "FROM tag exposed")
check(run("LIST").data.from == nil, "no FROM -> no source on result")

io.write(("all %d checks passed\n"):format(n_ok))

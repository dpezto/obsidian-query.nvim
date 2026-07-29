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
  [ROOT .. "/Bitacora/2026-07-01.md"] = {
    mtime = ts(2026, 7, 1),
    size = 100,
    aliases = { "MTS day one" },
    tags = { "bitácora", "mts/setup" },
    properties = { lang = "es", priority = 3, due = "2026-08-01" },
    links_out = { { target = "2026-07-10", kind = "wiki" } },
    tasks = {
      { line = 10, indent = 0, state = " ", text = "alinear #lab [due:: 2026-08-15]" },
      { line = 11, indent = 2, state = "x", text = "sub uno" },
      { line = 13, indent = 0, state = "x", text = "calibrar 📅 2026-07-30" },
    },
  },
  [ROOT .. "/Bitacora/2026-07-10.md"] = {
    mtime = ts(2026, 7, 10),
    size = 200,
    aliases = {},
    tags = { "bitácora" },
    properties = { lang = "en", priority = 1 },
    links_out = {},
    tasks = {},
  },
  [ROOT .. "/Papers/reading.md"] = {
    mtime = ts(2026, 6, 1),
    size = 300,
    aliases = {},
    tags = { "papers" },
    properties = { lang = "en", rating = 9.5 },
    links_out = { { target = "2026-07-01", kind = "wiki" } },
    tasks = {},
  },
}
local SUP = {
  [ROOT .. "/Bitacora/2026-07-01.md"] = {
    fields = { ["session-goal"] = "characterize MTS" },
    headers = { { line = 5, level = 1, text = "Plan" }, { line = 9, level = 2, text = "Tareas" } },
  },
}
local INLINKS = {
  [ROOT .. "/Bitacora/2026-07-10.md"] = { ROOT .. "/Bitacora/2026-07-01.md" },
  [ROOT .. "/Bitacora/2026-07-01.md"] = { ROOT .. "/Papers/reading.md" },
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
local q = assert(parser.parse('TABLE WITHOUT ID lang AS "Lang", priority FROM #bitácora WHERE priority > 1 SORT priority DESC LIMIT 5'))
check(q.header.kind == "table" and q.header.without_id, "TABLE WITHOUT ID")
check(#q.header.fields == 2 and q.header.fields[1].alias == "Lang", "field alias")
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
local q2 = assert(parser.parse('LIST WHERE priority > 1 AND lang = "es" OR done'))
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
local pg = page_mod.build(ROOT .. "/Bitacora/2026-07-01.md", INDEX[ROOT .. "/Bitacora/2026-07-01.md"], CTX)
local penv = { page = pg, funcs = F, now = NOW }
local function ev(src)
  local q3 = assert(parser.parse("LIST WHERE " .. src))
  return eval.expr(q3.commands[1].expr, penv)
end
check(ev("lang = \"es\"") == true, "fm field access")
check(ev("priority + 1 = 4") == true, "arith on field")
check(ev("missing.deep.chain") == value.NULL, "null chain propagates")
check(ev("file.name") == "2026-07-01", "file.name")
check(ev("file.folder") == "Bitacora", "file.folder")
check(value.typeof(ev("due")) == "date", "ISO frontmatter string -> date")
check(ev("session-goal") == "characterize MTS", "inline field via kebab ident")
check(ev("contains(file.tags, \"#mts\")") == true, "tag prefix expansion")
check(ev("contains(file.etags, \"#mts/setup\")") == true, "etags exact")
check(ev("length(file.aliases) = 1") == true, "aliases")
check(ev("length(file.inlinks) = 1") == true, "inlinks")
check(ev("length(file.outlinks) = 1") == true, "outlinks")
check(ev("length(file.tasks) = 3") == true, "tasks present")
check(ev("any(map(file.tasks, (t) => !t.checked))") == true, "lambda over tasks")
check(ev("date(today) - due < dur(30 days)") == true, "date literal + dur math")
-- swizzle
local rows_v = eval.expr(assert(parser.parse("LIST WHERE file.tasks.text")).commands[1].expr, penv)
check(value.typeof(rows_v) == "array" and rows_v[1]:find("^alinear #lab") ~= nil, "array swizzle .text")

---------------------------------------------------------------- page/tasks
group = "page"
check(pg.file.tasks[1].fullyCompleted == false, "parent not fullyCompleted (unchecked itself)")
check(pg.file.tasks[3].fullyCompleted == true, "leaf completed")
check(#pg.file.tasks[1].children == 1, "indent nesting")
check(pg.file.tasks[1].section.display == "Tareas", "section from headers index")
check(pg.file.tasks[1].line == 10, "cache line passed through 1-indexed")
check(value.eq(pg.file.tasks[1].tags, value.array({ "#lab" })), "task tags")
check(value.typeof(pg.file.tasks[1].due) == "date" and pg.file.tasks[1].due.day == 15, "task [due::] field")
check(value.typeof(pg.file.tasks[3].due) == "date" and pg.file.tasks[3].due.day == 30, "task emoji due")

group = "this"
local tctx = vim.tbl_extend("force", {}, CTX, { this_path = ROOT .. "/Bitacora/2026-07-01.md" })
local tres = query.run('LIST WHERE file.name = this.file.name', tctx)
check(tres.ok and #tres.data.groups[1].items == 1, "this resolves to fence note")
tres = query.run("LIST FROM [[]]", tctx)
check(tres.ok and #tres.data.groups[1].items == 1 and tres.data.groups[1].items[1].path:find("reading"), "FROM [[]] = inlinks of this")

---------------------------------------------------------------- pipeline
group = "pipeline"
local res = run('TABLE lang, priority FROM "Bitacora" SORT priority DESC')
check(res.ok, "table runs: " .. (res.msg or ""))
check(#res.data.rows == 2, "folder source")
check(res.data.columns[1] == "File" and res.data.columns[2] == "lang", "columns")
check(res.data.rows[1].cells[2] == 3, "sort desc by priority")
check(res.data.rows[1].path:find("2026%-07%-01"), "row path")

res = run("LIST FROM #mts")
check(res.ok and #res.data.groups[1].items == 1, "nested tag source")

res = run("LIST FROM #bitácora WHERE lang = \"es\"")
check(res.ok and #res.data.groups[1].items == 1, "WHERE filters")

res = run("LIST FROM [[2026-07-10]]")
check(res.ok and #res.data.groups[1].items == 1, "FROM [[link]] = inlinks")
check(res.data.groups[1].items[1].path:find("07%-01"), "inlink correct")

res = run("LIST FROM outgoing([[reading]])")
check(res.ok and #res.data.groups[1].items == 1 and res.data.groups[1].items[1].path:find("07%-01"), "outgoing()")

res = run('LIST FROM "Bitacora" OR "Papers"')
check(res.ok and #res.data.groups[1].items == 3, "source OR")

res = run('LIST FROM -"Papers"')
check(res.ok and #res.data.groups[1].items == 2, "source negation")

res = run("TABLE length(rows) FROM \"Bitacora\" GROUP BY lang")
check(res.ok and #res.data.rows == 2, "GROUP BY buckets")
check(res.data.rows[1].cells[1] == 1, "length(rows)")

res = run('LIST FROM "Bitacora" FLATTEN file.tags AS t WHERE t = "#mts"')
check(res.ok and #res.data.groups[1].items == 1, "FLATTEN then WHERE (written order)")

res = run('LIST FROM "Bitacora" WHERE priority > 0 LIMIT 1')
check(res.ok and #res.data.groups[1].items == 1, "LIMIT")

-- command order matters: WHERE before vs after GROUP
local a = run('TABLE length(rows) FROM "Bitacora" WHERE priority > 1 GROUP BY lang')
local b = run('TABLE length(rows) FROM "Bitacora" GROUP BY lang WHERE length(rows) > 1')
check(a.ok and #a.data.rows == 1, "WHERE then GROUP")
check(b.ok and #b.data.rows == 0, "GROUP then WHERE on group rows")

res = run("TASK FROM \"Bitacora\" WHERE !completed")
check(res.ok, "task query runs")
local tcount = 0
for _, g in ipairs(res.data.groups) do
  tcount = tcount + #g.items
end
check(tcount == 1, "task explosion + WHERE on task fields; got " .. tcount)

res = run("TASK FROM \"Bitacora\" GROUP BY section")
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
local cal = dv_render.calendar_lines(run("CALENDAR").data)
local flat = {}
for _, l in ipairs(cal) do
  local parts = {}
  for _, seg in ipairs(l) do
    parts[#parts + 1] = seg[1]
  end
  flat[#flat + 1] = table.concat(parts)
end
check(flat[1]:find("July 2026"), "grid header")
check(flat[2]:find("Mo Tu We"), "weekday row")
check(flat[3]:find("1•"), "day 1 marked (2026-07-01 is a Wednesday)")
check(flat[#flat]:find("2 dated notes"), "dated count tail")

local cal_data = run("CALENDAR").data
dv_render.calendar_lines(cal_data)
local cmap = cal_data._clickmap
check(cmap ~= nil and next(cmap) ~= nil, "clickmap built")
local any_cell
for _, cells in pairs(cmap) do
  any_cell = cells[1]
  break
end
check(any_cell and any_cell.s > 2 and any_cell.e > any_cell.s and #any_cell.paths > 0, "clickmap cell shape")

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

io.write(("all %d checks passed\n"):format(n_ok))
